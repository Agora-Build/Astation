import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'gateway.dart';
import 'models.dart';

enum WorkspaceTab { chats, agents, account }

class WorkspaceController extends ChangeNotifier {
  WorkspaceController(this.gateway, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final AstationGateway gateway;
  final DateTime Function() now;
  WorkspaceSnapshot? snapshot;
  WorkspaceTab tab = WorkspaceTab.chats;
  AgentTarget? selected;
  String? selectedHost;
  String? error;
  bool loading = true;
  bool busy = false;
  bool foreground = true;
  bool _disposed = false;
  int _generation = 0;
  int _revision = -1;
  int _operation = 0;
  final Set<String> _retiredContexts = {};
  final Map<AgentTarget, String> _drafts = {};
  StreamSubscription<WorkspaceSnapshot>? _subscription;
  Timer? _expiry;

  List<AgentSummary> get recentAgents => [...?snapshot?.agents]
    ..sort((a, b) {
      final date = b.updatedAt.compareTo(a.updatedAt);
      return date == 0 ? a.target.key.compareTo(b.target.key) : date;
    });
  List<ApprovalRequest> get pendingApprovals =>
      snapshot?.approvals
          .where((request) => request.isPending(now()))
          .toList() ??
      [];
  AgentSummary? agent(AgentTarget? target) {
    for (final item in snapshot?.agents ?? <AgentSummary>[]) {
      if (item.target == target) return item;
    }
    return null;
  }

  HostSummary? host(String? id) {
    for (final item in snapshot?.hosts ?? <HostSummary>[]) {
      if (item.id == id) return item;
    }
    return null;
  }

  Conversation? conversation(AgentTarget target) {
    for (final item in snapshot?.conversations ?? <Conversation>[]) {
      if (item.target == target) return item;
    }
    return null;
  }

  String draft(AgentTarget target) => _drafts[target] ?? '';
  void saveDraft(AgentTarget target, String text) {
    _drafts[target] = text;
  }

  bool canOperate(AgentTarget target) =>
      foreground &&
      !busy &&
      snapshot?.access == DeviceAccess.control &&
      agent(target)?.connected == true &&
      agent(target)?.lifecycle == AgentLifecycle.running &&
      agent(target)?.canControl == true;

  Future<void> start() async {
    _subscription = gateway.changes.listen(
      _accept,
      onError: (Object failure) {
        if (!_disposed) {
          error = _message(failure);
          notifyListeners();
        }
      },
    );
    try {
      _accept(await gateway.readState());
    } catch (failure) {
      error = _message(failure);
    }
    if (_disposed) return;
    loading = false;
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) {
      if (snapshot?.approvals.any(
            (request) => request.state == ApprovalState.pending,
          ) ??
          false) {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void _accept(WorkspaceSnapshot next) {
    if (_disposed ||
        next.revision <= _revision ||
        _retiredContexts.contains(next.context)) {
      return;
    }
    if (snapshot?.context != next.context) {
      if (snapshot != null) _retiredContexts.add(snapshot!.context);
      _generation++;
      _drafts.clear();
      selected = null;
      selectedHost = null;
      tab = WorkspaceTab.chats;
    }
    _revision = next.revision;
    snapshot = next;
    final targets = next.agents.map((item) => item.target).toSet();
    _drafts.removeWhere((target, _) => !targets.contains(target));
    if (!targets.contains(selected)) selected = null;
    notifyListeners();
  }

  Future<void> refresh() => _perform(() async {
    await gateway.refresh();
    _accept(await gateway.readState());
  });
  Future<void> signIn() => _perform(() async {
    await gateway.signIn();
    _accept(await gateway.readState());
  });
  Future<void> signOut() => _reset(gateway.signOut);
  Future<void> selectEnvironment(ServerEnvironment environment) =>
      _reset(() => gateway.selectEnvironment(environment));
  Future<void> _reset(Future<void> Function() operation) => _perform(() async {
    _generation++;
    if (snapshot != null) _retiredContexts.add(snapshot!.context);
    _drafts.clear();
    selected = null;
    selectedHost = null;
    snapshot = null;
    notifyListeners();
    await operation();
    _accept(await gateway.readState());
  }, supersede: true);
  bool get canEnroll =>
      foreground &&
      !busy &&
      snapshot?.account != null &&
      snapshot?.access == DeviceAccess.notEnrolled &&
      snapshot?.enrollmentAvailable == true;

  Future<void> enrollDevice() async {
    if (!canEnroll) return;
    await _perform(gateway.enrollDevice);
  }

  void selectTab(WorkspaceTab value) {
    tab = value;
    if (value == WorkspaceTab.agents) selectedHost = null;
    selected = null;
    notifyListeners();
  }

  void selectHost(String id) {
    selectedHost = id;
    selected = null;
    notifyListeners();
  }

  Future<void> selectConversation(AgentTarget target) async {
    if (agent(target) == null) return;
    selected = target;
    notifyListeners();
    final context = snapshot!.context;
    try {
      await gateway.watchConversation(context, target);
    } catch (failure) {
      if (!_disposed && snapshot?.context == context && selected == target) {
        error = _message(failure);
        notifyListeners();
      }
    }
  }

  void closeConversation() {
    selected = null;
    notifyListeners();
  }

  Future<void> loadEarlier(AgentTarget target) =>
      _perform(() => gateway.loadEarlier(snapshot!.context, target));

  Future<CommandResult?> send(
    AgentTarget target, {
    ControllerReference? takeover,
  }) async {
    if (!canOperate(target)) return null;
    final text = draft(target).trim();
    if (text.isEmpty || utf8.encode(text).length > 65536) {
      error = text.isEmpty
          ? 'Write a message first.'
          : 'This message is too large. Shorten it and try again.';
      notifyListeners();
      return null;
    }
    final generation = _generation;
    final result = await _result(
      () => gateway.sendPrompt(
        snapshot!.context,
        target,
        text,
        takeover: takeover,
      ),
    );
    if (_generation != generation) return null;
    if (result != null &&
        result.status != 'takeoverRequired' &&
        ['accepted', 'executing', 'completed'].contains(result.status) &&
        draft(target).trim() == text) {
      _drafts.remove(target);
      notifyListeners();
    }
    return result;
  }

  Future<CommandResult?> answer(
    ApprovalRequest request,
    String decision, {
    ApprovalRule? rule,
    String? message,
  }) async {
    if (!canOperate(request.target) ||
        !request.isPending(now()) ||
        !(snapshot?.approvals.any(
              (current) =>
                  current.key == request.key && current.isPending(now()),
            ) ??
            false)) {
      return null;
    }
    final current = snapshot!.approvals.firstWhere(
      (item) => item.key == request.key,
    );
    if (current.command != request.command ||
        current.summary != request.summary ||
        !['allowOnce', 'allowAlways', 'deny'].contains(decision) ||
        (decision != 'allowAlways' && rule != null) ||
        (decision == 'allowAlways' &&
            (rule == null ||
                !current.rules.any(
                  (item) =>
                      item.id == rule.id &&
                      item.label == rule.label &&
                      item.scope == rule.scope,
                )))) {
      return null;
    }
    return _result(
      () => gateway.answerApproval(
        snapshot!.context,
        current,
        decision,
        ruleId: rule?.id,
        message: message,
      ),
    );
  }

  Future<CommandResult?> revokeRule(AgentTarget target, String id) async {
    if (!canOperate(target) ||
        !(snapshot?.rules.any(
              (item) => item.target == target && item.rule.id == id,
            ) ??
            false)) {
      return null;
    }
    return _result(() => gateway.revokeRule(snapshot!.context, target, id));
  }

  Future<CommandResult?> launch(LaunchProfile profile) async {
    if (!foreground ||
        busy ||
        snapshot?.access != DeviceAccess.control ||
        host(profile.host)?.online != true ||
        !(snapshot?.profiles.any(
              (item) => item.host == profile.host && item.id == profile.id,
            ) ??
            false)) {
      return null;
    }
    return _result(() => gateway.launchAgent(snapshot!.context, profile));
  }

  Future<CommandResult?> lookup(AgentTarget target, String requestId) =>
      _result(
        () =>
            gateway.lookupReceipt(snapshot!.context, target, requestId.trim()),
      );
  Future<void> openExternal(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      error = 'This link cannot be opened safely.';
      notifyListeners();
      return;
    }
    await _perform(() => gateway.openExternal(uri));
  }

  Future<void> setForeground(bool value) async {
    foreground = value;
    if (!value) _generation++;
    notifyListeners();
    try {
      await gateway.setForeground(value);
    } catch (_) {
      /* Resume refresh exposes connection state without a background alert. */
    }
    if (value && !_disposed) await refresh();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<CommandResult?> _result(
    Future<CommandResult> Function() operation,
  ) async {
    final generation = _generation;
    CommandResult? result;
    await _perform(() async {
      result = await operation();
    });
    return generation == _generation ? result : null;
  }

  Future<void> _perform(
    Future<void> Function() operation, {
    bool supersede = false,
  }) async {
    if ((busy && !supersede) || _disposed) return;
    final ticket = ++_operation;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await operation();
    } catch (failure) {
      if (!_disposed && ticket == _operation) error = _message(failure);
    } finally {
      if (!_disposed && ticket == _operation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  String _message(Object failure) => failure is GatewayFailure
      ? failure.message
      : 'The connection changed. Reconnect and try again.';
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _expiry?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
