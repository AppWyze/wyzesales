import 'package:flutter/material.dart';

enum StatPeriod { mtd, ytd }

/// A KPI tile that can flip between an MTD and a YTD reading of the same
/// metric — the Dashboard's second-generation KPI row (2026-08-27, after
/// Craig reviewed a mockup and asked: "is it possible to have a toggle on
/// the tile to flip between mtd / ytd?" for Revenue Target Attainment, GP
/// Margin, Top 5 Customer Concentration, and Rep Target Attainment).
///
/// Both periods' value/subtitle/color are computed up front by the caller
/// (from data the Dashboard already fetches in one go) and handed to this
/// widget together — flipping the toggle is a pure `setState` on which set
/// to display, never a refetch, same philosophy as `ValueGpToggle` elsewhere
/// in this app.
///
/// `showToggle: false` renders just the MTD side with no switch at all. Used
/// for Revenue Target Attainment from 2026-08-27 through 2026-08-28 — the
/// Actual vs Target chart directly below it already shows MTD and YTD
/// permanently side by side, so a toggle there just re-answered a question
/// the chart already answered a few pixels down (see
/// Wyzesales_Rebuild_Decisions.md Section 27 for the reasoning Craig signed
/// off on at the time) — but Craig asked for the toggle back on that tile
/// too "for conformance purposes" with the other 5, so no tile uses
/// `showToggle: false` today. Left in place for any future tile that
/// genuinely doesn't need a toggle. In that mode `ytdValue`/`ytdColor` aren't
/// required.
class ToggleStatCard extends StatefulWidget {
  const ToggleStatCard({
    super.key,
    required this.label,
    required this.mtdValue,
    required this.mtdColor,
    this.mtdSubtitle,
    this.ytdValue,
    this.ytdColor,
    this.ytdSubtitle,
    this.showToggle = true,
    this.initialPeriod = StatPeriod.mtd,
    this.footnote,
  }) : assert(
          !showToggle || (ytdValue != null && ytdColor != null),
          'ytdValue and ytdColor are required whenever showToggle is true',
        );

  final String label;
  final String mtdValue;
  final Color mtdColor;
  final String? mtdSubtitle;
  final String? ytdValue;
  final Color? ytdColor;
  final String? ytdSubtitle;
  final bool showToggle;
  final StatPeriod initialPeriod;

  /// A short trailing mark appended to the label (e.g. "†") for a tile that
  /// points at a footnote printed elsewhere on the page — Quote → Order
  /// Conversion's schema caveat is the one call site today.
  final String? footnote;

  @override
  State<ToggleStatCard> createState() => _ToggleStatCardState();
}

class _ToggleStatCardState extends State<ToggleStatCard> {
  late StatPeriod _period = widget.initialPeriod;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final isMtd = _period == StatPeriod.mtd;
    final value = isMtd ? widget.mtdValue : widget.ytdValue!;
    final color = isMtd ? widget.mtdColor : widget.ytdColor!;
    final subtitle = isMtd ? widget.mtdSubtitle : widget.ytdSubtitle;
    final label = widget.footnote == null ? widget.label : '${widget.label} ${widget.footnote}';

    // 2026-08-27, Craig, after seeing real labels ellipsize on a real
    // device: "Cannot truncate. Needs to resize accordingly. The tiles all
    // need to be the same size as well." Two things follow from that:
    //   1. Every text element below wraps (maxLines: 2) instead of
    //      single-line-ellipsizing — a long label like "Top 5 Customer
    //      Concentration" or a combined value like "R 1,475,556 · R
    //      469,790" simply takes a second line rather than getting cut off.
    //      `overflow: TextOverflow.ellipsis` is kept ONLY as a last-resort
    //      safety net past 2 lines, not the primary behaviour.
    //   2. Every tile reserves the exact same vertical slots regardless of
    //      its own content — the toggle row is always the same height (an
    //      empty SizedBox stands in for it on Revenue Target Attainment,
    //      which has `showToggle: false`), so all 6 tiles come out
    //      identically sized when the caller gives them identical
    //      width+height SizedBoxes (see dashboard_screen.dart). Wrapping
    //      text no longer risks blowing that fixed height out — 2 lines at
    //      this app's compact type scale (12sp label, 20sp value, 11sp
    //      subtitle) fits comfortably inside it; see this widget's
    //      tile-sizing math in Wyzesales_Rebuild_Decisions.md if that
    //      budget ever needs revisiting.
    //
    // 2026-08-28, Craig: "can we halve the size of the toggles[?] Remove the
    // unnecessary white space on the tiles." Card padding and the gaps
    // between the label/toggle/value/subtitle rows were roughly halved at
    // the time. The toggle itself was first tried at a true half (24px ->
    // 12px, 9sp text) but Craig caught it on the next screenshot: "The MTD /
    // YTD text does not fit into the toggle!" — a 12px-tall row simply isn't
    // enough vertical room for even a 9sp line of text once the button's own
    // rendering is accounted for, so it clipped. Settled on 24px -> 20px
    // (10sp text) instead — smaller than the original, but with enough room
    // for the label to actually render.
    //
    // 2026-08-28, later the same day: the Dashboard's KPI row switched from
    // a `Wrap` of fixed-180px tiles to a grid where each tile stretches to
    // fill an equal share of a much wider row (`_KpiTileGrid` in
    // dashboard_screen.dart). That's when this card's left-aligned,
    // top-anchored layout — tuned for a narrow tile where text needed every
    // pixel of width to avoid wrapping — stopped making sense: at the new,
    // wider tile size almost everything renders on a single line, so the
    // block of text just sat pinned to the top-left with a lot of empty
    // width and height around it. Craig: "The info is all bunched up in the
    // top left corner of each tile leaving unnecessary white space to the
    // right and at the bottom." Fixed by centering the whole block, both
    // axes: `mainAxisAlignment`/`crossAxisAlignment` center it within
    // whatever height/width `_KpiTileGrid` actually gives the card, and
    // `textAlign: TextAlign.center` keeps any text that DOES still wrap (a
    // long label in the narrower 2-column/900px-or-under layout, say)
    // centered too rather than left-aligned within a centered block. Card
    // padding grown back up slightly (10/6 -> 14/10) and the inter-row gaps
    // widened (4/4/1 -> 8/8/4) now that there's real room to give the
    // content some breathing space instead of packing it as tight as
    // possible.
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              label,
              style: textTheme.bodyMedium,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 20,
              child: widget.showToggle
                  ? SegmentedButton<StatPeriod>(
                      // The default SegmentedButton reserves visible width
                      // for a checkmark icon on the selected segment
                      // (`showSelectedIcon` defaults to true) — that check
                      // mark, not just padding, was most of the extra width
                      // Craig originally flagged, so it's turned off here
                      // rather than just densified further. `styleFrom` (not
                      // a raw ButtonStyle) is used so padding/minimumSize/
                      // textStyle/visualDensity all apply consistently
                      // through Material 3's resolved segment style.
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 20),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 10),
                      ),
                      segments: const [
                        ButtonSegment(value: StatPeriod.mtd, label: Text('MTD')),
                        ButtonSegment(value: StatPeriod.ytd, label: Text('YTD')),
                      ],
                      selected: {_period},
                      onSelectionChanged: (selection) => setState(() => _period = selection.first),
                    )
                  // An empty placeholder, not omitted outright — keeps this
                  // tile's toggle row exactly as tall as every other tile's,
                  // which is what makes a `showToggle: false` tile end up
                  // the same overall size as the other 5 despite having no
                  // switch to show.
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              // headlineMedium, not headlineSmall — same reasoning as
              // StatCard: a KPI tile's own number stays bold/prominent
              // regardless of the smaller page-title scale used elsewhere.
              style: textTheme.headlineMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: textTheme.bodySmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
