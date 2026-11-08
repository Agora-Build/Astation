import 'package:flutter/services.dart';

import 'models.dart';

class GatewayFailure implements Exception {
  const GatewayFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class ControllerReference {
  const ControllerReference(this.session, this.epoch, this.label);
  final String session;
  final int epoch;
  final String label;
  Map<String, Object?> toJson() => {
    'controllerSession': session,
    'leaseEpoch': epoch,
  };
}

class CommandResult {
  const CommandResult({
    required this.requestId,
    required this.status,
    this.detail,
    this.controller,
  });
  final String requestId;
  final String status;
  final String? detail;
  final ControllerReference? controller;

  factory CommandResult.fromJson(Map<String, Object?> json) {
    final holder = json['controller'];
    return CommandResult(
      requestId: json['requestId'] as String,
      status: json['status'] as String,
      detail: json['detail'] as String?,
      controller: holder is Map
          ? ControllerReference(
              holder['controllerSession'] as String,
              holder['leaseEpoch'] as int,
              holder['label'] as String,
            )
          : null,
    );
  }
}

abstract class AstationGateway {
  Stream<WorkspaceSnapshot> get changes;
  Future<WorkspaceSnapshot> readState();
  Future<void> signIn();
  Future<void> signOut();
  Future<void> selectEnvironment(ServerEnvironment environment);
  Future<void> refresh();
  Future<void> setForeground(bool foreground);
  Future<void> enrollDevice();
  Future<void> openExternal(Uri uri);
  Future<void> watchConversation(String context, AgentTarget target);
  Future<void> loadEarlier(String context, AgentTarget target);
  Future<CommandResult> sendPrompt(
    String context,
    AgentTarget target,
    String text, {
    ControllerReference? takeover,
  });
  Future<CommandResult> answerApproval(
    String context,
    ApprovalRequest request,
    String decision, {
    String? ruleId,
    String? message,
  });
  Future<CommandResult> revokeRule(
    String context,
    AgentTarget target,
    String ruleId,
  );
  Future<CommandResult> launchAgent(String context, LaunchProfile profile);
  Future<CommandResult> lookupReceipt(
    String context,
    AgentTarget target,
    String requestId,
  );
}

/// Only presentation data and typed intents cross this boundary. Native code
/// retains tokens, private keys, signed checkpoints and durable request IDs.
class NativeGateway implements AstationGateway {
  const NativeGateway();
  static const _methods = MethodChannel('build.agora.astation/mobile.v1');
  static const _events = EventChannel('build.agora.astation/workspace.v1');

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw const GatewayFailure(
        'native_unavailable',
        'Open Astation on an iPhone, iPad or Android device.',
      );
    } on PlatformException catch (error) {
      throw GatewayFailure(
        error.code,
        error.message ?? 'The operation could not be completed.',
      );
    }
  }

  @override
  Stream<WorkspaceSnapshot> get changes => _events.receiveBroadcastStream().map(
    (event) =>
        WorkspaceSnapshot.fromJson(Map<String, Object?>.from(event as Map)),
  );
  @override
  Future<WorkspaceSnapshot> readState() async => WorkspaceSnapshot.fromJson(
    Map<String, Object?>.from((await _invoke<Map>('readState'))!),
  );
  @override
  Future<void> signIn() => _invoke<void>('signIn');
  @override
  Future<void> signOut() => _invoke<void>('signOut');
  @override
  Future<void> selectEnvironment(ServerEnvironment environment) =>
      _invoke<void>('selectEnvironment', {'environment': environment.name});
  @override
  Future<void> refresh() => _invoke<void>('refresh');
  @override
  Future<void> setForeground(bool foreground) =>
      _invoke<void>('setForeground', {'foreground': foreground});
  @override
  Future<void> enrollDevice() => _invoke<void>('enrollDevice');
  @override
  Future<void> openExternal(Uri uri) =>
      _invoke<void>('openExternal', {'url': uri.toString()});
  Map<String, Object?> _target(String context, AgentTarget target) => {
    'context': context,
    'target': target.toJson(),
  };
  @override
  Future<void> watchConversation(String context, AgentTarget target) =>
      _invoke<void>('watchConversation', _target(context, target));
  @override
  Future<void> loadEarlier(String context, AgentTarget target) =>
      _invoke<void>('loadEarlier', _target(context, target));
  Future<CommandResult> _command(
    String method,
    Map<String, Object?> args,
  ) async => CommandResult.fromJson(
    Map<String, Object?>.from((await _invoke<Map>(method, args))!),
  );
  @override
  Future<CommandResult> sendPrompt(
    String context,
    AgentTarget target,
    String text, {
    ControllerReference? takeover,
  }) => _command('sendPrompt', {
    ..._target(context, target),
    'text': text,
    if (takeover != null) 'expectedController': takeover.toJson(),
  });
  @override
  Future<CommandResult> answerApproval(
    String context,
    ApprovalRequest request,
    String decision, {
    String? ruleId,
    String? message,
  }) => _command('answerApproval', {
    ..._target(context, request.target),
    'approvalId': request.id,
    'decision': decision,
    'ruleId': ?ruleId,
    'message': ?message,
  });
  @override
  Future<CommandResult> revokeRule(
    String context,
    AgentTarget target,
    String ruleId,
  ) => _command('revokeRule', {..._target(context, target), 'ruleId': ruleId});
  @override
  Future<CommandResult> launchAgent(String context, LaunchProfile profile) =>
      _command('launchAgent', {
        'context': context,
        'host': profile.host,
        'profileId': profile.id,
      });
  @override
  Future<CommandResult> lookupReceipt(
    String context,
    AgentTarget target,
    String requestId,
  ) => _command('lookupReceipt', {
    ..._target(context, target),
    'requestId': requestId,
  });
}
