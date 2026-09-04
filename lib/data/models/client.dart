/// Mirrors public.clients (schema/001_wyzesales_foundation.sql Section 1,
/// contact/address fields added by schema/016_wyzesales_client_profile_
/// fields.sql). WyzeSales' tenant unit is "users only, no vessels" (Craig's
/// framing of the multi-tenancy ask), so this has no vessel-shaped fields —
/// but it otherwise mirrors SeaWyze's CompanyModel field-for-field, minus
/// `documentsUrl`: Craig, 2026-08-28, asked for "all of the fields as per
/// Seawyze" on both the Platform Admin Client edit and Settings Company
/// edit, "but without the Company Documents function," so there was never a
/// reason to add a column nothing writes to.
///
/// All the new fields are nullable — a client created before schema/016
/// (or one whose admin just hasn't filled them in) has none of them set,
/// and every call site needs to render that as "—", not crash.
class Client {
  final String id;
  final String code;
  final String name;
  final String? contactName;
  final String? contactNumber;
  final String? contactEmail;
  final String? address1;
  final String? address2;
  final String? address3;
  final String? city;
  final String? country;
  final String? postalCode;
  final DateTime createdAt;

  /// Storage object path for this client's uploaded logo
  /// (`client-logos/{client_id}/logo.png`, schema/036, 2026-09-04) — null for
  /// every client that hasn't set one, which is the app-wide default (the
  /// sidebar falls back to the stock WyzeSales mark). Use `clientLogoUrl`
  /// (core/utils/client_logo.dart) to turn this into a displayable URL rather
  /// than building the storage URL ad hoc at each call site.
  final String? logoPath;

  /// When `logoPath` was last (re)uploaded — exists purely as a cache-buster
  /// for `clientLogoUrl`: the storage path itself never changes across a
  /// re-upload (always the same fixed filename, overwritten in place), so
  /// without this a browser that already cached the old image would keep
  /// showing it after a client replaces their logo.
  final DateTime? logoUpdatedAt;

  const Client({
    required this.id,
    required this.code,
    required this.name,
    this.contactName,
    this.contactNumber,
    this.contactEmail,
    this.address1,
    this.address2,
    this.address3,
    this.city,
    this.country,
    this.postalCode,
    required this.createdAt,
    this.logoPath,
    this.logoUpdatedAt,
  });

  factory Client.fromMap(Map<String, dynamic> map) {
    return Client(
      id: map['id'] as String,
      code: map['code'] as String,
      name: map['name'] as String,
      contactName: map['contact_name'] as String?,
      contactNumber: map['contact_number'] as String?,
      contactEmail: map['contact_email'] as String?,
      address1: map['address1'] as String?,
      address2: map['address2'] as String?,
      address3: map['address3'] as String?,
      city: map['city'] as String?,
      country: map['country'] as String?,
      postalCode: map['postal_code'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      logoPath: map['logo_path'] as String?,
      logoUpdatedAt: map['logo_updated_at'] == null ? null : DateTime.parse(map['logo_updated_at'] as String),
    );
  }
}
