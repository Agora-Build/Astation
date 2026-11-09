import 'package:flutter/material.dart';

abstract final class AppColors {
  static const paper = Color(0xFFF7F6F2);
  static const surface = Color(0xFFFFFEFA);
  static const ink = Color(0xFF252E29);
  static const muted = Color(0xFF777C73);
  static const line = Color(0xFFE3E5DB);
  static const olive = Color(0xFF61764E);
  static const deep = Color(0xFF455C37);
  static const sage = Color(0xFFEDF0E7);
  static const amber = Color(0xFFA77731);
}

ThemeData astationTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'PlexSans',
  scaffoldBackgroundColor: AppColors.paper,
  colorScheme: ColorScheme.fromSeed(
    seedColor: AppColors.deep,
    surface: AppColors.surface,
    brightness: Brightness.light,
  ),
  dividerColor: AppColors.line,
  textTheme: ThemeData.light().textTheme.apply(
    fontFamily: 'PlexSans',
    bodyColor: AppColors.ink,
    displayColor: AppColors.ink,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: AppColors.paper,
    foregroundColor: AppColors.ink,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: AppColors.deep,
      foregroundColor: AppColors.surface,
      minimumSize: const Size(44, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: AppColors.deep,
      minimumSize: const Size(44, 44),
      side: const BorderSide(color: AppColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: AppColors.surface,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.line),
    ),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    height: 72,
    backgroundColor: AppColors.surface,
    indicatorColor: AppColors.sage,
    labelTextStyle: WidgetStatePropertyAll(
      TextStyle(fontSize: 11, fontFamily: 'PlexSans'),
    ),
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    constraints: BoxConstraints(maxWidth: 560),
  ),
);

class AstationBrand extends StatelessWidget {
  const AstationBrand({super.key});
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 31,
          height: 31,
          decoration: BoxDecoration(
            color: AppColors.ink,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: const Text(
            'a',
            style: TextStyle(
              fontFamily: 'PlexSerif',
              height: 1,
              fontSize: 32,
              color: AppColors.surface,
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'astation',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 22,
            letterSpacing: -.8,
          ),
        ),
      ],
    ),
  );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontFamily: 'PlexMono',
            fontSize: 10,
            letterSpacing: 1,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(child: Divider()),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

class QuietCard extends StatelessWidget {
  const QuietCard({
    super.key,
    required this.child,
    this.color = AppColors.surface,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.line),
    ),
    child: child,
  );
}
