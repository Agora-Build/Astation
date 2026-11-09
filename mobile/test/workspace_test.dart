import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:astation_mobile/preview/preview_gateway.dart';
import 'package:astation_mobile/src/app.dart';
import 'package:astation_mobile/src/chat.dart';
import 'package:astation_mobile/src/controller.dart';
import 'package:astation_mobile/src/theme.dart';
import 'package:astation_mobile/src/welcome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final viewport in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(1024, 768),
    const Size(1114, 720),
    const Size(720, 1114),
  ]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('welcome fits $viewport at text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final gateway = PreviewGateway();
        final controller = WorkspaceController(gateway);
        await controller.start();
        final features = <DisplayFeature>[
          if (viewport.width == 1114)
            const DisplayFeature(
              bounds: Rect.fromLTWH(540, 0, 34, 720),
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureFlat,
            ),
          if (viewport.height == 1114)
            const DisplayFeature(
              bounds: Rect.fromLTWH(0, 540, 720, 34),
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureHalfOpened,
            ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: astationTheme(),
            home: MediaQuery(
              data: MediaQueryData(
                size: viewport,
                textScaler: TextScaler.linear(scale),
                displayFeatures: features,
              ),
              child: Scaffold(body: WelcomeScreen(controller: controller)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.smartphone_rounded), findsOneWidget);
        await tester.tap(
          find.byTooltip('Show Vox Realtime'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await gateway.dispose();
      });
    }
  }

  testWidgets('preview signs in, switches conversations and keeps drafts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = PreviewGateway(signedIn: true);
    await tester.pumpWidget(AstationApp(gateway: gateway));
    await tester.pumpAndSettle();
    expect(find.text('DESIGN PREVIEW · SAMPLE DATA'), findsOneWidget);
    await tester.ensureVisible(find.text('Astation mobile').last);
    await tester.tap(find.text('Astation mobile').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      'A draft for Codex',
    );
    await tester.longPress(find.text('Astation mobile').first);
    await tester.pumpAndSettle();
    expect(find.text('Switch conversation'), findsOneWidget);
    expect(find.text('Show all agents'), findsOneWidget);
    await tester.tap(find.text('Relay reliability'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.longPress(find.text('Relay reliability').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Astation mobile'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .controller!
          .text,
      'A draft for Codex',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await gateway.dispose();
  });

  testWidgets('closed approval cards expose no action buttons', (tester) async {
    final gateway = PreviewGateway(signedIn: true)
      ..answered.add('approval-test');
    final controller = WorkspaceController(gateway);
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(
        theme: astationTheme(),
        home: Scaffold(
          body: ApprovalCard(
            controller: controller,
            request: controller.snapshot!.approvals.first,
          ),
        ),
      ),
    );
    expect(find.text('Answered on this preview device'), findsOneWidget);
    expect(find.text('Allow once'), findsNothing);
    expect(find.text('Always allow'), findsNothing);
    expect(find.text('Deny'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await gateway.dispose();
  });
}
