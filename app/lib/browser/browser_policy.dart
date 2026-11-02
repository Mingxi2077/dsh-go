import 'dart:io';

/// Policy for the public-web workspace. Internal DSH pages have a separate
/// navigation/authentication path and must not be loaded with these controls.
abstract final class BrowserPolicy {
  static const maxUrlChars = 8192;

  static Uri? parseAddress(String input) {
    final value = input.trim();
    if (value.isEmpty || value.length > maxUrlChars || RegExp(r'[\s\\]').hasMatch(value)) return null;
    // Only add https to a hostname, not to an unknown URI scheme.
    final candidate = value.contains('://') ? value : 'https://$value';
    final uri = Uri.tryParse(candidate);
    return uri != null && allows(uri) ? uri : null;
  }

  static bool allows(Uri uri) {
    try {
      return _allows(uri);
    } on FormatException {
      return false;
    }
  }

  static bool _allows(Uri uri) {
    if (!['http', 'https'].contains(uri.scheme) || !uri.hasAuthority || uri.userInfo.isNotEmpty) return false;
    final raw = uri.toString();
    if (raw.length > maxUrlChars || RegExp(r'[\x00-\x20\x7f\\]').hasMatch(raw)) return false;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.isEmpty || host.contains('%') || uri.port < 1 || uri.port > 65535) return false;
    if (host == 'localhost' ||
        ['.localhost', '.local', '.internal', '.lan', '.home', '.test', '.invalid'].any(host.endsWith)) {
      return false;
    }
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      final bytes = address.rawAddress;
      if (address.type == InternetAddressType.IPv4) return _publicV4(bytes);
      // IPv4 mapped IPv6, loopback, link-local, unique-local, multicast and
      // other non-global ranges are not external sites. Accept global unicast.
      if (bytes.take(10).every((b) => b == 0) && bytes[10] == 255 && bytes[11] == 255) {
        return _publicV4(bytes.skip(12).toList());
      }
      return (bytes[0] & 0xe0) == 0x20;
    }
    // Reject shorthand/hex IP spellings that Chromium may resolve as local IPs.
    final labels = host.split('.');
    if (labels.length < 2 || labels.any((label) => label.isEmpty)) return false;
    if (labels.every((label) => RegExp(r'^(?:[0-9]+|0x[0-9a-f]+)$').hasMatch(label))) return false;
    return labels.every((label) => label.length <= 63 && RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label));
  }

  static bool _publicV4(List<int> b) =>
      b[0] != 0 &&
      b[0] != 10 &&
      b[0] != 127 &&
      b[0] < 224 &&
      !(b[0] == 169 && b[1] == 254) &&
      !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
      !(b[0] == 192 && b[1] == 168) &&
      !(b[0] == 100 && b[1] >= 64 && b[1] <= 127) &&
      !(b[0] == 198 && (b[1] == 18 || b[1] == 19));

  /// Reference sources omit queries/fragments. Automatic tab/history storage
  /// applies this before preserving recognized search terms; explicitly saved
  /// bookmarks may retain the full URL the user chose to save.
  static Uri savedUrl(Uri uri) => Uri.parse(uri.toString().split(RegExp(r'[?#]')).first);
}
