/// Mirrors public.pricing_plan (schema/008_wyzesales_multitenancy.sql
/// Section 1). Users-only shape — no vessel-priced fields at all, unlike
/// SeaWyze's PricingPlanModel (pricePerAdditionalVessel/baseVessels), since
/// a WyzeSales client is users only (Craig's framing of the multi-tenancy
/// ask). Rates are ZAR/month; annual figures are derived by multiplying by
/// 12 wherever they're shown or (re)computed (see License.discountedMonthly
/// below and the Platform Admin Pricing tab).
class PricingPlan {
  final String id;
  final String name;
  final String? description;
  final num basePrice;
  final num pricePerAdditionalUser;
  final int baseUsers;
  final String currency;
  final bool isActive;
  final DateTime createdAt;

  const PricingPlan({
    required this.id,
    required this.name,
    this.description,
    required this.basePrice,
    required this.pricePerAdditionalUser,
    required this.baseUsers,
    required this.currency,
    required this.isActive,
    required this.createdAt,
  });

  factory PricingPlan.fromMap(Map<String, dynamic> map) {
    return PricingPlan(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      basePrice: map['base_price'] as num? ?? 0,
      pricePerAdditionalUser: map['price_per_additional_user'] as num? ?? 0,
      baseUsers: map['base_users'] as int? ?? 5,
      currency: map['currency'] as String? ?? 'ZAR',
      isActive: map['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  /// Monthly total for a given seat count, before any per-license discount
  /// (see License.monthlyTotal, which applies discount_percent on top of
  /// this — Craig's decision 5: a negotiated rate is a percentage off the
  /// plan-derived total, not a frozen absolute number, so it stays correct
  /// automatically if these base rates change later).
  num monthlyForSeats(int seats) {
    final additional = (seats - baseUsers).clamp(0, 999999);
    return basePrice + additional * pricePerAdditionalUser;
  }

  /// `monthlyForSeats(seats)` with a per-license discount applied, times 12
  /// — the actual value written to `license.annual_price`. Single source of
  /// truth for the Platform Admin recalculate-on-save logic added
  /// 2026-08-28 (Craig: "Licenses: Annual price needs to be recalculated on
  /// SAVE" / "Pricing: Annual price needs to be recalculated on SAVE"),
  /// used identically by the License tab (one license, its own discount)
  /// and the Pricing tab (every license on the plan that was just saved,
  /// each with its own discount). Deliberately reuses `monthlyForSeats`
  /// rather than re-deriving the base+additional-users math a second time.
  num annualPriceForSeats(int seats, num discountPercent) {
    return monthlyForSeats(seats) * (1 - discountPercent / 100) * 12;
  }
}
