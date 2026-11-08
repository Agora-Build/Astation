import 'dart:async';

import 'package:astation_mobile/preview/preview_gateway.dart';
import 'package:astation_mobile/src/app.dart';
import 'package:astation_mobile/src/controller.dart';
import 'package:astation_mobile/src/device_access.dart';
import 'package:astation_mobile/src/gateway.dart';
import 'package:astation_mobile/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class EnrollmentGateway extends PreviewGateway {
  EnrollmentGateway({this.available = false}) : super(signedIn: true);
  final bool available;
  int enrollmentCalls = 0;
  Completer<void>? pending;

  @override
  WorkspaceSnapshot state() => WorkspaceSnapshot(
    context: 'test-$generation',
    revision: revision,
    environment: environment,
    account: signedIn
        ? const AccountSummary(id: 'account', name: 'Owner')
        : null,
    access: signedIn ? access : DeviceAccess.notEnrolled,
    enrollmentAvailable: available,
  );

  @override
  Future<void> enrollDevice() async {
    enrollmentCalls++;
    if (pending != null) return pending!.future;
    throw const GatewayFailure(
      'enrollment_not_ready',
      'Device setup is unavailable.',
    );
  }
}

void main() {
  testWidgets('all device setup entries explain unavailable enrollment', (
    tester,
  ) async {
    final gateway = EnrollmentGateway()..access = DeviceAccess.notEnrolled;
    await tester.pumpWidget(AstationApp(gateway: gateway));
    await tester.pumpAndSettle();
    expect(find.textContaining(deviceSetupUnavailable), findsOneWidget);
    expect(find.text('Set up access'), findsNothing);

    await tester.tap(find.text('View setup status'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in to Agora.Build'), findsOneWidget);
    expect(find.text(deviceSetupUnavailable), findsOneWidget);
    expect(find.text('Start device setup'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open account'));
    await tester.pumpAndSettle();
    for (final entry in ['Devices & security', 'This device']) {
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View setup status'));
      await tester.pumpAndSettle();
      expect(find.text(deviceSetupUnavailable), findsOneWidget);
      expect(find.text('Start device setup'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('View setup status'))).pop();
      await tester.pumpAndSettle();
    }
    expect(gateway.enrollmentCalls, 0);
    expect(gateway.access, DeviceAccess.notEnrolled);
    await tester.pumpWidget(const SizedBox.shrink());
    await gateway.dispose();
  });

  testWidgets(
    'enrollment errors stay visible above the account sheet on resume',
    (tester) async {
      final gateway = EnrollmentGateway(available: true)
        ..access = DeviceAccess.notEnrolled;
      await tester.pumpWidget(AstationApp(gateway: gateway));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices & security'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up access'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start device setup'));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet).last;
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('Device setup is unavailable.'),
        ),
        findsOneWidget,
      );
      expect(gateway.enrollmentCalls, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('Device setup is unavailable.'),
        ),
        findsOneWidget,
      );
      expect(gateway.access, DeviceAccess.notEnrolled);
      await tester.pumpWidget(const SizedBox.shrink());
      await gateway.dispose();
    },
  );

  test('enrollment is refused when unsupported, signed out, revoked or in the background', () async {
    for (final available in [false, true]) {
      final gateway = EnrollmentGateway(available: available);
      final controller = WorkspaceController(gateway);
      await controller.start();
      for (final access in [
        DeviceAccess.control,
        DeviceAccess.view,
        DeviceAccess.revoked,
      ]) {
        gateway.access = access;
        await controller.refresh();
        await controller.enrollDevice();
      }
      gateway.access = DeviceAccess.notEnrolled;
      await controller.refresh();
      await controller.setForeground(false);
      await controller.enrollDevice();
      await controller.setForeground(true);
      if (!available) await controller.enrollDevice();
      await controller.signOut();
      await controller.enrollDevice();
      expect(gateway.enrollmentCalls, 0);
      controller.dispose();
      await gateway.dispose();
    }
  });

  test(
    'enrollment cannot be started twice while a request is pending',
    () async {
      final gateway = EnrollmentGateway(available: true)
        ..access = DeviceAccess.notEnrolled
        ..pending = Completer<void>();
      final controller = WorkspaceController(gateway);
      await controller.start();
      final first = controller.enrollDevice();
      expect(controller.canEnroll, isFalse);
      await controller.enrollDevice();
      expect(gateway.enrollmentCalls, 1);
      gateway.pending!.complete();
      await first;
      expect(controller.snapshot!.access, DeviceAccess.notEnrolled);
      controller.dispose();
      await gateway.dispose();
    },
  );
}
