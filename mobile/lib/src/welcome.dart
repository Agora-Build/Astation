import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import 'adaptive.dart';
import 'controller.dart';
import 'models.dart';
import 'theme.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.controller});
  final WorkspaceController controller;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final regions = AdaptiveRegions.forWindow(
          constraints.biggest,
          MediaQuery.displayFeaturesOf(context),
        );
        final split = regions.expanded;
        final centered = regions.separating;
        final column = _WelcomeCopy(
          controller: controller,
          centered: centered,
          expanded: split,
          carousel: split ? null : FeatureCarousel(controller: controller),
        );
        if (!split) return PositionedRegion(rect: regions.first, child: column);
        final first = regions.first;
        final second = regions.second!;
        // A tablet welcome uses equal columns; workspace navigation uses a narrower master.
        final left = regions.separating
            ? first
            : Rect.fromLTWH(
                0,
                0,
                constraints.maxWidth / 2,
                constraints.maxHeight,
              );
        final right = regions.separating
            ? second
            : Rect.fromLTWH(
                constraints.maxWidth / 2,
                0,
                constraints.maxWidth / 2,
                constraints.maxHeight,
              );
        return Stack(
          children: [
            Positioned.fromRect(rect: left, child: column),
            Positioned.fromRect(
              rect: right,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: FeatureCarousel(
                    controller: controller,
                    expanded: true,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class PositionedRegion extends StatelessWidget {
  const PositionedRegion({super.key, required this.rect, required this.child});
  final Rect rect;
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    children: [Positioned.fromRect(rect: rect, child: child)],
  );
}

class _WelcomeCopy extends StatelessWidget {
  const _WelcomeCopy({
    required this.controller,
    required this.centered,
    required this.expanded,
    this.carousel,
  });
  final WorkspaceController controller;
  final bool centered;
  final bool expanded;
  final Widget? carousel;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final padding = expanded ? 38.0 : 26.0;
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              crossAxisAlignment: centered
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                const AstationBrand(),
                SizedBox(height: expanded ? 48 : 42),
                Text(
                  'A LITTLE CLOSER TO YOUR AGENTS',
                  textAlign: centered ? TextAlign.center : TextAlign.left,
                  style: const TextStyle(
                    fontFamily: 'PlexMono',
                    fontSize: 9,
                    letterSpacing: 1.2,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 15),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: centered ? Alignment.center : Alignment.centerLeft,
                  child: Text(
                    'Your agents.\nWithin reach.',
                    textAlign: centered ? TextAlign.center : TextAlign.left,
                    style: TextStyle(
                      fontFamily: 'PlexSerif',
                      fontSize: expanded ? 49 : 39,
                      letterSpacing: -1.8,
                      height: 1.17,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Keep building. Anywhere. Your way.',
                  textAlign: centered ? TextAlign.center : TextAlign.left,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 14,
                    height: 1.6,
                  ),
                ),
                if (carousel != null) ...[
                  const SizedBox(height: 26),
                  carousel!,
                ],
                SizedBox(height: expanded ? 30 : 26),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('sign-in'),
                      onPressed:
                          controller.busy ||
                              controller.snapshot?.loginAvailable != true
                          ? null
                          : controller.signIn,
                      icon: controller.busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Continue with Agora.Build'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const SizedBox(
                  width: 340,
                  child: Text(
                    'Sign in or create an account with GitHub\nor your Agora.Build account.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.7,
                      color: AppColors.muted,
                    ),
                  ),
                ),
                if (controller.snapshot?.notice case final String notice) ...[
                  const SizedBox(height: 16),
                  Text(
                    notice,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.6,
                      color: AppColors.muted,
                    ),
                  ),
                ],
                if (kDebugMode && controller.snapshot != null) ...[
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final environment in ServerEnvironment.values)
                        ChoiceChip(
                          label: Text('${environment.label} servers'),
                          selected:
                              controller.snapshot!.environment == environment,
                          onSelected: controller.busy
                              ? null
                              : (_) =>
                                    controller.selectEnvironment(environment),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 28),
                Text(
                  'YOUR MACHINES. YOUR AGENTS. YOUR CONTEXT.',
                  textAlign: centered ? TextAlign.center : TextAlign.left,
                  style: const TextStyle(
                    fontFamily: 'PlexMono',
                    fontSize: 8,
                    letterSpacing: .4,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class WelcomeFeature {
  const WelcomeFeature(
    this.name,
    this.subtitle,
    this.description,
    this.icon, {
    this.url,
    this.background = AppColors.surface,
    this.ink = AppColors.ink,
  });
  final String name;
  final String subtitle;
  final String description;
  final IconData icon;
  final String? url;
  final Color background;
  final Color ink;
}

const welcomeFeatures = [
  WelcomeFeature(
    'Astation mobile',
    'Codex on Genie',
    'The layout is in place.\nHere\'s what I\'d build next.',
    Icons.smartphone_rounded,
  ),
  WelcomeFeature(
    'Atem',
    'YOUR AGENTS. YOUR MACHINE.',
    'A terminal that connects builders, AI agents and more.',
    Icons.terminal_rounded,
    url: 'https://github.com/Agora-Build/Atem',
    background: Color(0xFFF5F2EA),
  ),
  WelcomeFeature(
    'Vox Realtime',
    'VOICE AGENT BENCHMARKS',
    'Compare voice agents on response speed, interruptions, and conversation success.',
    Icons.graphic_eq,
    url: 'https://vox.agora.build',
    background: Color(0xFF203E37),
    ink: Color(0xFFF1F4E9),
  ),
  WelcomeFeature(
    'Astation Dictation',
    'YOUR VOICE, WRITTEN.',
    'Push-to-talk or hands-free on your Mac.',
    Icons.mic_none_rounded,
    background: Color(0xFFFCF4E9),
  ),
  WelcomeFeature(
    'Approvals anywhere',
    'REVIEW IN CONTEXT.',
    'Know what runs. Give the next step your go-ahead.',
    Icons.verified_user_outlined,
    background: Color(0xFFF4F7ED),
  ),
];

class FeatureCarousel extends StatefulWidget {
  const FeatureCarousel({
    super.key,
    required this.controller,
    this.expanded = false,
  });
  final WorkspaceController controller;
  final bool expanded;
  @override
  State<FeatureCarousel> createState() => _FeatureCarouselState();
}

class _FeatureCarouselState extends State<FeatureCarousel> {
  final _pages = PageController();
  int _index = 0;
  void _select(int index) => _pages.animateToPage(
    (index + welcomeFeatures.length) % welcomeFeatures.length,
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    curve: Curves.easeOut,
  );
  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _select(_index + 1);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _select(_index - 1);
      } else if (event.logicalKey == LogicalKeyboardKey.home) {
        _select(0);
      } else if (event.logicalKey == LogicalKeyboardKey.end) {
        _select(welcomeFeatures.length - 1);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    },
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height:
              (widget.expanded ? 270 : 260) *
              MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          child: PageView.builder(
            controller: _pages,
            itemCount: welcomeFeatures.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (context, index) => _FeatureCard(
              feature: welcomeFeatures[index],
              open: () => widget.controller.openExternal(
                Uri.parse(welcomeFeatures[index].url!),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              tooltip: 'Previous featured card',
              onPressed: () => _select(_index - 1),
              icon: const Icon(
                Icons.chevron_left,
                size: 18,
                color: AppColors.muted,
              ),
            ),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < welcomeFeatures.length; index++)
                    Flexible(
                      child: Semantics(
                        selected: index == _index,
                        child: IconButton(
                          tooltip: 'Show ${welcomeFeatures[index].name}',
                          onPressed: () => _select(index),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 44,
                          ),
                          icon: Container(
                            width: index == _index ? 18 : 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: index == _index
                                  ? AppColors.olive
                                  : const Color(0xFFC4CDB8),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Next featured card',
              onPressed: () => _select(_index + 1),
              icon: const Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
        Semantics(
          liveRegion: true,
          child: Text(
            '${_index == 0 ? 'Agent chat' : welcomeFeatures[_index].name} · ${_index + 1} / ${welcomeFeatures.length}',
            style: const TextStyle(fontSize: 9, color: AppColors.muted),
          ),
        ),
      ],
    ),
  );
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.feature, required this.open});
  final WelcomeFeature feature;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) {
    final vox = feature.name == 'Vox Realtime';
    final content = Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: vox ? AppColors.paper : AppColors.sage,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: vox
                    ? Image.asset('assets/vox-mark.png', width: 24, height: 24)
                    : Icon(feature.icon, color: AppColors.deep, size: 21),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      feature.name,
                      style: TextStyle(
                        fontSize: 14,
                        color: feature.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      feature.subtitle,
                      style: TextStyle(
                        fontSize: 8,
                        color: feature.ink.withValues(alpha: .6),
                        letterSpacing: .3,
                      ),
                    ),
                  ],
                ),
              ),
              if (feature.name == 'Astation mobile')
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 5, color: AppColors.olive),
                    SizedBox(width: 4),
                    Text(
                      'Ready',
                      style: TextStyle(fontSize: 10, color: AppColors.olive),
                    ),
                  ],
                ),
            ],
          ),
          if (vox)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < 18; i++)
                    Container(
                      width: 4,
                      height: 12 + math.sin(i * 2.3).abs() * 23,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFB4D39F),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            )
          else if (feature.name == 'Atem')
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 14),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF293B32),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                r'$ atem agent launch codex',
                style: TextStyle(
                  fontFamily: 'PlexMono',
                  fontSize: 10,
                  color: Color(0xFFE0E9D1),
                ),
              ),
            )
          else
            const SizedBox(height: 23),
          Text(
            feature.description,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: feature.ink.withValues(alpha: .8),
            ),
          ),
          const Spacer(),
          Divider(color: feature.ink.withValues(alpha: .13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  feature.url == null
                      ? (feature.name == 'Astation mobile'
                            ? 'ONE WORKSPACE. EVERY DEVICE.'
                            : 'FEATURE SPOTLIGHT')
                      : 'Explore ${feature.name}',
                  style: TextStyle(
                    color: feature.ink.withValues(alpha: .8),
                    fontSize: feature.url == null ? 8 : 12,
                    fontFamily: feature.url == null ? 'PlexMono' : 'PlexSans',
                  ),
                ),
              ),
              Icon(
                feature.url == null
                    ? Icons.chat_bubble_outline
                    : Icons.open_in_new,
                size: 16,
                color: feature.ink.withValues(alpha: .7),
              ),
            ],
          ),
        ],
      ),
    );
    final child = LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(child: content),
        ),
      ),
    );
    return Material(
      color: feature.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: feature.url == null ? child : InkWell(onTap: open, child: child),
    );
  }
}
