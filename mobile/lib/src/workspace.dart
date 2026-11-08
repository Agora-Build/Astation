import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import 'chat.dart';
import 'controller.dart';
import 'device_access.dart';
import 'models.dart';
import 'theme.dart';

class WorkspaceMaster extends StatelessWidget {
  const WorkspaceMaster({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: AppColors.line)),
    ),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 12, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const AstationBrand(),
              IconButton(
                tooltip: 'Open account',
                onPressed: () => controller.selectTab(WorkspaceTab.account),
                icon: CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xFFDFE8D2),
                  child: Text(
                    _initials(controller.snapshot?.account?.name ?? ''),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deep,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (controller.snapshot?.preview ?? false)
          Container(
            width: double.infinity,
            color: AppColors.sage,
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 16),
            child: const Text(
              'DESIGN PREVIEW · SAMPLE DATA',
              style: TextStyle(
                fontFamily: 'PlexMono',
                fontSize: 9,
                color: AppColors.deep,
              ),
            ),
          ),
        Expanded(
          child: switch (controller.tab) {
            WorkspaceTab.chats => ChatsHome(controller: controller),
            WorkspaceTab.agents => AgentsHome(controller: controller),
            WorkspaceTab.account => AccountHome(controller: controller),
          },
        ),
        const Divider(height: 1),
        NavigationBar(
          selectedIndex: controller.tab.index,
          onDestinationSelected: (index) =>
              controller.selectTab(WorkspaceTab.values[index]),
          destinations: [
            NavigationDestination(
              icon: Badge(
                isLabelVisible: controller.pendingApprovals.isNotEmpty,
                label: Text('${controller.pendingApprovals.length}'),
                child: const Icon(Icons.chat_bubble_outline_rounded),
              ),
              label: 'Chats',
            ),
            const NavigationDestination(
              icon: Icon(Icons.dns_outlined),
              label: 'Agents',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              label: 'Account',
            ),
          ],
        ),
      ],
    ),
  );
}

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .take(2);
  return parts.map((part) => part.characters.first.toUpperCase()).join();
}

class ChatsHome extends StatelessWidget {
  const ChatsHome({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: controller.refresh,
    child: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Chats',
              style: TextStyle(fontFamily: 'PlexSerif', fontSize: 32),
            ),
            IconButton(
              tooltip: 'Find or create an agent',
              onPressed: () => controller.selectTab(WorkspaceTab.agents),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const Text(
          'Pick up where you left off.',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        if (controller.snapshot?.access == DeviceAccess.notEnrolled) ...[
          const SizedBox(height: 20),
          _EnrollmentCard(controller: controller),
        ],
        if (controller.pendingApprovals.isNotEmpty)
          ApprovalDeck(controller: controller)
        else
          const Padding(
            padding: EdgeInsets.only(top: 26, bottom: 8),
            child: Row(
              children: [
                Icon(Icons.check, size: 16, color: AppColors.olive),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'No approvals waiting',
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ),
              ],
            ),
          ),
        SectionLabel(
          'Latest chats',
          trailing: Text(
            '${controller.recentAgents.length}',
            style: const TextStyle(
              fontFamily: 'PlexMono',
              fontSize: 10,
              color: AppColors.muted,
            ),
          ),
        ),
        if (controller.recentAgents.isEmpty)
          QuietCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your conversations will appear here.'),
                const SizedBox(height: 8),
                const Text(
                  'Find an agent to start a conversation.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => controller.selectTab(WorkspaceTab.agents),
                  child: const Text('Find an agent'),
                ),
              ],
            ),
          ),
        for (final agent in controller.recentAgents)
          AgentListTile(controller: controller, agent: agent, recent: true),
        if (controller.snapshot?.notice case final String notice) ...[
          const SizedBox(height: 18),
          Text(
            notice,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      ],
    ),
  );
}

class _EnrollmentCard extends StatelessWidget {
  const _EnrollmentCard({required this.controller});
  final WorkspaceController controller;
  @override
  Widget build(BuildContext context) => QuietCard(
    color: AppColors.sage,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.verified_user_outlined, size: 18),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Device access',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          controller.snapshot?.enrollmentAvailable == true
              ? 'Approve this phone from a trusted Astation device before accessing your agents.'
              : '$deviceSetupUnavailable You are signed in; agent access still requires device verification.',
          style: const TextStyle(
            fontSize: 12,
            height: 1.6,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 12),
        DeviceAccessButton(controller: controller),
      ],
    ),
  );
}

class ApprovalDeck extends StatefulWidget {
  const ApprovalDeck({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<ApprovalDeck> createState() => _ApprovalDeckState();
}

class _ApprovalDeckState extends State<ApprovalDeck> {
  String? _active;
  double _drag = 0;
  int get _index {
    final index = widget.controller.pendingApprovals.indexWhere(
      (item) => item.key == _active,
    );
    return index < 0 ? 0 : index;
  }

  void _move(int offset) {
    final items = widget.controller.pendingApprovals;
    if (items.isNotEmpty) {
      setState(
        () => _active =
            items[(_index + offset + items.length) % items.length].key,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.controller.pendingApprovals;
    if (pending.isEmpty) return const SizedBox.shrink();
    final current = pending[_index];
    return Column(
      children: [
        SectionLabel(
          'Needs your approval',
          trailing: Text(
            '${pending.length}',
            style: const TextStyle(color: AppColors.amber, fontSize: 12),
          ),
        ),
        GestureDetector(
          onHorizontalDragStart: (_) => _drag = 0,
          onHorizontalDragUpdate: (event) => _drag += event.delta.dx,
          onHorizontalDragEnd: (_) {
            if (_drag.abs() >= 48) _move(_drag < 0 ? 1 : -1);
          },
          child: Padding(
            padding: EdgeInsets.only(bottom: pending.length > 1 ? 8 : 0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (pending.length > 1)
                  Positioned(
                    left: 6,
                    right: 6,
                    top: 10,
                    bottom: -6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0ECDf),
                        border: Border.all(color: const Color(0xFFE3D6BD)),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ApprovalPreview(
                  controller: widget.controller,
                  request: current,
                ),
              ],
            ),
          ),
        ),
        if (pending.length > 1)
          Row(
            children: [
              IconButton(
                tooltip: 'Previous approval',
                onPressed: () => _move(-1),
                icon: const Icon(Icons.chevron_left, size: 19),
              ),
              Text(
                '${_index + 1} of ${pending.length}',
                style: const TextStyle(fontFamily: 'PlexMono', fontSize: 10),
              ),
              IconButton(
                tooltip: 'Next approval',
                onPressed: () => _move(1),
                icon: const Icon(Icons.chevron_right, size: 19),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _showAll(context),
                child: const Text('Show all'),
              ),
            ],
          ),
      ],
    );
  }

  void _showAll(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .7,
      builder: (context, scroll) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Pending approvals',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            for (final item in widget.controller.pendingApprovals)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: ApprovalPreview(
                  controller: widget.controller,
                  request: item,
                  beforeOpen: () => Navigator.pop(context),
                ),
              ),
            if (widget.controller.pendingApprovals.isEmpty)
              const Text('No approvals waiting.'),
          ],
        ),
      ),
    ),
  );
}

class ApprovalPreview extends StatelessWidget {
  const ApprovalPreview({
    super.key,
    required this.controller,
    required this.request,
    this.beforeOpen,
  });
  final WorkspaceController controller;
  final ApprovalRequest request;
  final VoidCallback? beforeOpen;
  @override
  Widget build(BuildContext context) {
    final agent = controller.agent(request.target);
    return QuietCard(
      color: const Color(0xFFFBF8EF),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProviderSymbol(provider: agent?.provider ?? 'Agent'),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      agent?.name ?? 'Agent',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${agent?.provider ?? 'Agent'} on ${controller.host(request.target.host)?.displayName ?? request.target.host}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.verified_user_outlined,
                size: 17,
                color: AppColors.amber,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            request.summary,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
          if (request.command.isNotEmpty) ...[
            const SizedBox(height: 10),
            CodeLabel(request.command),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              beforeOpen?.call();
              controller.selectConversation(request.target);
            },
            label: const Text('Review request'),
            icon: const Icon(Icons.chevron_right, size: 17),
          ),
        ],
      ),
    );
  }
}

class ProviderSymbol extends StatelessWidget {
  const ProviderSymbol({super.key, required this.provider});
  final String provider;
  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      color: provider.toLowerCase().contains('claude')
          ? const Color(0xFFF3E4D6)
          : AppColors.sage,
      borderRadius: BorderRadius.circular(11),
    ),
    alignment: Alignment.center,
    child: Text(
      provider.toLowerCase().contains('claude') ? 'C' : '>_',
      style: const TextStyle(
        fontFamily: 'PlexMono',
        color: AppColors.deep,
        fontSize: 13,
      ),
    ),
  );
}

class AgentStatus extends StatelessWidget {
  const AgentStatus({super.key, required this.agent});
  final AgentSummary agent;
  @override
  Widget build(BuildContext context) {
    final color = !agent.connected || agent.lifecycle == AgentLifecycle.stopped
        ? AppColors.muted
        : agent.activity == AgentActivity.waiting
        ? AppColors.amber
        : AppColors.olive;
    final label = !agent.connected
        ? 'Reconnecting'
        : agent.lifecycle == AgentLifecycle.stopped
        ? 'Stopped'
        : switch (agent.activity) {
            AgentActivity.ready => 'Ready',
            AgentActivity.working => 'Working',
            AgentActivity.waiting => 'Waiting',
            AgentActivity.unknown => 'Unknown',
          };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }
}

class AgentListTile extends StatelessWidget {
  const AgentListTile({
    super.key,
    required this.controller,
    required this.agent,
    this.recent = false,
  });
  final WorkspaceController controller;
  final AgentSummary agent;
  final bool recent;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
      leading: ProviderSymbol(provider: agent.provider),
      title: Text(
        agent.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recent && agent.preview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                agent.preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '${agent.provider} · ${controller.host(agent.target.host)?.displayName ?? agent.target.host}',
              style: const TextStyle(fontSize: 10, color: AppColors.muted),
            ),
          ),
          AgentStatus(agent: agent),
        ],
      ),
      trailing: recent
          ? Text(
              _relativeTime(agent.updatedAt, controller.now()),
              style: const TextStyle(
                fontFamily: 'PlexMono',
                fontSize: 9,
                color: AppColors.muted,
              ),
            )
          : const Icon(Icons.chevron_right, size: 17),
      onTap: () => controller.selectConversation(agent.target),
      onLongPress: () => showConversationSwitcher(context, controller),
    ),
  );
}

String _relativeTime(DateTime date, DateTime now) {
  final age = now.difference(date);
  if (age.inMinutes < 1) return 'Now';
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 24) return '${age.inHours}h';
  return '${date.month}/${date.day}';
}

class AgentsHome extends StatefulWidget {
  const AgentsHome({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  State<AgentsHome> createState() => _AgentsHomeState();
}

class _AgentsHomeState extends State<AgentsHome> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final selectedHost = controller.host(controller.selectedHost);
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          if (selectedHost != null) ...[
            TextButton.icon(
              onPressed: () => controller.selectTab(WorkspaceTab.agents),
              icon: const Icon(Icons.chevron_left),
              label: const Text('All machines'),
            ),
            Text(
              selectedHost.name,
              style: const TextStyle(fontFamily: 'PlexSerif', fontSize: 30),
            ),
            const SizedBox(height: 8),
            SelectableText(
              selectedHost.id,
              style: const TextStyle(
                fontFamily: 'PlexMono',
                fontSize: 10,
                color: AppColors.muted,
              ),
            ),
            const SectionLabel('Agents'),
            for (final agent in controller.recentAgents.where(
              (agent) => agent.target.host == selectedHost.id,
            ))
              AgentListTile(controller: controller, agent: agent),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: selectedHost.online
                  ? () => showLaunchAgent(context, controller, selectedHost)
                  : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New agent'),
            ),
          ] else ...[
            const Text(
              'Your agents',
              style: TextStyle(fontFamily: 'PlexSerif', fontSize: 30),
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose a machine to find your agents.',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 20),
            TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Find a machine or ID',
                prefixIcon: Icon(Icons.search, size: 19),
              ),
            ),
            if (controller.snapshot?.hosts.isEmpty ?? true) ...[
              const SizedBox(height: 24),
              const QuietCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No Atem instances yet',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Enroll this device, then connect a verified Atem to your selected Station.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            for (final online in [true, false]) ...[
              if (controller.snapshot?.hosts.any(
                    (host) => host.online == online,
                  ) ??
                  false)
                SectionLabel(online ? 'Online' : 'Offline'),
              for (final host in controller.snapshot?.hosts ?? <HostSummary>[])
                if (host.online == online &&
                    '${host.name} ${host.id}'.toLowerCase().contains(
                      _query.toLowerCase(),
                    ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: QuietCard(
                      color: online ? AppColors.surface : AppColors.sage,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.dns_outlined,
                                color: AppColors.muted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  host.displayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.circle,
                                size: 7,
                                color: online
                                    ? AppColors.olive
                                    : AppColors.muted,
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              '${host.platform} · ${online ? '${controller.recentAgents.where((a) => a.target.host == host.id).length} agents' : 'Offline'}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () => controller.selectHost(host.id),
                                child: const Text('View agents'),
                              ),
                              OutlinedButton(
                                onPressed: host.online
                                    ? () => showLaunchAgent(
                                        context,
                                        controller,
                                        host,
                                      )
                                    : null,
                                child: const Text('New agent'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Each device connects independently.\nYour Mac can stay offline.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 11,
                height: 1.7,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> showLaunchAgent(
  BuildContext context,
  WorkspaceController controller,
  HostSummary host,
) async {
  LaunchProfile? selected;
  String? status;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final profiles =
              controller.snapshot?.profiles
                  .where((profile) => profile.host == host.id)
                  .toList() ??
              [];
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              22,
              6,
              22,
              24 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'New agent',
                  style: TextStyle(fontFamily: 'PlexSerif', fontSize: 28),
                ),
                const SizedBox(height: 8),
                Text(
                  'Run on ${host.displayName}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 20),
                if (profiles.isEmpty)
                  const Text(
                    'No approved launch profiles. Configure profiles on this Atem, then refresh.',
                    style: TextStyle(color: AppColors.muted, height: 1.6),
                  ),
                for (final profile in profiles)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: ProviderSymbol(provider: profile.provider),
                    title: Text(profile.name),
                    subtitle: Text(
                      '${profile.provider} · ${profile.project}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: Icon(
                      selected?.id == profile.id
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: AppColors.olive,
                    ),
                    onTap: () => setState(() => selected = profile),
                  ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed:
                        selected == null || controller.busy || status != null
                        ? null
                        : () async {
                            final result = await controller.launch(selected!);
                            if (context.mounted && result != null) {
                              setState(
                                () => status =
                                    '${result.status}: ${result.detail ?? 'Checking the original launch. Do not resubmit.'}',
                              );
                            }
                          },
                    child: Text(
                      controller.busy ? 'Creating agent…' : 'Create agent',
                    ),
                  ),
                ),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      status!,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                if (controller.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(controller.error!),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class AccountHome extends StatelessWidget {
  const AccountHome({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  Widget build(BuildContext context) {
    final state = controller.snapshot!;
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          'Account',
          style: TextStyle(fontFamily: 'PlexSerif', fontSize: 32),
        ),
        const SizedBox(height: 28),
        Text(
          state.account!.name,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 21),
        ),
        const SizedBox(height: 5),
        const Text(
          'Signed in with Agora.Build',
          style: TextStyle(fontSize: 12, color: AppColors.muted),
        ),
        const SectionLabel('Your account'),
        _setting(
          'Agora.Build account',
          Icons.open_in_new,
          () => controller.openExternal(
            Uri.parse('${state.environment.portal}/account/'),
          ),
        ),
        _setting(
          'Devices & security',
          Icons.verified_user_outlined,
          () => _info(context, 'Devices & security', [
            const Text(
              'Your trusted devices authorize access to your account’s Atem instances.',
            ),
            const SizedBox(height: 16),
            const Text(
              'To add this device, approve it on an existing trusted manager and compare the safety code. Account sign-in is a separate step.',
              style: TextStyle(height: 1.7, color: AppColors.muted),
            ),
            if (state.access == DeviceAccess.notEnrolled) ...[
              const SizedBox(height: 20),
              DeviceAccessButton(controller: controller),
            ],
          ]),
        ),
        _setting(
          'This device',
          Icons.smartphone_rounded,
          () => _info(context, 'This device', [
            Text(
              state.deviceName,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            Text(switch (state.access) {
              DeviceAccess.control => 'Verified · Control access',
              DeviceAccess.view => 'Verified · View access',
              DeviceAccess.notEnrolled => 'Not yet enrolled',
              DeviceAccess.revoked => 'Access revoked',
            }),
            const SizedBox(height: 14),
            if (state.deviceId.isNotEmpty)
              SelectableText(
                state.deviceId,
                style: const TextStyle(fontFamily: 'PlexMono', fontSize: 11),
              ),
            if (state.access == DeviceAccess.notEnrolled) ...[
              const SizedBox(height: 18),
              DeviceAccessButton(controller: controller),
            ],
          ]),
        ),
        const SectionLabel('Preferences'),
        _setting(
          'Notifications',
          Icons.notifications_none,
          () => _info(context, 'Notifications', const [
            Text('Pending approvals appear in Chats while you are connected.'),
            SizedBox(height: 16),
            Text(
              'Offline push setup is not available in this foundation build.',
              style: TextStyle(color: AppColors.muted, height: 1.7),
            ),
          ]),
        ),
        _setting(
          'Station',
          Icons.hub_outlined,
          () => _info(context, 'Station', [
            const Text('Built-in Station'),
            const SizedBox(height: 14),
            SelectableText(
              state.environment.station,
              style: const TextStyle(fontFamily: 'PlexMono', fontSize: 12),
            ),
            const SizedBox(height: 14),
            const Text(
              'This device connects to the Station independently of your Mac.',
              style: TextStyle(color: AppColors.muted, height: 1.7),
            ),
          ]),
        ),
        if (kDebugMode) ...[
          const SectionLabel('Development'),
          const Text(
            'Changing servers signs out and closes this device’s connections.',
            style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.6),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final environment in ServerEnvironment.values)
                ChoiceChip(
                  label: Text(environment.label),
                  selected: state.environment == environment,
                  onSelected: controller.busy
                      ? null
                      : (_) async {
                          if (environment != state.environment &&
                              await _confirm(
                                context,
                                'Change servers?',
                                'Sign out and connect to ${environment.label.toLowerCase()} servers?',
                                'Change servers',
                              )) {
                            await controller.selectEnvironment(environment);
                          }
                        },
                ),
            ],
          ),
        ],
        const SizedBox(height: 28),
        OutlinedButton(
          onPressed: controller.busy
              ? null
              : () async {
                  if (await _confirm(
                    context,
                    'Sign out?',
                    'Close this device’s current connections and sign out of Agora.Build?',
                    'Sign out',
                  )) {
                    await controller.signOut();
                  }
                },
          child: const Text('Sign out'),
        ),
        const Divider(height: 40),
        _setting(
          'About Astation',
          Icons.info_outline,
          () => _info(context, 'Astation', const [
            Text('Keep building. Anywhere. Your way.'),
            SizedBox(height: 16),
            Text(
              'Version 0.1.0 · Mobile foundation',
              style: TextStyle(color: AppColors.muted),
            ),
            SizedBox(height: 8),
            Text(
              'iOS + Android · phone, tablet and folding displays',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _setting(String title, IconData icon, VoidCallback onTap) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, size: 20, color: AppColors.muted),
    title: Text(title, style: const TextStyle(fontSize: 13)),
    trailing: const Icon(Icons.chevron_right, size: 17),
    onTap: onTap,
  );
}

Future<void> _info(BuildContext context, String title, List<Widget> children) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class CodeLabel extends StatelessWidget {
  const CodeLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppColors.sage,
      borderRadius: BorderRadius.circular(9),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText(
        text,
        style: const TextStyle(
          fontFamily: 'PlexMono',
          fontSize: 11,
          height: 1.6,
        ),
      ),
    ),
  );
}
