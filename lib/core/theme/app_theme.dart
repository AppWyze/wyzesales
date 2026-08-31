import 'package:flutter/material.dart';

/// Rebranded 2026-08-26 to the palette from Craig's `SAMTRA_design_concept
/// .html` mockup (a separate AppWyze pitch piece, not the WyzeSales app
/// itself — he asked for its navy/amber colour scheme carried over here).
/// Values below are taken verbatim from that file's `:root` CSS variables:
/// `--navy`/`--panel-2`/`--panel` for the three navy tones, `--amber`/
/// `--amber-dim` for the brand accent (still named `teal`/`tealDark` below —
/// renaming every call site that references `AppColors.teal` was judged
/// higher-risk than it's worth for a name that's cosmetic internally; every
/// usage already treats it as "the brand accent colour", not literally
/// "teal", so the mismatch is a labelling wrinkle, not a bug), `--white`/
/// `--steel` for text, and `--white`'s own darkened text tone for `onAccent`.
///
/// Heads up for Craig: the new brand accent (amber, #FFB23E) sits close in
/// hue to the pre-existing `caution` semantic colour (#F59E0B, used for
/// budget/seat-limit warnings) — e.g. Settings' License tab draws its seat
/// usage bar in `caution` when at-limit and in the brand accent otherwise,
/// so both states now read as "amber-ish" rather than one clearly reading
/// as a warning. Left `caution` untouched since changing it wasn't part of
/// "these colours" and it's used for meaning, not branding, elsewhere too —
/// flagging it here rather than deciding it one way or the other.
class AppColors {
  static const Color navyDeep = Color(0xFF0A1620);
  static const Color navyMid = Color(0xFF0E2230);
  static const Color navySurface = Color(0xFF132A38);
  static const Color teal = Color(0xFFFFB23E);
  static const Color tealDark = Color(0xFF9C7022);

  // Text/icon colour for anything sitting on a SOLID `teal` (brand accent)
  // fill — buttons, the profile avatar, active badges. The old teal
  // (#00BCD4) was dark enough for white text to read fine on it; the new
  // amber is light and warm, so white text on it is low-contrast the same
  // way it would be on any pale colour. Matches the source mockup's own
  // `.btn-primary{color:#1A1206}` exactly, rather than guessing a shade.
  static const Color onAccent = Color(0xFF1A1206);

  // Semantic colours WyzeSales actually needs: positive/negative GP%,
  // over/under budget, forecast confidence. Named for what they mean here
  // rather than reusing SeaWyze's work-order-status names.
  static const Color positive = Color(0xFF10B981);
  static const Color negative = Color(0xFFEF4444);
  static const Color caution = Color(0xFFF59E0B);
  static const Color info = Color(0xFF3B82F6);
  // A fifth accent purely for visual variety on things like the Dashboard's
  // quick-action tiles (SeaWyze's own quick actions cycle through a similar
  // spread of pastel hues) — no business meaning attached, unlike the four
  // semantic colours above.
  static const Color accentPurple = Color(0xFF8B5CF6);

  // Light theme keeps its existing neutral base — the SAMTRA mockup is
  // dark-themed only and gives no light-mode guidance, so inventing a new
  // light background/secondary-text tone here would be a guess, not
  // something taken "as per the attached". Only lightText is updated, to
  // keep mirroring navyDeep's new shade the same way it always has.
  static const Color lightBackground = Color(0xFFE2E8F0);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightText = Color(0xFF0A1620);
  static const Color lightTextSecondary = Color(0xFF64748B);
  static const Color darkBackground = Color(0xFF0A1620);
  static const Color darkSurface = Color(0xFF132A38);
  static const Color darkText = Color(0xFFEDF1F3);
  static const Color darkTextSecondary = Color(0xFF7E929E);
}

class AppTheme {
  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      // A denser default than Material's normal spacing — this app is
      // mostly data tables and filter rows, not the more spacious
      // touch-first layout Material assumes by default. Matches the intent
      // behind the DataTable sizing below, applied globally (buttons, list
      // tiles, form fields, etc. all shrink a bit too).
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: AppColors.lightBackground,
      colorScheme: const ColorScheme.light(
        primary: AppColors.teal,
        onPrimary: AppColors.onAccent,
        secondary: AppColors.navyDeep,
        onSecondary: Colors.white,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightText,
        error: AppColors.negative,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.navyDeep,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: AppColors.lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0x0F000000)),
        ),
      ),
      // Shrunk again 2026-08-21 — Craig compared side-by-side against real
      // SeaWyze screens (a form with small, subtle gray field labels like
      // "Registered name") and confirmed WyzeSales' headings/titles still
      // ran noticeably larger. headlineSmall/titleLarge/titleMedium (page
      // titles, section headers, card titles) came down the most; the KPI
      // stat-card numbers deliberately did NOT shrink with them — those are
      // supposed to stay bold and prominent (see StatCard, which now reads
      // headlineMedium instead of headlineSmall for exactly that reason).
      // titleSmall is untouched: that's what DataTable headers fall back to,
      // and the DataTable sizing pass already got Craig's separate
      // confirmation ("flutter analyze is clear" / no further table
      // complaints) — no reason to disturb it here.
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: AppColors.lightText),
        displayMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.lightText),
        displaySmall: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.lightText),
        headlineLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.lightText),
        headlineMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.lightText),
        headlineSmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.lightText),
        titleLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.lightText),
        titleMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.lightText),
        titleSmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.lightText),
        bodyLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: AppColors.lightText),
        bodyMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: AppColors.lightTextSecondary),
        bodySmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w400, color: AppColors.lightTextSecondary),
        labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.lightTextSecondary),
        labelMedium: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: AppColors.lightTextSecondary),
        labelSmall: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: AppColors.lightTextSecondary),
      ),
      // DataTable has its own hard-coded defaults (56px header row, 52px
      // data rows, 24px column spacing) independent of visualDensity above
      // — this app is DataTable on almost every screen, so this is the
      // single biggest lever for "does this feel like a dense report or a
      // touch-first app."
      dataTableTheme: const DataTableThemeData(
        headingTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.lightText),
        dataTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: AppColors.lightText),
        headingRowHeight: 40,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 36,
        horizontalMargin: 12,
        columnSpacing: 20,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.teal,
          foregroundColor: AppColors.onAccent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0x1F000000)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0x1F000000)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.teal, width: 2),
        ),
        labelStyle: const TextStyle(color: AppColors.lightTextSecondary),
      ),
      dividerTheme: const DividerThemeData(color: Color(0x0F000000), thickness: 1),
      // Material3's SegmentedButton (the R Value / R Gross Profit toggle)
      // and Switch default to a muted colour derived from secondaryContainer
      // rather than the app's actual teal — Craig asked for toggles to read
      // teal like SeaWyze's, so both are pinned to it explicitly here.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected) ? AppColors.teal : Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected) ? AppColors.onAccent : AppColors.lightTextSecondary;
          }),
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.teal, width: 1)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? AppColors.teal : null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? AppColors.teal.withValues(alpha: 0.5) : null;
        }),
      ),
    );
  }

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: AppColors.darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.teal,
        onPrimary: AppColors.onAccent,
        secondary: AppColors.navySurface,
        onSecondary: Colors.white,
        surface: AppColors.darkSurface,
        onSurface: AppColors.darkText,
        error: AppColors.negative,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.navyMid,
        foregroundColor: AppColors.darkText,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: AppColors.darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0x0FFFFFFF)),
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: AppColors.darkText),
        displayMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.darkText),
        displaySmall: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.darkText),
        headlineLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.darkText),
        headlineMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.darkText),
        headlineSmall: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.darkText),
        titleLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.darkText),
        titleMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.darkText),
        titleSmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.darkText),
        bodyLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: AppColors.darkText),
        bodyMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: AppColors.darkTextSecondary),
        bodySmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w400, color: AppColors.darkTextSecondary),
        labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.darkTextSecondary),
        labelMedium: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: AppColors.darkTextSecondary),
        labelSmall: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: AppColors.darkTextSecondary),
      ),
      dataTableTheme: const DataTableThemeData(
        headingTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.darkText),
        dataTextStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: AppColors.darkText),
        headingRowHeight: 40,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 36,
        horizontalMargin: 12,
        columnSpacing: 20,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.teal,
          foregroundColor: AppColors.onAccent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.navySurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0x1FFFFFFF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0x1FFFFFFF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.teal, width: 2),
        ),
        labelStyle: const TextStyle(color: AppColors.darkTextSecondary),
      ),
      dividerTheme: const DividerThemeData(color: Color(0x0FFFFFFF), thickness: 1),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected) ? AppColors.teal : Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected) ? AppColors.onAccent : AppColors.darkTextSecondary;
          }),
          side: const WidgetStatePropertyAll(BorderSide(color: AppColors.teal, width: 1)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? AppColors.teal : null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? AppColors.teal.withValues(alpha: 0.5) : null;
        }),
      ),
    );
  }
}
