import 'package:astation_mobile/preview/preview_gateway.dart';
import 'package:astation_mobile/src/chat.dart';
import 'package:astation_mobile/src/controller.dart';
import 'package:astation_mobile/src/models.dart';
import 'package:astation_mobile/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rich replies render without loading tracking images or HTML', (
    tester,
  ) async {
    final gateway = PreviewGateway(signedIn: true);
    final controller = WorkspaceController(gateway);
    await controller.start();
    final message = ChatMessage(
      id: 'rich',
      role: MessageRole.assistant,
      createdAt: DateTime.utc(2026),
      markdown:
          '# Result\n\nA **formatted** reply.\n\n'
          '| Check | Result |\n| --- | --- |\n| SDK | Ready |\n\n'
          '```dart\nawait refresh();\n```\n\n'
          '![tracking](https://example.org/tracker.png)\n\n'
          '<script>alert("never execute")</script>',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: astationTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageView(
              message: message,
              provider: 'Codex',
              controller: controller,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('[Image: tracking]'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byTooltip('Copy reply'), findsOneWidget);
    expect(gateway.lastExternal, isNull);
    expect(gateway.commandCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await gateway.dispose();
  });
}
