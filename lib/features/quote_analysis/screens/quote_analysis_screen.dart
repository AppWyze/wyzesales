import 'package:flutter/material.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/document_analysis_view.dart';

class QuoteAnalysisScreen extends StatelessWidget {
  const QuoteAnalysisScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppShell(
      title: 'Quote Analysis',
      currentRoute: '/quote-analysis',
      body: DocumentAnalysisView(documentKinds: ['quote']),
    );
  }
}
