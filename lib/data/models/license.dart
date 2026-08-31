import 'pricing_plan.dart';

/// Mirrors public.license (schema/008_wyzesales_multitenancy.sql Section 2).
/// Users-only shape — no max_vessels/base_vessels, unlike SeaWyze's
/// LicenseModel, since a WyzeSales client is users only. `plan` is populated
/// when the row was fetched with the pricing_plan join (see
/// LicenseRepository.getLicense); null otherwise.
class License {
  final String id;
  final String clientId;
  final String? planId;
  final int maxUsers;
  final int baseUsers;
  final DateTime startDate;
  final DateTime endDate;
  final String status;
  final num? annualPrice;
  final num discountPercent;
  final PricingPlan? plan;

  const License({
    required this.id,
    required this.clientId,
    this.planId,
    required this.maxUsers,
    required this.baseUsers,
    required this.startDate,
    required this.endDate,
    required this.status,
    this.annualPrice,
    this.discountPercent = 0,
    this.plan,
  });

  factory License.fromMap(Map<String, dynamic> map) {
    final planMap = map['pricing_plan'] as Map<String, dynamic>?;
    return License(
      id: map['id'] as String,
      clientId: map['client_id'] as String,
      planId: map['plan_id'] as String?,
      maxUsers: map['max_users'] as int? ?? 5,
      baseUsers: map['base_users'] as int? ?? 5,
      startDate: DateTime.parse(map['start_date'] as String),
      endDate: DateTime.parse(map['end_date'] as String),
      status: map['status'] as String? ?? 'active',
      annualPrice: map['annual_price'] as num?,
      discountPercent: map['discount_percent'] as num? ?? 0,
      plan: planMap != null ? PricingPlan.fromMap(planMap) : null,
    );
  }

  bool get isActive => status == 'active' && endDate.isAfter(DateTime.now());

  int get daysRemaining => endDate.difference(DateTime.now()).inDays;

  bool get isExpiringSoon => isActive && daysRemaining <= 30;

  /// Prefers the joined plan's own `baseUsers` over this license row's own
  /// `baseUsers` column whenever a plan is available. `license.base_users`
  /// is a one-time snapshot taken when the license was created/last edited
  /// — it has no trigger keeping it in sync with the plan it's linked to,
  /// so if the plan's base_users is changed later (Platform Admin > Pricing)
  /// this license's own copy goes stale exactly the way `annual_price` used
  /// to (Craig, 2026-08-28, spotted this from a real example: a license
  /// with max_users=10 on a plan whose base_users is also 10 was still
  /// showing "5 additional users" on Settings > License's pricing
  /// breakdown, because the license row's own stale base_users was 5). The
  /// fallback to the license's own `baseUsers` only matters for a license
  /// with no plan linked, where there's nothing else to compute from.
  int get additionalUsers => (maxUsers - (plan?.baseUsers ?? baseUsers)).clamp(0, 999999);

  /// Live monthly total at the license's current max_users, with
  /// discount_percent applied — recomputes from the joined plan's current
  /// rates rather than trusting the stored `annualPrice` column, which is
  /// only as fresh as the last time the Pricing tab recalculated it (see
  /// schema/008 Section 2's comment on why discount_percent exists at all:
  /// this recompute-on-read is exactly what makes a negotiated discount
  /// self-correct when the base plan's rates change, instead of going stale
  /// the way a frozen annual_price override would).
  num? get discountedMonthly {
    final p = plan;
    if (p == null) return null;
    final base = p.monthlyForSeats(maxUsers);
    return base * (1 - discountPercent / 100);
  }
}
