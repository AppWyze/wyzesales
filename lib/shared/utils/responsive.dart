import 'package:flutter/material.dart';

/// Returns a safe maximum height for a dialog's ConstrainedBox, given the
/// dialog's preferred (desktop-sized) height.
///
/// Several of this app's dialogs (Add client, Edit license, Edit plan, etc.
/// — see platform_admin_screen.dart) hardcode a maxHeight tuned for desktop
/// screens. On a shorter phone viewport that fixed height can exceed what's
/// actually visible — the on-screen keyboard (viewInsets.bottom) and system
/// status/nav bars (viewPadding) both eat into the real available space —
/// so content anchored to the bottom of the dialog (typically the Save
/// button) gets clipped rather than shown or scrolled to.
///
/// Pair this with `insetPadding: dialogInsetPadding` on the same Dialog so
/// the margin this function reserves actually matches what's applied —
/// otherwise Dialog's own default insetPadding (24 top + 24 bottom) eats
/// into the same space a second time. The extra 24px beyond that covers
/// mobile-browser viewport-reporting slop (e.g. address bar show/hide),
/// which otherwise leaves a razor-thin, easy-to-clip margin.
///
/// Ported from SeaWyze's identical helper (Craig's parity request,
/// 2026-08-25 — see Wyzesales_Rebuild_Decisions.md) so the Platform Admin
/// dialogs built on the same `_dialogHeader`/`_tf`/`_dialogFooter` pattern
/// behave the same way on mobile as they do on SeaWyze.
///
/// Use as: `maxHeight: dialogMaxHeight(context, 700)`.
double dialogMaxHeight(BuildContext context, double preferred) {
  final media = MediaQuery.of(context);
  final available = media.size.height -
      media.viewInsets.bottom -
      media.viewPadding.vertical -
      dialogInsetPadding.vertical -
      24;
  return available.clamp(300, preferred);
}

/// Reduced Dialog insetPadding for mobile — pair with [dialogMaxHeight].
const dialogInsetPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 16);

/// Same idea as [dialogMaxHeight], for width — 2026-09-07 (Craig: "check the
/// entire application... optimised for Mobile, Tablet and Desktop browser").
/// A handful of dialogs across the app (the "Add filter" entity picker, the
/// Document/Presets filter dialogs) hardcode a `SizedBox(width: 360)`-style
/// preferred width tuned for desktop, the same failure mode
/// [dialogMaxHeight]'s own doc comment describes for height: on a ~360-400px
/// phone, `AlertDialog`'s default `insetPadding` (40 horizontal) plus this
/// app's own [dialogInsetPadding] (16 horizontal, once a dialog opts into
/// it) already eats into the available width before the dialog's own
/// content even gets a say, so a hardcoded 360px preferred width can exceed
/// what's actually on screen and clip or force horizontal overflow.
///
/// Use as: `width: dialogMaxWidth(context, 360)` on the dialog's outer
/// `SizedBox`/`ConstrainedBox`, paired with `insetPadding: dialogInsetPadding`
/// on the same `Dialog`/`AlertDialog` so the margin this function reserves
/// actually matches what's applied — same pairing rule as
/// [dialogMaxHeight]/[dialogInsetPadding] above.
double dialogMaxWidth(BuildContext context, double preferred) {
  final available = MediaQuery.of(context).size.width - dialogInsetPadding.horizontal - 24;
  return available.clamp(240, preferred);
}
