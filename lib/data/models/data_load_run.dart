/// Mirrors public.data_load_runs (schema/033_wyzesales_data_load_runs.sql,
/// 2026-09-04) — one row per WyzeSalesExtract run attempt, written by that
/// program's own elevated Postgres connection (never through the app). This
/// is the "real run tracking from the start" health indicator Craig chose
/// over a plain staleness heuristic (AskUserQuestion, 2026-09-04): a failed
/// or hung extract shows up here as an actual failure/stuck run, not just an
/// old timestamp that could mean anything.
///
/// A client whose WyzeSalesExtract hasn't yet been redeployed with the
/// 2026-09-04 update has no rows in this table at all — every call site
/// reading this model handles `null`/empty by falling back to the old
/// "last extracted_at" behaviour rather than showing a false failure.
class DataLoadRun {
  final String id;
  final String clientId;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String status; // 'running' | 'success' | 'failure' — see schema/033's check constraint
  final String? errorMessage;
  final int? salesDocumentFactsRows;
  final int? stockMovementFactsRows;
  final int? itemStockSnapshotRows;
  final double? durationSeconds;

  const DataLoadRun({
    required this.id,
    required this.clientId,
    required this.startedAt,
    this.finishedAt,
    required this.status,
    this.errorMessage,
    this.salesDocumentFactsRows,
    this.stockMovementFactsRows,
    this.itemStockSnapshotRows,
    this.durationSeconds,
  });

  factory DataLoadRun.fromMap(Map<String, dynamic> map) {
    return DataLoadRun(
      id: map['id'] as String,
      clientId: map['client_id'] as String,
      startedAt: DateTime.parse(map['started_at'] as String),
      finishedAt: map['finished_at'] == null ? null : DateTime.parse(map['finished_at'] as String),
      status: map['status'] as String,
      errorMessage: map['error_message'] as String?,
      salesDocumentFactsRows: map['sales_document_facts_rows'] as int?,
      stockMovementFactsRows: map['stock_movement_facts_rows'] as int?,
      itemStockSnapshotRows: map['item_stock_snapshot_rows'] as int?,
      durationSeconds: (map['duration_seconds'] as num?)?.toDouble(),
    );
  }

  bool get isSuccess => status == 'success';
  bool get isFailure => status == 'failure';
  bool get isRunning => status == 'running';

  /// A 'running' row is only ever a live signal for as long as a real run
  /// could plausibly still be going — WyzeSalesExtract's own runs finish in
  /// minutes against real WCSA data volumes (seconds to a few minutes per
  /// the verified round-trip timings, Decisions doc Section 76), so two
  /// hours is a deliberately generous margin, not a tight one. Past that,
  /// the process almost certainly crashed, was killed, or the machine lost
  /// power mid-run without ever reaching CompleteLoadRunAsync — see
  /// schema/033's own header for why that's treated as a failure signal
  /// rather than a third on-screen state.
  bool get isStuck => isRunning && DateTime.now().toUtc().difference(startedAt.toUtc()) > const Duration(hours: 2);

  /// What the UI should actually treat this run as, folding isStuck into
  /// 'failure' so every call site (the top-bar chip, the history list) only
  /// ever needs to branch on three cases instead of re-deriving this itself.
  String get effectiveStatus => isStuck ? 'failure' : status;
}
