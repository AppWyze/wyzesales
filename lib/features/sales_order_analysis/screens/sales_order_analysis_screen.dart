import 'package:flutter/material.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/document_analysis_view.dart';

class SalesOrderAnalysisScreen extends StatelessWidget {
  const SalesOrderAnalysisScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppShell(
      title: 'Sales Order Analysis',
      currentRoute: '/sales-order-analysis',
      body: DocumentAnalysisView(documentKinds: ['sales_order']),
    );
  }
}
