import 'dart:convert';

/// Why cloud sync must stay disabled for these build-time values, or null.
/// Local capture never depends on this; a non-null result only skips Supabase.
String? cloudConfigurationError(String url, String key) {
  if (url.isEmpty || key.isEmpty) return 'Cloud sync is not configured';
  final projectUri = Uri.tryParse(url);
  if (projectUri == null ||
      projectUri.scheme != 'https' ||
      projectUri.host.isEmpty) {
    return 'SUPABASE_URL must use HTTPS';
  }
  if (_isServerKey(key)) {
    return 'SUPABASE_ANON_KEY must be a publishable/anon key, not a secret key';
  }
  return null;
}

bool _isServerKey(String key) {
  if (key.startsWith('sb_secret_')) return true;
  final parts = key.split('.');
  if (parts.length != 3) return false;
  try {
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return claims is Map && claims['role'] == 'service_role';
  } catch (_) {
    return false;
  }
}
