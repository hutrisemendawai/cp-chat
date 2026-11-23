import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';

/// Typography scale from the Stitch design system.
///
/// Three families: Mulish for headings/titles, Instrument Sans for body and
/// labels, Source Code Pro for encrypted payloads and tabular timestamps.
abstract final class AppTypography {
  static const display = 'Mulish';
  static const body = 'InstrumentSans';
  static const mono = 'SourceCodePro';
}

/// Spacing scale (`4px` / `8px` grid) from the design system.
abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const section = 32.0;
  static const pageMargin = 16.0;
}

/// Radius scale from the design system.
abstract final class AppRadius {
  static const sm = 4.0;
  static const md = 8.0;
  static const card = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const full = 9999.0;
}

/// Builds the light and dark [ThemeData] from the Stitch design system.
///
/// Material 3 roles are mapped onto the design system's palette one-to-one, and
/// component themes are pinned so a stock widget cannot silently reintroduce
/// the old blue seed colour.
abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = _scheme(isDark);
    final chat = isDark ? ChatTheme.dark : ChatTheme.light;
    final textTheme = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      fontFamily: AppTypography.body,
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[chat],
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerLow,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.headlineMedium,
        shape: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.whatsappEmerald,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          textStyle: textTheme.labelLarge,
          shape: const StadiumBorder(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          textStyle: textTheme.labelLarge,
          side: BorderSide(color: scheme.outlineVariant),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: textTheme.labelLarge,
          foregroundColor: scheme.primary,
          shape: const StadiumBorder(),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        hintStyle: textTheme.bodyMedium?.copyWith(color: scheme.outline),
        labelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: const BorderSide(
            color: AppColors.whatsappEmerald,
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        dragHandleColor: scheme.outlineVariant,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : Colors.transparent,
        ),
        side: BorderSide(color: scheme.outline),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.outline,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }

  /// Maps the design system palette onto Material 3's [ColorScheme].
  static ColorScheme _scheme(bool isDark) {
    if (isDark) {
      return const ColorScheme(
        brightness: Brightness.dark,
        primary: Color(0xFF59DCB5),
        onPrimary: Color(0xFF00382A),
        primaryContainer: Color(0xFF00A884),
        onPrimaryContainer: Color(0xFF003427),
        secondary: Color(0xFFA1D1BE),
        onSecondary: Color(0xFF05382A),
        secondaryContainer: Color(0xFF224F40),
        onSecondaryContainer: Color(0xFF90BFAC),
        tertiary: Color(0xFFFFB4A9),
        onTertiary: Color(0xFF60130C),
        tertiaryContainer: Color(0xFFE27465),
        onTertiaryContainer: Color(0xFF5B0F09),
        error: Color(0xFFFFB4AB),
        onError: Color(0xFF690005),
        errorContainer: Color(0xFF93000A),
        onErrorContainer: Color(0xFFFFDAD6),
        surface: Color(0xFF0E1512),
        onSurface: Color(0xFFDDE4DF),
        surfaceDim: Color(0xFF0E1512),
        surfaceBright: Color(0xFF343B37),
        surfaceContainerLowest: Color(0xFF090F0D),
        surfaceContainerLow: Color(0xFF171D1A),
        surfaceContainer: Color(0xFF1B211E),
        surfaceContainerHigh: Color(0xFF252B28),
        surfaceContainerHighest: Color(0xFF303633),
        onSurfaceVariant: Color(0xFFBCCAC2),
        outline: Color(0xFF86948D),
        outlineVariant: Color(0xFF3D4A44),
        inverseSurface: Color(0xFFDDE4DF),
        onInverseSurface: Color(0xFF2B322F),
        inversePrimary: Color(0xFF006B53),
        surfaceTint: Color(0xFF59DCB5),
      );
    }

    return const ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF006B53),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: Color(0xFF00A884),
      onPrimaryContainer: Color(0xFF003427),
      secondary: Color(0xFF3A6757),
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: Color(0xFFBAEAD6),
      onSecondaryContainer: Color(0xFF3F6B5B),
      tertiary: Color(0xFF9E4035),
      onTertiary: Color(0xFFFFFFFF),
      tertiaryContainer: Color(0xFFE27465),
      onTertiaryContainer: Color(0xFF5B0F09),
      error: Color(0xFFBA1A1A),
      onError: Color(0xFFFFFFFF),
      errorContainer: Color(0xFFFFDAD6),
      onErrorContainer: Color(0xFF93000A),
      surface: Color(0xFFF4FBF6),
      onSurface: Color(0xFF171D1A),
      surfaceDim: Color(0xFFD5DCD7),
      surfaceBright: Color(0xFFF4FBF6),
      surfaceContainerLowest: Color(0xFFFFFFFF),
      surfaceContainerLow: Color(0xFFEFF5F0),
      surfaceContainer: Color(0xFFE9EFEA),
      surfaceContainerHigh: Color(0xFFE3EAE5),
      surfaceContainerHighest: Color(0xFFDDE4DF),
      onSurfaceVariant: Color(0xFF3D4A44),
      outline: Color(0xFF6C7A74),
      outlineVariant: Color(0xFFBCCAC2),
      inverseSurface: Color(0xFF2B322F),
      onInverseSurface: Color(0xFFECF2ED),
      inversePrimary: Color(0xFF59DCB5),
      surfaceTint: Color(0xFF006B53),
    );
  }

  /// Material [TextTheme] built from the design system's type scale.
  static TextTheme _textTheme(ColorScheme scheme) {
    final onSurface = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;

    return TextTheme(
      // display-lg-mobile (28/34, 700, -0.25)
      displayLarge: _style(AppTypography.display, 36, 42, FontWeight.w700,
          letterSpacing: -0.5, color: onSurface),
      displayMedium: _style(AppTypography.display, 28, 34, FontWeight.w700,
          letterSpacing: -0.25, color: onSurface),
      displaySmall: _style(AppTypography.display, 24, 30, FontWeight.w700,
          letterSpacing: -0.2, color: onSurface),
      // headline-lg (24/30, 700) / headline-md (20/26, 600)
      headlineLarge: _style(AppTypography.display, 24, 30, FontWeight.w700,
          letterSpacing: -0.2, color: onSurface),
      headlineMedium: _style(AppTypography.display, 20, 26, FontWeight.w600,
          letterSpacing: -0.1, color: onSurface),
      headlineSmall: _style(AppTypography.display, 18, 24, FontWeight.w600,
          color: onSurface),
      // title-lg (18/24, 600) / title-md (16/22, 600)
      titleLarge: _style(AppTypography.display, 18, 24, FontWeight.w600,
          color: onSurface),
      titleMedium: _style(AppTypography.display, 16, 22, FontWeight.w600,
          color: onSurface),
      titleSmall: _style(AppTypography.display, 14, 20, FontWeight.w600,
          color: muted),
      // body-lg (16/22) / body-md (14/20) / body-sm (12/16, +0.1)
      bodyLarge: _style(AppTypography.body, 16, 22, FontWeight.w400,
          color: onSurface),
      bodyMedium: _style(AppTypography.body, 14, 20, FontWeight.w400,
          color: onSurface),
      bodySmall: _style(AppTypography.body, 12, 16, FontWeight.w400,
          letterSpacing: 0.1, color: muted),
      // label-lg (14/20, 600) / label-md (12/16, 500) / label-sm (11/14, 500)
      labelLarge: _style(AppTypography.body, 14, 20, FontWeight.w600,
          letterSpacing: 0.1, color: onSurface),
      labelMedium: _style(AppTypography.body, 12, 16, FontWeight.w500,
          letterSpacing: 0.2, color: muted),
      labelSmall: _style(AppTypography.body, 11, 14, FontWeight.w500,
          letterSpacing: 0.2, color: muted),
    );
  }

  static TextStyle _style(
    String family,
    double size,
    double height,
    FontWeight weight, {
    double? letterSpacing,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      height: height / size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      color: color,
    );
  }
}
