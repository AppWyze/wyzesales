import 'package:flutter/material.dart';

enum ValueMeasure { rValue, grossProfit }

extension ValueMeasureLabel on ValueMeasure {
  String get label => this == ValueMeasure.rValue ? 'R Value' : 'R Gross Profit';
}

/// The "R Value / R Gross Profit" toggle repeated on the Dashboard, Sales
/// Analysis, YTD Comparative, and Sales by [Dimension] screens
/// (Wyzesales_Screens_and_Recommendations.md Section 1).
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
      ],
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
