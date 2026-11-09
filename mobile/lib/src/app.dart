import 'dart:async';

import 'package:flutter/material.dart';

import 'adaptive.dart';
import 'chat.dart';
import 'controller.dart';
import 'gateway.dart';
import 'theme.dart';
import 'welcome.dart';
import 'workspace.dart';

class AstationApp extends StatefulWidget {
  const AstationApp({super.key, required this.gateway});
  final AstationGateway gateway;
  @override
  State<AstationApp> createState() => _AstationAppState();
}

class _AstationAppState extends State<AstationApp> with WidgetsBindingObserver {
  late final controller = WorkspaceController(widget.gateway);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(controller.start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(controller.setForeground(state == AppLifecycleState.resumed));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Astation',
    debugShowCheckedModeBanner: false,
    theme: astationTheme(),
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PopScope(
        canPop: controller.selected == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) controller.closeConversation();
        },
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(.8, 0),
                radius: 1.2,
                colors: [Color(0xFFF0F3E9), AppColors.paper],
              ),
            ),
            child: Column(
              children: [
                if (controller.error != null)
                  SafeArea(
                    bottom: false,
                    child: MaterialBanner(
                      backgroundColor: AppColors.sage,
                      content: Text(
                        controller.error!,
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                      actions: [
                        TextButton(
                          onPressed: controller.clearError,
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: controller.loading
                      ? const Center(child: CircularProgressIndicator())
                      : controller.snapshot?.account == null
                      ? WelcomeScreen(controller: controller)
                      : SafeArea(
                          child: AdaptiveWorkspace(
                            hasSelection: controller.selected != null,
                            master: WorkspaceMaster(controller: controller),
                            detail: controller.selected == null
                                ? const EmptyConversation()
                                : ConversationPane(
                                    key: ValueKey(controller.selected),
                                    controller: controller,
                                    target: controller.selected!,
                                  ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
