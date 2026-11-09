import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'controller.dart';
import 'gateway.dart';
import 'models.dart';
import 'theme.dart';
import 'workspace.dart';

class ConversationPane extends StatefulWidget {
  const ConversationPane({
    super.key,
    required this.controller,
    required this.target,
  });
  final WorkspaceController controller;
  final AgentTarget target;
  @override
  State<ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<ConversationPane> {
  late final _draft = TextEditingController(
    text: widget.controller.draft(widget.target),
  );
  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final agent = controller.agent(widget.target);
    if (agent == null) return const EmptyConversation();
    final conversation = controller.conversation(widget.target);
    final draft = controller.draft(widget.target);
    if (_draft.text != draft) {
      _draft.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
    return Material(
      color: AppColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to conversations',
                  onPressed: controller.closeConversation,
                  icon: const Icon(Icons.chevron_left),
                ),
                ProviderSymbol(provider: agent.provider),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () => showConversationSwitcher(context, controller),
                    onLongPress: () =>
                        showConversationSwitcher(context, controller),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            agent.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${agent.provider} on ${controller.host(agent.target.host)?.displayName ?? agent.target.host}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Conversation details',
                  onPressed: () => _details(context, controller, agent),
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (!agent.connected)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Reconnecting. Messages will not be replayed.',
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ),
          Expanded(
            child: ListView(
              key: PageStorageKey(agent.target.key),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              children: [
                if (conversation?.canLoadEarlier ?? false)
                  TextButton(
                    onPressed: controller.busy
                        ? null
                        : () => controller.loadEarlier(agent.target),
                    child: const Text('Load earlier messages'),
                  ),
                if (conversation?.notice case final String notice)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      notice,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                        height: 1.7,
                      ),
                    ),
                  ),
                if (conversation?.loading ?? true)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(30),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (conversation != null &&
                    !conversation.loading &&
                    conversation.messages.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Text(
                      'Start a conversation with this agent.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ),
                for (final message in conversation?.messages ?? <ChatMessage>[])
                  MessageView(
                    message: message,
                    provider: agent.provider,
                    controller: controller,
                  ),
                for (final request
                    in controller.snapshot?.approvals.where(
                          (item) => item.target == agent.target,
                        ) ??
                        <ApprovalRequest>[])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ApprovalCard(
                      controller: controller,
                      request: request,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              10,
              16,
              12 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFD5DDC8)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        key: const ValueKey('message-composer'),
                        controller: _draft,
                        onChanged: (value) =>
                            controller.saveDraft(agent.target, value),
                        enabled: agent.connected && controller.foreground,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 65536,
                        decoration: const InputDecoration(
                          hintText: 'Message your agent…',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.zero,
                          counterText: '',
                        ),
                        style: const TextStyle(fontSize: 13, height: 1.6),
                      ),
                      Row(
                        children: [
                          Expanded(child: AgentStatus(agent: agent)),
                          FilledButton.icon(
                            key: const ValueKey('send-message'),
                            onPressed: controller.canOperate(agent.target)
                                ? () => _send(controller, agent.target)
                                : null,
                            icon: const Icon(Icons.arrow_upward, size: 17),
                            label: const Text('Send'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (controller.snapshot?.access == DeviceAccess.view)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'View access',
                      style: TextStyle(fontSize: 10, color: AppColors.muted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _send(WorkspaceController controller, AgentTarget target) async {
    final result = await controller.send(target);
    if (!mounted ||
        result?.controller == null ||
        result?.status != 'takeoverRequired') {
      return;
    }
    final holder = result!.controller!;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Take over and send?'),
        content: Text(
          '${holder.label} currently controls this agent. Take over to send your message?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Take over and send'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await controller.send(target, takeover: holder);
    }
  }
}

class EmptyConversation extends StatelessWidget {
  const EmptyConversation({super.key});
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: AppColors.surface,
    child: Center(
      child: Padding(
        padding: EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 36,
              color: AppColors.olive,
            ),
            SizedBox(height: 24),
            Text(
              'Your next conversation',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'PlexSerif', fontSize: 28),
            ),
            SizedBox(height: 12),
            Text(
              'Choose an agent to see messages, tool activity and approvals.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 13,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.provider,
    required this.controller,
  });
  final ChatMessage message;
  final String provider;
  final WorkspaceController controller;
  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.only(
      bottom: 22,
      left: message.role == MessageRole.user ? 24 : 0,
    ),
    padding: message.role == MessageRole.user
        ? const EdgeInsets.all(14)
        : EdgeInsets.zero,
    decoration: message.role == MessageRole.user
        ? BoxDecoration(
            color: AppColors.sage,
            borderRadius: BorderRadius.circular(14),
          )
        : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.role != MessageRole.user)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              message.role == MessageRole.assistant ? provider : 'Activity',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.olive,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        MarkdownBody(
          data: message.markdown,
          selectable: true,
          imageBuilder: (_, _, alt) => Text(
            alt?.isNotEmpty == true ? '[Image: $alt]' : '[Image]',
            style: const TextStyle(
              color: AppColors.muted,
              fontStyle: FontStyle.italic,
            ),
          ),
          onTapLink: (_, href, _) => _openLink(context, controller, href),
          styleSheet: MarkdownStyleSheet(
            p: const TextStyle(
              fontSize: 13,
              height: 1.75,
              color: AppColors.ink,
            ),
            code: const TextStyle(
              fontFamily: 'PlexMono',
              fontSize: 11,
              height: 1.7,
            ),
            codeblockDecoration: BoxDecoration(
              color: AppColors.sage,
              borderRadius: BorderRadius.circular(10),
            ),
            h1: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            a: const TextStyle(
              color: AppColors.deep,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
        for (final tool in message.tools)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              tool.title,
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  tool.detail,
                  style: const TextStyle(
                    fontFamily: 'PlexMono',
                    fontSize: 10,
                    height: 1.7,
                  ),
                ),
              ),
            ],
          ),
        if (message.role == MessageRole.assistant)
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: 'Copy reply',
              icon: const Icon(Icons.copy_outlined, size: 15),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: message.markdown)),
            ),
          ),
      ],
    ),
  );
}

Future<void> _openLink(
  BuildContext context,
  WorkspaceController controller,
  String? href,
) async {
  final uri = Uri.tryParse(href ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return;
  }
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open in browser?'),
      content: SelectableText(uri.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open link'),
        ),
      ],
    ),
  );
  if (open == true) await controller.openExternal(uri);
}

class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.controller,
    required this.request,
  });
  final WorkspaceController controller;
  final ApprovalRequest request;
  @override
  Widget build(BuildContext context) {
    final pending = request.isPending(controller.now());
    final enabled = pending && controller.canOperate(request.target);
    return QuietCard(
      color: pending ? const Color(0xFFFBF8EF) : AppColors.sage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pending
                    ? Icons.verified_user_outlined
                    : Icons.check_circle_outline,
                size: 18,
                color: pending ? AppColors.amber : AppColors.olive,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pending
                      ? 'Needs your approval'
                      : request.state == ApprovalState.autoAllowed
                      ? 'Allowed by a session rule'
                      : request.closeReason ??
                            (request.state == ApprovalState.pending
                                ? 'Expired'
                                : 'Already answered'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            request.summary,
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
          if (request.command.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: CodeLabel(request.command),
            ),
          if (pending)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: enabled
                      ? () => controller.answer(request, 'allowOnce')
                      : null,
                  child: const Text('Allow once'),
                ),
                if (request.rules.isNotEmpty)
                  OutlinedButton(
                    onPressed: enabled ? () => _always(context) : null,
                    child: const Text('Always allow'),
                  ),
                TextButton(
                  onPressed: enabled ? () => _deny(context) : null,
                  child: const Text('Deny'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _always(BuildContext context) async {
    final rule = await showDialog<ApprovalRule>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Always allow this rule?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choose the exact rule offered by this agent.'),
              for (final rule in request.rules)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    rule.label,
                    style: const TextStyle(
                      fontFamily: 'PlexMono',
                      fontSize: 12,
                    ),
                  ),
                  subtitle: Text('Scope: ${rule.scope}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, rule),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (rule != null) {
      await controller.answer(request, 'allowAlways', rule: rule);
    }
  }

  Future<void> _deny(BuildContext context) async {
    final message = TextEditingController();
    final deny = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deny this request?'),
        content: TextField(
          controller: message,
          minLines: 2,
          maxLines: 4,
          maxLength: 4096,
          decoration: const InputDecoration(
            labelText: 'Message to the agent (optional)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deny'),
          ),
        ],
      ),
    );
    final text = message.text;
    message.dispose();
    if (deny == true) {
      await controller.answer(
        request,
        'deny',
        message: text.isEmpty ? null : text,
      );
    }
  }
}

Future<void> showConversationSwitcher(
  BuildContext context,
  WorkspaceController controller,
) async {
  final box = context.findRenderObject() as RenderBox?;
  final anchor = box?.localToGlobal(Offset.zero) ?? Offset.zero;
  await showDialog<void>(
    context: context,
    anchorPoint: anchor,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 22, 22, 14),
                child: Text(
                  'Switch conversation',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final agent in controller.recentAgents)
                      ListTile(
                        leading: ProviderSymbol(provider: agent.provider),
                        title: Text(
                          agent.name,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${agent.provider} on ${controller.host(agent.target.host)?.displayName ?? agent.target.host}',
                          style: const TextStyle(fontSize: 10),
                        ),
                        trailing: agent.target == controller.selected
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          controller.selectConversation(agent.target);
                        },
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Show all agents'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  controller.selectTab(WorkspaceTab.agents);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _details(
  BuildContext context,
  WorkspaceController controller,
  AgentSummary agent,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (sheetContext) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(22, 6, 22, 26),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Conversation',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ProviderSymbol(provider: agent.provider),
          title: Text(agent.name),
          subtitle: Text(
            controller.host(agent.target.host)?.displayName ??
                agent.target.host,
          ),
          trailing: const Icon(Icons.swap_horiz),
          onTap: () {
            Navigator.pop(sheetContext);
            showConversationSwitcher(context, controller);
          },
          onLongPress: () {
            Navigator.pop(sheetContext);
            showConversationSwitcher(context, controller);
          },
        ),
        const Text(
          'Touch and hold to switch conversations',
          style: TextStyle(fontSize: 10, color: AppColors.muted),
        ),
        const SectionLabel('Approval rules'),
        for (final item
            in controller.snapshot?.rules.where(
                  (item) => item.target == agent.target,
                ) ??
                <SessionRule>[])
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              item.rule.label,
              style: const TextStyle(fontFamily: 'PlexMono', fontSize: 11),
            ),
            subtitle: Text('Scope: ${item.rule.scope}'),
            trailing: TextButton(
              onPressed: controller.canOperate(agent.target)
                  ? () => controller.revokeRule(agent.target, item.rule.id)
                  : null,
              child: const Text('Revoke'),
            ),
          ),
        if (!(controller.snapshot?.rules.any(
              (item) => item.target == agent.target,
            ) ??
            false))
          const Text(
            'No always-allow rules are active.',
            style: TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        const SizedBox(height: 14),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history, size: 20),
          title: const Text(
            'Activity & request status',
            style: TextStyle(fontSize: 13),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () {
            Navigator.pop(sheetContext);
            _activity(context, controller, agent);
          },
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'Connection details',
            style: TextStyle(fontSize: 12),
          ),
          children: [
            SelectableText(
              '${agent.target.host}\nSession: ${agent.target.session}\nProcess: ${agent.target.processGeneration}',
              style: const TextStyle(fontFamily: 'PlexMono', fontSize: 10),
            ),
          ],
        ),
      ],
    ),
  ),
);

Future<void> _activity(
  BuildContext context,
  WorkspaceController controller,
  AgentSummary agent,
) async {
  final request = TextEditingController();
  CommandResult? result;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          22,
          6,
          22,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Activity & request status',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 18),
            AgentStatus(agent: agent),
            const SizedBox(height: 20),
            for (final message
                in controller.conversation(agent.target)?.messages ??
                    <ChatMessage>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  message.markdown,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
            const SectionLabel('Receipt lookup'),
            const Text(
              'Check the outcome of an existing request. A lookup never sends it again.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: request,
              decoration: const InputDecoration(labelText: 'Request ID'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () async {
                if (request.text.trim().isEmpty) return;
                final value = await controller.lookup(
                  agent.target,
                  request.text,
                );
                if (context.mounted) setState(() => result = value);
              },
              child: const Text('Check receipt'),
            ),
            if (result != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '${result!.status}\n${result!.detail ?? ''}',
                  style: const TextStyle(fontSize: 12, height: 1.7),
                ),
              ),
          ],
        ),
      ),
    ),
  );
  request.dispose();
}
