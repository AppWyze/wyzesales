// `FilterBar` (the inline Category/Item/Sales Person/Branch/Customer boxes
// that used to sit on Sales Analysis/Quote Analysis/Sales Order Analysis'
// Table tab) was removed 2026-08-27 — Craig: "check the sizing and
// consistency of all of the filter boxes across the application. Some of
// them are... double labelled." Those five boxes duplicated the app-wide
// `GlobalFilterBar` (mounted by AppShell on every screen, including these
// three) with zero new information: both showed "All" when unset and the
// same selected entity when set, since both read/wrote the exact same
// `globalFiltersProvider` state. See `entity_search_field.dart`'s doc
// comment for the full reasoning and `document_analysis_view.dart` for
// what replaced this file's call site.
//
// This file is kept only so its old path doesn't dangle; delete it outright
// whenever convenient (nothing imports it any more).
