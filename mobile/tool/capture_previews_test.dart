import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:astation_mobile/preview/preview_gateway.dart';
import 'package:astation_mobile/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('capture the actual Flutter welcome, chats and conversation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      for (final family in ['PlexSans', 'PlexSerif', 'PlexMono']) {
        await (FontLoader(
          family,
        )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    final gateway = PreviewGateway();
    const boundaryKey = ValueKey('capture');
    Future<void> capture(String name, Size viewport) async {
      tester.view.physicalSize = viewport;
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ImageByteFormat.png);
        final file = File('../.build/mobile-preview/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    }

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: AstationApp(gateway: gateway),
      ),
    );
    await capture('phone-welcome', const Size(390, 844));
    await gateway.signIn();
    await capture('phone-chats', const Size(390, 844));
    await tester.ensureVisible(find.text('Astation mobile').last);
    await tester.tap(find.text('Astation mobile').last);
    await capture('phone-conversation', const Size(390, 844));
    await capture('tablet-conversation', const Size(1024, 768));
    await tester.pumpWidget(const SizedBox.shrink());
    await gateway.dispose();
  });
}
