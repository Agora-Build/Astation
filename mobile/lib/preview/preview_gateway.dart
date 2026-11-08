import 'dart:async';

import '../src/gateway.dart';
import '../src/models.dart';

/// Deliberately imported only by main_preview.dart and tests, never main.dart.
class PreviewGateway implements AstationGateway {
  PreviewGateway({this.signedIn = false, DateTime? clock})
    : clock = clock ?? DateTime.now();

  final DateTime clock;
  final _changes = StreamController<WorkspaceSnapshot>.broadcast();
  bool signedIn;
  bool foreground = true;
  DeviceAccess access = DeviceAccess.control;
  int revision = 0;
  int generation = 0;
  int commandCount = 0;
  ServerEnvironment environment = ServerEnvironment.development;
  final Set<String> answered = {};
  final List<SessionRule> rules = [];
  final Map<AgentTarget, List<ChatMessage>> sent = {};
  ControllerReference? holder;
  ControllerReference? lastTakeover;
  String? lastDecision;
  String? lastRule;
  Uri? lastExternal;
  Completer<CommandResult>? commandBarrier;

  static const codex = AgentTarget(
    account: 'preview-account',
    host: 'genie-preview',
    trustGeneration: 1,
    session: 'codex-preview',
    processGeneration: 'process-codex-1',
  );
  static const claude = AgentTarget(
    account: 'preview-account',
    host: 'genie-preview',
    trustGeneration: 1,
    session: 'claude-preview',
    processGeneration: 'process-claude-1',
  );

  WorkspaceSnapshot state() => WorkspaceSnapshot(
    context: 'preview-$generation',
    revision: revision,
    environment: environment,
    account: signedIn
        ? const AccountSummary(id: 'preview-account', name: 'Brent Guo')
        : null,
    access: signedIn ? access : DeviceAccess.notEnrolled,
    deviceName: 'Preview phone',
    deviceId: 'preview-device',
    loginAvailable: true,
    preview: true,
    hosts: !signedIn
        ? const []
        : const [
            HostSummary(
              id: 'genie-preview',
              name: 'Genie',
              platform: 'Linux',
              online: true,
            ),
            HostSummary(
              id: 'studio-preview',
              name: 'Studio',
              platform: 'macOS',
              online: false,
            ),
          ],
    agents: !signedIn
        ? const []
        : [
            AgentSummary(
              target: codex,
              name: 'Astation mobile',
              provider: 'Codex',
              activity: AgentActivity.ready,
              lifecycle: AgentLifecycle.running,
              updatedAt: clock.subtract(const Duration(minutes: 2)),
              preview: 'The layout is in place. Ready to run the mobile tests.',
              connected: true,
              canControl: true,
            ),
            AgentSummary(
              target: claude,
              name: 'Relay reliability',
              provider: 'Claude',
              activity: AgentActivity.waiting,
              lifecycle: AgentLifecycle.running,
              updatedAt: clock.subtract(const Duration(minutes: 9)),
              preview: 'I need your approval to run the test suite.',
              connected: true,
              canControl: true,
            ),
          ],
    profiles: !signedIn
        ? const []
        : const [
            LaunchProfile(
              host: 'genie-preview',
              id: 'codex',
              name: 'Codex · Astation',
              provider: 'Codex',
              project: 'Agora.Build / Astation',
            ),
          ],
    approvals: !signedIn
        ? const []
        : [
            ApprovalRequest(
              id: 'approval-test',
              target: claude,
              summary: 'Run the relay test suite',
              command: 'cargo test --bin station-relay-server',
              expiresAt: clock.add(const Duration(hours: 2)),
              state: answered.contains('approval-test')
                  ? ApprovalState.answered
                  : ApprovalState.pending,
              closeReason: answered.contains('approval-test')
                  ? 'Answered on this preview device'
                  : null,
              rules: const [
                ApprovalRule(
                  id: 'rule-test',
                  label: 'cargo test --bin station-relay-server',
                  scope: 'session',
                ),
              ],
            ),
            ApprovalRequest(
              id: 'approval-docs',
              target: codex,
              summary: 'Read the project documentation',
              command: 'cat README.md',
              expiresAt: clock.add(const Duration(hours: 2)),
              state: answered.contains('approval-docs')
                  ? ApprovalState.answered
                  : ApprovalState.pending,
            ),
          ],
    conversations: !signedIn
        ? const []
        : [
            Conversation(
              target: codex,
              messages: [
                ChatMessage(
                  id: 'codex-1',
                  role: MessageRole.user,
                  markdown: 'How does the mobile foundation look?',
                  createdAt: clock.subtract(const Duration(minutes: 3)),
                ),
                ChatMessage(
                  id: 'codex-2',
                  role: MessageRole.assistant,
                  markdown:
                      'The layout is in place. **Here is what I would build next.**\n\n'
                      '1. Keep the phone composer within reach.\n2. Put approvals beside their exact conversation.\n'
                      '3. Preserve drafts when you switch agents.\n\n'
                      '```dart\nawait client.refresh();\n```\n\n'
                      'See the [Astation project](https://github.com/Agora-Build/Astation).',
                  createdAt: clock.subtract(const Duration(minutes: 2)),
                  tools: const [
                    ToolActivity(
                      title: 'Reviewed the mobile layout',
                      detail: 'Phone, tablet and separating hinges.',
                    ),
                  ],
                ),
                ...?sent[codex],
              ],
            ),
            Conversation(
              target: claude,
              messages: [
                ChatMessage(
                  id: 'claude-1',
                  role: MessageRole.assistant,
                  markdown: 'The relay changes are ready. I need your approval to run the test suite.',
                  createdAt: clock.subtract(const Duration(minutes: 9)),
                ),
                ...?sent[claude],
              ],
            ),
          ],
    rules: signedIn ? List.unmodifiable(rules) : const [],
  );

  void emit() {
    revision++;
    _changes.add(state());
  }

  Future<void> dispose() => _changes.close();
  @override
  Stream<WorkspaceSnapshot> get changes => _changes.stream;
  @override
  Future<WorkspaceSnapshot> readState() async => state();
  @override
  Future<void> signIn() async {
    signedIn = true;
    generation++;
    emit();
  }

  @override
  Future<void> signOut() async {
    signedIn = false;
    sent.clear();
    generation++;
    emit();
  }

  @override
  Future<void> selectEnvironment(ServerEnvironment value) async {
    environment = value;
    await signOut();
  }

  @override
  Future<void> refresh() async => emit();
  @override
  Future<void> setForeground(bool value) async {
    foreground = value;
  }

  @override
  Future<void> enrollDevice() async => throw const GatewayFailure(
    'preview',
    'Enrollment is unavailable in a design preview.',
  );
  @override
  Future<void> openExternal(Uri uri) async {
    lastExternal = uri;
  }

  @override
  Future<void> watchConversation(String context, AgentTarget target) async {}
  @override
  Future<void> loadEarlier(String context, AgentTarget target) async {}
  @override
  Future<CommandResult> sendPrompt(
    String context,
    AgentTarget target,
    String text, {
    ControllerReference? takeover,
  }) async {
    commandCount++;
    lastTakeover = takeover;
    if (commandBarrier != null) return commandBarrier!.future;
    if (holder != null &&
        (takeover?.session != holder!.session ||
            takeover?.epoch != holder!.epoch)) {
      return CommandResult(
        requestId: 'preview-held',
        status: 'takeoverRequired',
        controller: holder,
      );
    }
    sent
        .putIfAbsent(target, () => [])
        .add(
          ChatMessage(
            id: 'sent-$commandCount',
            role: MessageRole.user,
            markdown: text,
            createdAt: clock,
          ),
        );
    emit();
    return CommandResult(
      requestId: 'preview-$commandCount',
      status: 'completed',
      detail: 'Preview only; no agent command was sent.',
    );
  }

  @override
  Future<CommandResult> answerApproval(
    String context,
    ApprovalRequest request,
    String decision, {
    String? ruleId,
    String? message,
  }) async {
    commandCount++;
    lastDecision = decision;
    lastRule = ruleId;
    answered.add(request.id);
    if (decision == 'allowAlways') {
      rules.add(
        SessionRule(
          target: request.target,
          rule: request.rules.firstWhere((rule) => rule.id == ruleId),
        ),
      );
    }
    emit();
    return const CommandResult(
      requestId: 'preview-approval',
      status: 'completed',
    );
  }

  @override
  Future<CommandResult> revokeRule(
    String context,
    AgentTarget target,
    String ruleId,
  ) async {
    commandCount++;
    rules.removeWhere(
      (item) => item.target == target && item.rule.id == ruleId,
    );
    emit();
    return const CommandResult(
      requestId: 'preview-revoke',
      status: 'completed',
    );
  }

  @override
  Future<CommandResult> launchAgent(
    String context,
    LaunchProfile profile,
  ) async {
    commandCount++;
    return const CommandResult(
      requestId: 'preview-launch',
      status: 'completed',
      detail: 'Preview only; no agent was started.',
    );
  }

  @override
  Future<CommandResult> lookupReceipt(
    String context,
    AgentTarget target,
    String requestId,
  ) async => CommandResult(
    requestId: requestId,
    status: 'completed',
    detail: 'Sample receipt. No live request.',
  );
}
