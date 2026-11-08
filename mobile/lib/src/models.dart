import 'dart:convert';

import 'package:flutter/foundation.dart';

enum ServerEnvironment {
  development(
    'Development',
    'https://dev.agora.build',
    'https://auth.dev.agora.build',
    'https://station-dev.agora.build',
  ),
  production(
    'Production',
    'https://agora.build',
    'https://auth.agora.build',
    'https://station.agora.build',
  );

  const ServerEnvironment(this.label, this.portal, this.issuer, this.station);
  final String label;
  final String portal;
  final String issuer;
  final String station;

  static ServerEnvironment get buildDefault =>
      kDebugMode ? development : production;
}

enum DeviceAccess { notEnrolled, view, control, revoked }

enum AgentActivity { ready, working, waiting, unknown }

enum AgentLifecycle { running, stopped }

enum ApprovalState { pending, answered, expired, autoAllowed }

enum MessageRole { user, assistant, system }

@immutable
class AgentTarget {
  const AgentTarget({
    required this.account,
    required this.host,
    required this.trustGeneration,
    required this.session,
    required this.processGeneration,
  });

  final String account;
  final String host;
  final int trustGeneration;
  final String session;
  final String processGeneration;

  factory AgentTarget.fromJson(Map<String, Object?> json) => AgentTarget(
    account: _string(json, 'account'),
    host: _string(json, 'host'),
    trustGeneration: _integer(json, 'trustGeneration'),
    session: _string(json, 'session'),
    processGeneration: _string(json, 'processGeneration'),
  );

  Map<String, Object?> toJson() => {
    'account': account,
    'host': host,
    'trustGeneration': trustGeneration,
    'session': session,
    'processGeneration': processGeneration,
  };
  String get key => jsonEncode(toJson());
  @override
  bool operator ==(Object other) => other is AgentTarget && key == other.key;
  @override
  int get hashCode => key.hashCode;
}

@immutable
class AccountSummary {
  const AccountSummary({required this.id, required this.name});
  final String id;
  final String name;
  factory AccountSummary.fromJson(Map<String, Object?> json) =>
      AccountSummary(id: _string(json, 'id'), name: _string(json, 'name'));
}

@immutable
class HostSummary {
  const HostSummary({
    required this.id,
    required this.name,
    required this.platform,
    required this.online,
    this.lastSeen,
  });
  final String id;
  final String name;
  final String platform;
  final bool online;
  final DateTime? lastSeen;
  String get shortId => id.length > 12 ? id.substring(id.length - 12) : id;
  String get displayName =>
      id.toLowerCase().startsWith(name.toLowerCase()) ? id : '$name · $shortId';
  factory HostSummary.fromJson(Map<String, Object?> json) => HostSummary(
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    platform: _string(json, 'platform'),
    online: _bool(json, 'online'),
    lastSeen: _optionalDate(json['lastSeen']),
  );
}

@immutable
class AgentSummary {
  const AgentSummary({
    required this.target,
    required this.name,
    required this.provider,
    required this.activity,
    required this.lifecycle,
    required this.updatedAt,
    this.preview = '',
    this.connected = false,
    this.canControl = false,
  });
  final AgentTarget target;
  final String name;
  final String provider;
  final AgentActivity activity;
  final AgentLifecycle lifecycle;
  final DateTime updatedAt;
  final String preview;
  final bool connected;
  final bool canControl;
  factory AgentSummary.fromJson(Map<String, Object?> json) => AgentSummary(
    target: AgentTarget.fromJson(_object(json['target'])),
    name: _string(json, 'name'),
    provider: _string(json, 'provider'),
    activity: _enum(json, 'activity', AgentActivity.values),
    lifecycle: _enum(json, 'lifecycle', AgentLifecycle.values),
    updatedAt: _date(json['updatedAt']),
    preview: _string(json, 'preview', empty: true),
    connected: _bool(json, 'connected'),
    canControl: _bool(json, 'canControl'),
  );
}

@immutable
class ApprovalRule {
  const ApprovalRule({
    required this.id,
    required this.label,
    required this.scope,
  });
  final String id;
  final String label;
  final String scope;
  factory ApprovalRule.fromJson(Map<String, Object?> json) => ApprovalRule(
    id: _string(json, 'id'),
    label: _string(json, 'label'),
    scope: _string(json, 'scope'),
  );
}

@immutable
class SessionRule {
  const SessionRule({required this.target, required this.rule});
  final AgentTarget target;
  final ApprovalRule rule;
  factory SessionRule.fromJson(Map<String, Object?> json) => SessionRule(
    target: AgentTarget.fromJson(_object(json['target'])),
    rule: ApprovalRule.fromJson(_object(json['rule'])),
  );
}

@immutable
class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    required this.target,
    required this.summary,
    required this.command,
    required this.expiresAt,
    required this.state,
    this.rules = const [],
    this.closeReason,
  });
  final String id;
  final AgentTarget target;
  final String summary;
  final String command;
  final DateTime expiresAt;
  final ApprovalState state;
  final List<ApprovalRule> rules;
  final String? closeReason;
  bool isPending(DateTime now) =>
      state == ApprovalState.pending && now.isBefore(expiresAt);
  String get key => '${target.key}:$id';
  factory ApprovalRequest.fromJson(Map<String, Object?> json) =>
      ApprovalRequest(
        id: _string(json, 'id'),
        target: AgentTarget.fromJson(_object(json['target'])),
        summary: _string(json, 'summary'),
        command: _string(json, 'command', empty: true),
        expiresAt: _date(json['expiresAt']),
        state: _enum(json, 'state', ApprovalState.values),
        rules: _list(json['rules'], ApprovalRule.fromJson, maximum: 32),
        closeReason: json['closeReason'] as String?,
      );
}

@immutable
class ToolActivity {
  const ToolActivity({required this.title, required this.detail});
  final String title;
  final String detail;
  factory ToolActivity.fromJson(Map<String, Object?> json) => ToolActivity(
    title: _string(json, 'title'),
    detail: _string(json, 'detail', empty: true),
  );
}

@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.markdown,
    required this.createdAt,
    this.tools = const [],
  });
  final String id;
  final MessageRole role;
  final String markdown;
  final DateTime createdAt;
  final List<ToolActivity> tools;
  factory ChatMessage.fromJson(Map<String, Object?> json) => ChatMessage(
    id: _string(json, 'id'),
    role: _enum(json, 'role', MessageRole.values),
    markdown: _string(json, 'markdown', empty: true, maximum: 262144),
    createdAt: _date(json['createdAt']),
    tools: _list(json['tools'], ToolActivity.fromJson, maximum: 64),
  );
}

@immutable
class Conversation {
  const Conversation({
    required this.target,
    this.messages = const [],
    this.loading = false,
    this.canLoadEarlier = false,
    this.notice,
  });
  final AgentTarget target;
  final List<ChatMessage> messages;
  final bool loading;
  final bool canLoadEarlier;
  final String? notice;
  factory Conversation.fromJson(Map<String, Object?> json) => Conversation(
    target: AgentTarget.fromJson(_object(json['target'])),
    messages: _list(json['messages'], ChatMessage.fromJson, maximum: 500),
    loading: _bool(json, 'loading'),
    canLoadEarlier: _bool(json, 'canLoadEarlier'),
    notice: json['notice'] as String?,
  );
}

@immutable
class LaunchProfile {
  const LaunchProfile({
    required this.host,
    required this.id,
    required this.name,
    required this.provider,
    required this.project,
  });
  final String host;
  final String id;
  final String name;
  final String provider;
  final String project;
  factory LaunchProfile.fromJson(Map<String, Object?> json) => LaunchProfile(
    host: _string(json, 'host'),
    id: _string(json, 'id'),
    name: _string(json, 'name'),
    provider: _string(json, 'provider'),
    project: _string(json, 'project', empty: true),
  );
}

@immutable
class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.context,
    required this.revision,
    required this.environment,
    this.account,
    this.access = DeviceAccess.notEnrolled,
    this.deviceName = 'This device',
    this.deviceId = '',
    this.loginAvailable = false,
    this.enrollmentAvailable = false,
    this.hosts = const [],
    this.agents = const [],
    this.approvals = const [],
    this.profiles = const [],
    this.conversations = const [],
    this.rules = const [],
    this.notice,
    this.preview = false,
  });
  final String context;
  final int revision;
  final ServerEnvironment environment;
  final AccountSummary? account;
  final DeviceAccess access;
  final String deviceName;
  final String deviceId;
  final bool loginAvailable;
  final bool enrollmentAvailable;
  final List<HostSummary> hosts;
  final List<AgentSummary> agents;
  final List<ApprovalRequest> approvals;
  final List<LaunchProfile> profiles;
  final List<Conversation> conversations;
  final List<SessionRule> rules;
  final String? notice;
  final bool preview;

  factory WorkspaceSnapshot.fromJson(Map<String, Object?> json) {
    if (json['bridgeVersion'] != 1) {
      throw const FormatException('Update Astation to use this native bridge.');
    }
    final result = WorkspaceSnapshot(
      context: _string(json, 'context'),
      revision: _integer(json, 'revision'),
      environment: _enum(json, 'environment', ServerEnvironment.values),
      account: json['account'] == null
          ? null
          : AccountSummary.fromJson(_object(json['account'])),
      access: _enum(json, 'access', DeviceAccess.values),
      deviceName: _string(json, 'deviceName'),
      deviceId: _string(json, 'deviceId', empty: true),
      loginAvailable: _bool(json, 'loginAvailable'),
      enrollmentAvailable: json.containsKey('enrollmentAvailable')
          ? _bool(json, 'enrollmentAvailable')
          : false,
      hosts: _list(json['hosts'], HostSummary.fromJson, maximum: 256),
      agents: _list(json['agents'], AgentSummary.fromJson, maximum: 1024),
      approvals: _list(
        json['approvals'],
        ApprovalRequest.fromJson,
        maximum: 1024,
      ),
      profiles: _list(json['profiles'], LaunchProfile.fromJson, maximum: 1024),
      conversations: _list(
        json['conversations'],
        Conversation.fromJson,
        maximum: 8,
      ),
      rules: _list(json['rules'], SessionRule.fromJson, maximum: 1024),
      notice: json['notice'] as String?,
    );
    final account = result.account?.id;
    final hosts = result.hosts.map((host) => host.id).toSet();
    final targets = result.agents.map((agent) => agent.target).toSet();
    if (hosts.length != result.hosts.length ||
        targets.length != result.agents.length ||
        result.agents.any(
          (agent) =>
              agent.target.account != account ||
              !hosts.contains(agent.target.host),
        ) ||
        result.conversations.any((chat) => !targets.contains(chat.target)) ||
        result.approvals.any(
          (approval) => !targets.contains(approval.target),
        ) ||
        result.rules.any((rule) => !targets.contains(rule.target)) ||
        result.profiles.any((profile) => !hosts.contains(profile.host)) ||
        (account == null &&
            (result.hosts.isNotEmpty ||
                result.access != DeviceAccess.notEnrolled))) {
      throw const FormatException(
        'The workspace security context changed. Reconnect.',
      );
    }
    return result;
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map) throw const FormatException('Invalid native response.');
  return Map<String, Object?>.from(value);
}

List<T> _list<T>(
  Object? value,
  T Function(Map<String, Object?>) parse, {
  required int maximum,
}) {
  if (value is! List || value.length > maximum) {
    throw const FormatException('Invalid native list.');
  }
  return List.unmodifiable(value.map((item) => parse(_object(item))));
}

String _string(
  Map<String, Object?> json,
  String key, {
  bool empty = false,
  int maximum = 4096,
}) {
  final value = json[key];
  if (value is! String || (!empty && value.isEmpty) || value.length > maximum) {
    throw FormatException('Invalid native $key.');
  }
  return value;
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 0 || value > 9007199254740991) {
    throw FormatException('Invalid native $key.');
  }
  return value;
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid native $key.');
  return value;
}

T _enum<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
) => values.firstWhere(
  (value) => value.name == json[key],
  orElse: () => throw FormatException('Invalid native $key.'),
);
DateTime _date(Object? value) => value is String
    ? DateTime.parse(value).toUtc()
    : throw const FormatException('Invalid native date.');
DateTime? _optionalDate(Object? value) => value == null ? null : _date(value);
