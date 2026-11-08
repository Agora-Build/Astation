import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'theme.dart';

const deviceSetupUnavailable =
    'Device setup is not available in this build yet.';

class DeviceAccessButton extends StatelessWidget {
  const DeviceAccessButton({super.key, required this.controller});
  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: () => _showDeviceAccess(context, controller),
    child: Text(
      controller.snapshot?.enrollmentAvailable == true
          ? 'Set up access'
          : 'View setup status',
    ),
  );
}

Future<void> _showDeviceAccess(
  BuildContext context,
  WorkspaceController controller,
) {
  final securityContext = controller.snapshot?.context;
  String? setupError;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final state = controller.snapshot;
          final changed =
              state?.context != securityContext || state?.account == null;
          final verified =
              state?.access == DeviceAccess.view ||
              state?.access == DeviceAccess.control;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Device access',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 20),
                if (changed)
                  const Text(
                    'Your account changed. Close this screen and open device setup again.',
                  )
                else ...[
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.check_circle_outline,
                      color: AppColors.olive,
                    ),
                    title: Text('Signed in to Agora.Build'),
                    subtitle: Text(
                      'Your account sign-in is saved on this device.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    verified
                        ? 'This device is verified.'
                        : state!.access == DeviceAccess.revoked
                        ? 'Access to this device has been revoked.'
                        : state.enrollmentAvailable
                        ? 'Approve this device from a trusted Astation device and compare the safety code.'
                        : deviceSetupUnavailable,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      height: 1.6,
                    ),
                  ),
                  if (!verified && !state!.enrollmentAvailable) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'This build supports account sign-in, but cannot add trusted phones yet. '
                      'Agent chats and approvals stay locked until this device is verified. '
                      'Signing in again will not enable access.',
                      style: TextStyle(color: AppColors.muted, height: 1.6),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Text(
                    state!.environment.station,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
                  if (state.access == DeviceAccess.notEnrolled &&
                      state.enrollmentAvailable) ...[
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: !controller.canEnroll
                          ? null
                          : () async {
                              setSheetState(() => setupError = null);
                              await controller.enrollDevice();
                              if (sheetContext.mounted &&
                                  controller.snapshot?.context ==
                                      securityContext) {
                                setSheetState(
                                  () => setupError = controller.error,
                                );
                              }
                            },
                      child: Text(
                        controller.busy
                            ? 'Starting setup...'
                            : 'Start device setup',
                      ),
                    ),
                  ],
                  if (setupError != null) ...[
                    const SizedBox(height: 16),
                    Semantics(liveRegion: true, child: Text(setupError!)),
                  ],
                ],
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
