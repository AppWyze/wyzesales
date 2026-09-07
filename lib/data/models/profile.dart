/// Mirrors public.profiles (schema/001_wyzesales_foundation.sql Section 6).
enum UserLevel { user, reguser, adminuser, superuser }

UserLevel userLevelFromString(String value) {
  return UserLevel.values.firstWhere(
    (l) => l.name == value,
    orElse: () => UserLevel.user,
  );
}

class Profile {
  final String id;
  final String clientId;
  final String name;
  final String email;
  final String? contactNumber;
  final UserLevel level;
  final String? repCode;
  final String? branchCode;

  /// A RegUser's own assigned value for whichever dimension THIS CLIENT
  /// flags is_rls_scope (client_dimensions, schema/038), WHEN that dimension
  /// isn't 'branch' — schema/039. WCSA keeps using `branchCode` exactly as
  /// it does today (its RLS-scope dimension is 'branch'); this stays null
  /// and unused for it. Null for a plain 'user' too — only RegUsers carry a
  /// scope value here (see migration 039's own column comment) — Settings >
  /// Users' Add/Edit dialogs only show/write this field for a RegUser on a
  /// client whose RLS-scope dimension is something other than Branch.
  final String? rlsScopeCode;

  final bool isActive;
  final bool isPlatformAdmin;

  /// 'A' (the original KPI-tile/pie-chart Dashboard) or 'B' (the classification-
  /// table layout, schema/053) — 2026-09-08, Craig, looking at Edgetec's old
  /// standalone report: "I would like to offer the current dashboard as
  /// option A and this one as option B. The user can pick and set to default
  /// and then the default displays on log in." Persisted per LOGIN, not per
  /// client — two users at the same client can each pick their own. Defaults
  /// to 'A' at the DB column level (schema/053), so every existing login
  /// keeps seeing exactly what it does today until they explicitly switch.
  final String dashboardLayout;

  const Profile({
    required this.id,
    required this.clientId,
    required this.name,
    required this.email,
    this.contactNumber,
    required this.level,
    this.repCode,
    this.branchCode,
    this.rlsScopeCode,
    this.isActive = true,
    this.isPlatformAdmin = false,
    this.dashboardLayout = 'A',
  });

  factory Profile.fromMap(Map<String, dynamic> map) {
    return Profile(
      id: map['id'] as String,
      clientId: map['client_id'] as String,
      name: map['name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      contactNumber: map['contact_number'] as String?,
      level: userLevelFromString(map['level'] as String? ?? 'user'),
      repCode: map['rep_code'] as String?,
      branchCode: map['branch_code'] as String?,
      rlsScopeCode: map['rls_scope_code'] as String?,
      isActive: map['is_active'] as bool? ?? true,
      isPlatformAdmin: map['is_platform_admin'] as bool? ?? false,
      dashboardLayout: map['dashboard_layout'] as String? ?? 'A',
    );
  }

  // schema/008's role migration (2026-08-25) retired superuser as a role
  // anyone is actually assigned — every adminuser can now manage users
  // (Craig's decision 8: "all adminuser's should be able to add, delete
  // and edit users"), and cross-tenant reach is a separate concern
  // entirely (see isPlatformAdmin below), not a role level. superuser
  // stays in the UserLevel enum/DB type as an unused legacy value (see
  // schema/008's comment on why it can't be cleanly dropped), so this
  // getter deliberately does not special-case it — nothing should be
  // assigned that level again.
  bool get canManageUsers => level == UserLevel.adminuser;
  bool get canEditBudgets => level == UserLevel.adminuser;
}
