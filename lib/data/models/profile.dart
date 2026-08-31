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
  final bool isActive;
  final bool isPlatformAdmin;

  const Profile({
    required this.id,
    required this.clientId,
    required this.name,
    required this.email,
    this.contactNumber,
    required this.level,
    this.repCode,
    this.branchCode,
    this.isActive = true,
    this.isPlatformAdmin = false,
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
      isActive: map['is_active'] as bool? ?? true,
      isPlatformAdmin: map['is_platform_admin'] as bool? ?? false,
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
