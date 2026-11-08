import 'dart:convert';

import 'package:astation_mobile/main.dart' as app;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'dev browser login, refresh rotation and Station token acceptance',
    (tester) async {
      app.main();
      await tester.pumpAndSettle();
      const native = MethodChannel('build.agora.astation/mobile.v1');
      await tester.runAsync(() async {
        await native.invokeMethod<void>('selectEnvironment', {
          'environment': 'development',
        });
        // Complete account login and the app confirmation in the system browser.
        await native.invokeMethod<void>('signIn');
        final evidence = Map<String, Object?>.from(
          (await native.invokeMethod<Map>('verifyLogin'))!,
        );
        expect(evidence['clientId'], anyOf('astation-ios', 'astation-android'));
        expect(evidence['station'], 'https://station-dev.agora.build');
        expect(evidence['refreshRotated'], true);
        expect(evidence['authTimeUnchanged'], true);
        expect(evidence['stationTokenAccepted'], true);
        // This test does not enroll the phone or claim an authenticated R9 channel.
        expect(evidence['memberChannelVerified'], false);
        // Only these redacted flags leave native code; credentials stay native.
        // ignore: avoid_print
        print('MOBILE_LOGIN_EVIDENCE ${jsonEncode(evidence)}');
      });
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
