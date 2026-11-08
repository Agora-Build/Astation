import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:flutter/material.dart';

/// Regions come from the current window, never the model or operating system.
class AdaptiveRegions {
  const AdaptiveRegions(this.first, this.second, {this.separating = false});
  final Rect first;
  final Rect? second;
  final bool separating;
  bool get expanded => second != null;

  factory AdaptiveRegions.forWindow(Size size, List<DisplayFeature> features) {
    final window = Offset.zero & size;
    for (final feature in features) {
      if (feature.type != DisplayFeatureType.hinge &&
          feature.type != DisplayFeatureType.fold) {
        continue;
      }
      final obstruction = feature.bounds.intersect(window);
      if (obstruction.width > 0 && obstruction.height >= size.height * .8) {
        final first = Rect.fromLTRB(0, 0, obstruction.left, size.height);
        final second = Rect.fromLTRB(
          obstruction.right,
          0,
          size.width,
          size.height,
        );
        if (first.width >= 280 && second.width >= 280) {
          return AdaptiveRegions(first, second, separating: true);
        }
        return AdaptiveRegions(
          first.width >= second.width ? first : second,
          null,
          separating: true,
        );
      }
      if (obstruction.height > 0 && obstruction.width >= size.width * .8) {
        final first = Rect.fromLTRB(0, 0, size.width, obstruction.top);
        final second = Rect.fromLTRB(
          0,
          obstruction.bottom,
          size.width,
          size.height,
        );
        if (first.height >= 260 && second.height >= 260) {
          return AdaptiveRegions(first, second, separating: true);
        }
        return AdaptiveRegions(
          first.height >= second.height ? first : second,
          null,
          separating: true,
        );
      }
    }
    if (size.width >= 800) {
      final master = (size.width * .32).clamp(300.0, 360.0);
      return AdaptiveRegions(
        Rect.fromLTWH(0, 0, master, size.height),
        Rect.fromLTRB(master, 0, size.width, size.height),
      );
    }
    return AdaptiveRegions(window, null);
  }
}

class AdaptiveWorkspace extends StatelessWidget {
  const AdaptiveWorkspace({
    super.key,
    required this.master,
    required this.detail,
    required this.hasSelection,
  });
  final Widget master;
  final Widget detail;
  final bool hasSelection;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final regions = AdaptiveRegions.forWindow(
        constraints.biggest,
        MediaQuery.displayFeaturesOf(context),
      );
      final secondary = regions.second;
      return Stack(
        children: [
          Positioned.fromRect(
            rect: regions.first,
            child: secondary == null && hasSelection ? detail : master,
          ),
          if (secondary != null)
            Positioned.fromRect(rect: secondary, child: detail),
        ],
      );
    },
  );
}
