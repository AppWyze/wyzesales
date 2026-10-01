import 'package:flutter/material.dart';

/// One tile/screen's "How it works" content — a dialog title plus a list of
/// plain-language paragraphs, rendered in order. Kept as a plain data class
/// (not just a raw `List<String>`) so a call site reads as `TileHelp(title:
/// ..., paragraphs: [...])` rather than an unlabelled positional list.
class TileHelp {
  const TileHelp({required this.title, required this.paragraphs});

  /// The dialog's own title — e.g. "How Sales Coverage is calculated".
  final String title;

  /// One AlertDialog paragraph per entry, in order. Plain strings, not
  /// `TextSpan`/rich text — every explanation written against this so far
  /// (2026-10-01's Dashboard tiles) reads fine as plain prose; a future call
  /// site that genuinely needs inline emphasis can still build its own
  /// dialog by hand the way budgets_screen.dart's Seasonal Forecast
  /// explanation does, rather than this widget growing a rich-text mode
  /// nothing uses yet.
  final List<String> paragraphs;
}

/// A small tappable "?" that opens a full plain-language explanation of
/// whatever it's attached to — generalizes budgets_screen.dart's own
/// `_helpButton`/`_showForecastExplanation` pattern (2026-09-22, Craig's
/// original request for the Seasonal Forecast figure: "a Button / Hover...
/// that explains in layman terms exactly how [it's] calculated") into one
/// reusable widget, rather than every screen re-implementing the same
/// Tooltip+showDialog shape by hand.
///
/// 2026-10-01, Craig, asking for this more broadly: "if a user positions
/// their cursor hovers over a screen, tile etc a popup window appears giving
/// detail of the function... Do you maybe have a better more acceptable way
/// of doing this?" Built as a visible tap target rather than hover-only —
/// WyzeSales is a Flutter WEB app (no native mobile build), so it can
/// perfectly well be opened from a tablet or phone browser, where hover
/// never fires at all; a hover-only popup would simply never be reachable
/// there. `Tooltip` (below) still gives a desktop/mouse user the instant
/// hover hint Craig originally pictured, for free — Flutter's own built-in
/// widget already shows on hover for a mouse and falls back to long-press on
/// touch, no separate "are we on a touch device" branch needed — but the
/// FULL explanation always sits behind one unambiguous tap/click, visible to
/// every input method and screen reader alike, not behind a hover gesture
/// some devices can't produce.
class HelpInfoIcon extends StatelessWidget {
  const HelpInfoIcon({super.key, required this.help, this.hint, this.iconSize = 14});

  final TileHelp help;

  /// The Tooltip's one-line hover hint — defaults to `help.title` when
  /// omitted (budgets_screen.dart's own `_helpButton` always provides this
  /// explicitly as a slightly different, shorter phrasing; most call sites
  /// won't need to).
  final String? hint;

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45);
    return Tooltip(
      message: hint ?? help.title,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _show(context),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(Icons.help_outline, size: iconSize, color: color),
        ),
      ),
    );
  }

  void _show(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(help.title),
        // ConstrainedBox with a maxWidth, not a fixed-width SizedBox — same
        // reasoning as budgets_screen.dart's identical dialog: a literal
        // fixed width would force that width even on a phone screen
        // narrower than it plus the dialog's own insets. maxWidth only caps
        // how wide this gets on a large screen, never forces a floor.
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final paragraph in help.paragraphs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(paragraph),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Got it')),
        ],
      ),
    );
  }
}
