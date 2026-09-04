import '../../data/models/client.dart';
import '../supabase/supabase_config.dart';

/// Builds a displayable URL for a client's uploaded logo (schema/036,
/// 2026-09-04 branding feature) — null when the client has no logo set, so
/// every call site (sidebar `_BrandMark`, Settings > Company's Branding
/// card) can treat "no URL" as "show the stock WyzeSales mark instead"
/// without needing to know anything about `logo_path` itself.
///
/// `client-logos` is a public bucket (schema/036's own comment explains why
/// — a company logo isn't sensitive, and a stable public URL means no
/// signed-URL refresh logic anywhere this ever gets used), so this is a
/// plain `getPublicUrl`, not a signed URL. The `?v=` query param is a cache-
/// buster: the storage object path is always the same fixed filename
/// (`{client_id}/logo.png`), overwritten in place on every re-upload, so
/// without something in the URL that actually changes on a re-upload, a
/// browser that already cached the old image would keep showing it
/// indefinitely after a client replaces their logo.
String? clientLogoUrl(Client client) {
  final path = client.logoPath;
  if (path == null) return null;
  final base = supabase.storage.from('client-logos').getPublicUrl(path);
  final v = client.logoUpdatedAt?.millisecondsSinceEpoch ?? 0;
  return '$base?v=$v';
}
