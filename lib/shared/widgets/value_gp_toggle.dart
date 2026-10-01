import 'package:flutter/material.dart';

// 2026-10-01, Craig: "On all of the screens we currently have R Value and R
// Gross Profit. We need a third one Quantity. This will obviously then show
// the same screens / views but loaded with the Quantity values." Added as a
// third case on the existing enum/toggle rather than a parallel mechanism -
// every screen below already had a clean `_measure == ValueMeasure.rValue ?
// a : b` branch point (value vs profit), and the underlying data was already
// there to extend it: v_consolidated_sales/v_dimension_monthly_sales/
// v_sales_documents (and the RPCs built on them) already return a `quantity`
// column today - nothing on the Supabase side needed to change, only which
// field each screen reads and how it's formatted (formatQuantity, not
// formatRand - see core/utils/formatters.dart).
//
// Target/Budget overlays (Sales Analysis' Target bars) are already gated to
// `_measure == ValueMeasure.rValue` specifically, not `!= grossProfit` - a
// Rand-denominated Sales Budget target has no meaningful Quantity
// equivalent anywhere in the schema (budget_figures/sales_forecast are both
// Rand-only), so that existing gate already excludes Quantity for free,
// exactly the same way it already excluded Gross Profit - no new
// special-casing needed there.
enum ValueMeasure { rValue, grossProfit, quantity }

extension ValueMeasureLabel on ValueMeasure {
  String get label {
    switch (this) {
      case ValueMeasure.rValue:
        return 'R Value';
      case ValueMeasure.grossProfit:
        return 'R Gross Profit';
      case ValueMeasure.quantity:
        return 'Quantity';
    }
  }
}

/// The "R Value / R Gross Profit / Quantity" toggle repeated on the
/// Dashboard, Sales Analysis, YTD Comparative, and Sales by [Dimension]
/// screens (Wyzesales_Screens_and_Recommendations.md Section 1).
class ValueGpToggle extends StatelessWidget {
  const ValueGpToggle({super.key, required this.value, required this.onChanged});

  final ValueMeasure value;
  final ValueChanged<ValueMeasure> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ValueMeasure>(
      segments: const [
        ButtonSegment(value: ValueMeasure.rValue, label: Text('R Value')),
        ButtonSegment(value: ValueMeasure.grossProfit, label: Text('R Gross Profit')),
        ButtonSegment(value: ValueMeasure.quantity, label: Text('Quantity')),
      ],
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
