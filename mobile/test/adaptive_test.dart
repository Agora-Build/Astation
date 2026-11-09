import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:astation_mobile/src/adaptive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('phone has one pane, tablet has list and conversation', () {
    expect(AdaptiveRegions.forWindow(const Size(390, 844), []).second, isNull);
    final tablet = AdaptiveRegions.forWindow(const Size(1024, 768), []);
    expect(tablet.first.width, closeTo(327.68, .01));
    expect(tablet.second!.left, tablet.first.right);
  });
  test('vertical and horizontal separating hinges remain clear', () {
    for (final entry in [
      (const Size(1114, 720), const Rect.fromLTWH(540, 0, 34, 720)),
      (const Size(720, 1114), const Rect.fromLTWH(0, 540, 720, 34)),
    ]) {
      final panes = AdaptiveRegions.forWindow(entry.$1, [
        DisplayFeature(
          bounds: entry.$2,
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureHalfOpened,
        ),
      ]);
      expect(panes.separating, isTrue);
      expect(panes.second, isNotNull);
      expect(panes.first.overlaps(entry.$2), isFalse);
      expect(panes.second!.overlaps(entry.$2), isFalse);
    }
  });
  test('too-small pane is avoided instead of crossing the hinge', () {
    final panes = AdaptiveRegions.forWindow(const Size(700, 720), [
      const DisplayFeature(
        bounds: Rect.fromLTWH(100, 0, 24, 720),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      ),
    ]);
    expect(panes.second, isNull);
    expect(panes.first.left, 124);
  });
  test('a camera cutout never invents a second display', () {
    final panes = AdaptiveRegions.forWindow(const Size(390, 844), [
      const DisplayFeature(
        bounds: Rect.fromLTWH(130, 0, 130, 30),
        type: DisplayFeatureType.cutout,
        state: DisplayFeatureState.unknown,
      ),
    ]);
    expect(panes.second, isNull);
  });
}
