import '../../core/constants/fiscal.dart';

/// Lightweight reference/dimension rows — mirrors schema/001 Section 2.
/// Kept as plain (code, name) pairs since that's all the pickers/filter bar
/// need; screens that need more (e.g. an item's default price) can extend
/// this later without disturbing the picker widgets.
class CodeName {
  final String code;
  final String? name;

  const CodeName({required this.code, this.name});

  factory CodeName.fromMap(Map<String, dynamic> map, {required String codeKey, String nameKey = 'name'}) {
    return CodeName(code: map[codeKey] as String, name: map[nameKey] as String?);
  }

  /// What filter bars / pickers display — falls back to the code itself so
  /// an unnamed new branch/customer still shows something useful rather than
  /// a blank row.
  String get displayLabel => (name == null || name!.isEmpty) ? code : name!;

  @override
  String toString() => displayLabel;
}

/// One top-bar search match, tagged with the dimension it came from — see
/// ReferenceDataRepository.searchAllDimensions.
class DimensionSearchResult {
  final SalesDimension dimension;
  final CodeName entity;
  const DimensionSearchResult({required this.dimension, required this.entity});
}

/// One top-bar Document search match (2026-08-26, Craig: "Include Document
/// in Top Bar search") — see ReferenceDataRepository.searchDocuments.
/// `documentKind` (invoice/credit_note/quote/sales_order) decides which
/// analysis screen a hit should open on.
class DocumentSearchResult {
  final String document;
  final String documentKind;
  const DocumentSearchResult({required this.document, required this.documentKind});
}
