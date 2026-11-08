import 'dart:async';

import 'package:astation_mobile/preview/preview_gateway.dart';
import 'package:astation_mobile/src/controller.dart';
import 'package:astation_mobile/src/gateway.dart';
import 'package:astation_mobile/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final clock = DateTime.utc(2026, 11, 3, 12);
  late PreviewGateway gateway;
  late WorkspaceController controller;
  setUp(() async {
    gateway = PreviewGateway(signedIn: true, clock: clock);
    controller = WorkspaceController(gateway, now: () => clock);
    await controller.start();
  });
  tearDown(() async {
    controller.dispose();
    await gateway.dispose();
  });

  test(
    'opening conversations keeps activity order and separate drafts',
    () async {
      final order = controller.recentAgents.map((item) => item.target).toList();
      controller.saveDraft(PreviewGateway.codex, 'Codex draft');
      controller.saveDraft(PreviewGateway.claude, 'Claude draft');
      await controller.selectConversation(PreviewGateway.claude);
      await controller.selectConversation(PreviewGateway.codex);
      expect(controller.recentAgents.map((item) => item.target), order);
      expect(controller.draft(PreviewGateway.claude), 'Claude draft');
      expect(controller.draft(PreviewGateway.codex), 'Codex draft');
    },
  );

  test('send clears only the admitted target draft', () async {
    controller.saveDraft(PreviewGateway.codex, 'Please review');
    controller.saveDraft(PreviewGateway.claude, 'Keep me');
    expect((await controller.send(PreviewGateway.codex))?.status, 'completed');
    expect(controller.draft(PreviewGateway.codex), isEmpty);
    expect(controller.draft(PreviewGateway.claude), 'Keep me');
    expect(gateway.commandCount, 1);
  });

  test('takeover requires the exact observed controller and epoch', () async {
    gateway.holder = const ControllerReference(
      'other-attachment',
      7,
      'Other phone',
    );
    controller.saveDraft(PreviewGateway.codex, 'Please review');
    final refused = await controller.send(PreviewGateway.codex);
    expect(refused?.status, 'takeoverRequired');
    expect(controller.draft(PreviewGateway.codex), 'Please review');
    gateway.holder = const ControllerReference('new-attachment', 8, 'Tablet');
    final stale = await controller.send(
      PreviewGateway.codex,
      takeover: refused!.controller,
    );
    expect(stale?.status, 'takeoverRequired');
    expect(gateway.lastTakeover?.epoch, 7);
    expect(gateway.sent, isEmpty);
    expect(
      (await controller.send(
        PreviewGateway.codex,
        takeover: stale!.controller,
      ))?.status,
      'completed',
    );
    expect(gateway.sent[PreviewGateway.codex], hasLength(1));
  });

  test('double tap cannot submit a prompt twice', () async {
    gateway.commandBarrier = Completer<CommandResult>();
    controller.saveDraft(PreviewGateway.codex, 'Run once');
    final first = controller.send(PreviewGateway.codex);
    expect(await controller.send(PreviewGateway.codex), isNull);
    expect(gateway.commandCount, 1);
    gateway.commandBarrier!.complete(
      const CommandResult(requestId: 'one', status: 'accepted'),
    );
    await first;
    expect(controller.draft(PreviewGateway.codex), isEmpty);
  });

  test('sign out fences an in-flight command immediately', () async {
    gateway.commandBarrier = Completer<CommandResult>();
    controller.saveDraft(PreviewGateway.codex, 'Run once');
    final pending = controller.send(PreviewGateway.codex);
    await controller.signOut();
    expect(controller.snapshot?.account, isNull);
    expect(controller.busy, isFalse);
    expect(controller.draft(PreviewGateway.codex), isEmpty);
    gateway.commandBarrier!.complete(
      const CommandResult(requestId: 'late', status: 'accepted'),
    );
    expect(await pending, isNull);
    expect(controller.snapshot?.account, isNull);
    expect(controller.error, isNull);
  });

  test('server change signs out and clears selection and drafts', () async {
    controller.saveDraft(PreviewGateway.codex, 'Sensitive draft');
    await controller.selectConversation(PreviewGateway.codex);
    await controller.selectEnvironment(ServerEnvironment.production);
    expect(controller.snapshot?.environment, ServerEnvironment.production);
    expect(controller.snapshot?.account, isNull);
    expect(controller.selected, isNull);
    expect(controller.draft(PreviewGateway.codex), isEmpty);
  });

  test('login alone cannot operate, view permission cannot mutate', () async {
    for (final access in [
      DeviceAccess.notEnrolled,
      DeviceAccess.view,
      DeviceAccess.revoked,
    ]) {
      gateway.access = access;
      gateway.emit();
      await Future<void>.delayed(Duration.zero);
      controller.saveDraft(PreviewGateway.codex, 'Must not send');
      expect(await controller.send(PreviewGateway.codex), isNull);
      expect(
        await controller.launch(controller.snapshot!.profiles.first),
        isNull,
      );
      expect(
        await controller.answer(
          controller.snapshot!.approvals.first,
          'allowOnce',
        ),
        isNull,
      );
    }
    expect(gateway.commandCount, 0);
  });

  test(
    'backgrounding fences mutations and returning refreshes state',
    () async {
      await controller.setForeground(false);
      controller.saveDraft(PreviewGateway.codex, 'Wait');
      expect(await controller.send(PreviewGateway.codex), isNull);
      expect(gateway.commandCount, 0);
      await controller.setForeground(true);
      expect(controller.canOperate(PreviewGateway.codex), isTrue);
      expect(controller.draft(PreviewGateway.codex), 'Wait');
    },
  );

  test(
    'approval answers use host-offered exact rules without taking a lease',
    () async {
      final request = controller.snapshot!.approvals.first;
      const wrong = ApprovalRule(
        id: 'rule-test',
        label: 'Allow everything',
        scope: 'account',
      );
      expect(
        await controller.answer(request, 'allowAlways', rule: wrong),
        isNull,
      );
      expect(gateway.commandCount, 0);
      expect(
        (await controller.answer(
          request,
          'allowAlways',
          rule: request.rules.first,
        ))?.status,
        'completed',
      );
      expect(gateway.lastRule, 'rule-test');
      expect(gateway.lastDecision, 'allowAlways');
      await Future<void>.delayed(Duration.zero);
      expect(await controller.answer(request, 'allowOnce'), isNull);
      expect(gateway.commandCount, 1);
      final before = gateway.holder;
      await controller.revokeRule(request.target, 'rule-test');
      expect(gateway.holder, before);
      expect(gateway.rules, isEmpty);
    },
  );

  test('expiry refuses an otherwise pending approval', () async {
    final request = controller.snapshot!.approvals.first;
    final expired = ApprovalRequest(
      id: request.id,
      target: request.target,
      summary: request.summary,
      command: request.command,
      expiresAt: clock,
      state: ApprovalState.pending,
      rules: request.rules,
    );
    expect(await controller.answer(expired, 'allowOnce'), isNull);
    expect(gateway.commandCount, 0);
  });

  test('only approved host profiles can launch', () async {
    const arbitrary = LaunchProfile(
      host: 'genie-preview',
      id: 'arbitrary-command',
      name: 'Shell',
      provider: 'shell',
      project: '/',
    );
    expect(await controller.launch(arbitrary), isNull);
    expect(gateway.commandCount, 0);
    expect(
      (await controller.launch(controller.snapshot!.profiles.first))?.status,
      'completed',
    );
    expect(gateway.commandCount, 1);
  });

  test('unsafe links never reach the native browser', () async {
    for (final uri in [
      'javascript:alert(1)',
      'http://example.org',
      'https://user:pass@example.org',
    ]) {
      await controller.openExternal(Uri.parse(uri));
    }
    expect(gateway.lastExternal, isNull);
    await controller.openExternal(Uri.parse('https://vox.agora.build'));
    expect(gateway.lastExternal?.host, 'vox.agora.build');
  });
}
