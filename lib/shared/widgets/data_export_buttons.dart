import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Everything one export needs: column headers, the rows as already-
/// formatted display strings (same Rand/percent/quantity formatting the
/// screen itself shows — a raw unformatted number would be more
/// spreadsheet-friendly for later math, but matching what's on screen is
/// the least surprising default and avoids a second, divergent formatting
/// path per screen), a base file name (no extension — one is added per
/// format), and a title line for the PDF's own heading.
class ExportData {
  const ExportData({
    required this.headers,
    required this.rows,
    required this.fileNameBase,
    required this.title,
  });

  final List<String> headers;
  final List<List<String>> rows;
  final String fileNameBase;
  final String title;
}

/// Real CSV/PDF export, replacing the old placeholder that only ever showed
/// a "not implemented yet" SnackBar (2026-08-31, Craig: flagged as the most
/// urgent of the gaps from the "what's missing" review — a button that
/// claims to work but doesn't is worse than no button). WyzeSales runs in
/// the browser only (Craig confirmed, no native desktop build), so "save"
/// here just means "trigger the browser's normal download" — file_saver's
/// web implementation does exactly that, no native save dialog or file-
/// system permissions involved.
///
/// `onExport` is a callback rather than pre-computed data because not every
/// caller can hand over rows for free: DocumentAnalysisView only ever holds
/// one server-fetched *page* in memory (schema/012's pagination — see that
/// file's own doc comment), so its callback does a fresh, larger fetch
/// against the same filters when Export is actually pressed, rather than
/// exporting just the 100 rows currently on screen. Screens that already
/// hold their full (unpaginated, per-dimension) result set in memory just
/// wrap it in `() async => ExportData(...)` — no extra fetch needed.
class DataExportButtons extends StatefulWidget {
  const DataExportButtons({super.key, required this.onExport});

  final Future<ExportData> Function() onExport;

  @override
  State<DataExportButtons> createState() => _DataExportButtonsState();
}

class _DataExportButtonsState extends State<DataExportButtons> {
  bool _exporting = false;

  Future<void> _export(_ExportFormat format) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final data = await widget.onExport();
      final bytes = format == _ExportFormat.csv ? _buildCsv(data) : await _buildPdf(data);
      await FileSaver.instance.saveFile(
        name: data.fileNameBase,
        bytes: bytes,
        fileExtension: format == _ExportFormat.csv ? 'csv' : 'pdf',
        mimeType: format == _ExportFormat.csv ? MimeType.csv : MimeType.pdf,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Uint8List _buildCsv(ExportData data) {
    // csv 8.0.0 replaced the old class-based API (ListToCsvConverter /
    // CsvToListConverter — what this was originally written against, from
    // memory of an older major version) with a `Csv` object exposing
    // `.encode()`/`.decode()`, plus two ready-made instances: the
    // pre-configured top-level `csv` (standard comma/quote settings — used
    // here, so behaviour matches what this was always designed around) and
    // `excel` (Excel-locale-specific settings, e.g. a different field
    // separator in some locales — deliberately NOT used, since the manual
    // UTF-8 BOM below is already this file's whole strategy for Excel
    // compatibility, and swapping in unfamiliar delimiter defaults on top of
    // that would be an unforced, undocumented behaviour change). The local
    // variable below is named `csvString`, not `csv`, so it doesn't shadow
    // the package's own top-level `csv` instance being called on the same
    // line.
    final csvString = csv.encode([data.headers, ...data.rows]);
    // utf8 with a BOM — Excel on both Mac and Windows otherwise guesses the
    // wrong encoding for anything beyond plain ASCII (the 'R' Rand prefix
    // and thousand-separator characters are fine, but a customer/item name
    // with an accented character isn't) and mangles it on open.
    return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csvString)]);
  }

  Future<Uint8List> _buildPdf(ExportData data) async {
    // Confirmed 2026-08-31 against Craig's first real PDF export (YTD
    // Comparative): the pdf package's default Helvetica/Helvetica-Bold base
    // fonts have no glyph for an em dash (U+2014) — every "—" rendered as a
    // tofu box, both in the title ("WyzeSales — YTD Comparative") and in
    // every null-value cell (formatRand/formatPercent/formatQuantity's own
    // "—" convention — see formatters.dart). Fixing this by embedding a real
    // Unicode font (`printing`'s PdfGoogleFonts, fetched over the network at
    // render time, or a bundled TTF asset) would be a second new dependency
    // and a new failure mode on top of two rounds of real-toolchain surprises
    // already — for one known character, that's not worth it. Screen and CSV
    // output are untouched (Flutter's own font and Excel both render an em
    // dash fine); this substitution is scoped to the PDF path only, applied
    // to the title, headers, and every cell right before they reach the PDF
    // renderer. If a future export hits the same "Unable to find a font to
    // draw ... try TextStyle.fontFallback" error for some other character,
    // add it to this same map rather than reaching for a font dependency.
    String pdfSafe(String value) => value.replaceAll('—', '-').replaceAll('–', '-');
    final title = pdfSafe(data.title);
    final headers = data.headers.map(pdfSafe).toList();
    final rows = data.rows.map((row) => row.map(pdfSafe).toList()).toList();
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        // `MultiPage` refuses (PdfToBigPageException) past this many pages —
        // a debug-build-only safety net against a genuinely broken widget
        // looping forever, defaulting to just 20 (confirmed against Craig's
        // real "Export failed" screenshot from Sales Analysis' Table tab,
        // which has far more than 20 pages' worth of rows once fully
        // fetched). Raised well above what document_analysis_view.dart's own
        // 20,000-row export cap could ever produce at ~40-50 rows/page in
        // this font size, so a large-but-legitimate export never trips it —
        // this is a page-count ceiling, not a memory pre-allocation, so
        // setting it high costs nothing for the normal, much smaller exports.
        maxPages: 5000,
        pageFormat: PdfPageFormat.a4.landscape,
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title, style: const pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Divider(),
          ],
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: rows,
            headerStyle: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignment: pw.Alignment.centerLeft,
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          ),
        ],
      ),
    );
    return doc.save();
  }

  @override
  Widget build(BuildContext context) {
    if (_exporting) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: EdgeInsets.all(6),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Export PDF',
          icon: const Icon(Icons.picture_as_pdf_outlined),
          onPressed: () => _export(_ExportFormat.pdf),
        ),
        IconButton(
          tooltip: 'Export CSV',
          icon: const Icon(Icons.table_view_outlined),
          onPressed: () => _export(_ExportFormat.csv),
        ),
      ],
    );
  }
}

enum _ExportFormat { csv, pdf }

/// Thrown by an `onExport` callback for any expected, user-facing reason an
/// export can't proceed right now — too much data to hand to the browser in
/// one go (see DocumentAnalysisView's own cap), or the underlying data
/// simply isn't ready yet. `implements Exception` rather than a bare `throw
/// 'string'` so it reads cleanly in the SnackBar without an "Exception:"
/// prefix, while still being a proper typed exception rather than throwing
/// an arbitrary object.
class ExportUnavailableException implements Exception {
  const ExportUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}
