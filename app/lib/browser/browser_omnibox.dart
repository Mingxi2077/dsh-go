import 'browser_policy.dart';

enum BrowserSearchEngine {
  bing,
  google,
  baidu,
  duckduckgo;

  String get label => switch (this) {
    bing => 'Bing',
    google => 'Google',
    baidu => '百度',
    duckduckgo => 'DuckDuckGo',
  };

  Uri search(String terms) => switch (this) {
    bing => Uri.https('www.bing.com', '/search', {'q': terms}),
    google => Uri.https('www.google.com', '/search', {'q': terms}),
    baidu => Uri.https('www.baidu.com', '/s', {'wd': terms}),
    duckduckgo => Uri.https('duckduckgo.com', '/', {'q': terms}),
  };
}

class BrowserNavigationIntent {
  const BrowserNavigationIntent({required this.url, this.query});

  final Uri url;
  final String? query;
  bool get isSearch => query != null;
}

/// The address field and start page share one decision, made on submission.
/// No requests or suggestions are sent to a search service while typing.
abstract final class BrowserOmnibox {
  static const _searchOperators = {
    'site',
    'filetype',
    'intitle',
    'allintitle',
    'inurl',
    'allinurl',
    'intext',
    'allintext',
    'related',
    'before',
    'after',
    'cache',
  };

  static BrowserNavigationIntent? resolve(String input, {BrowserSearchEngine engine = BrowserSearchEngine.bing}) {
    final value = input.trim();
    if (value.isEmpty || value.length > BrowserPolicy.maxUrlChars || RegExp(r'[\x00-\x1f\x7f\\]').hasMatch(value)) {
      return null;
    }
    final scheme = RegExp(r'^([a-z][a-z0-9+.-]*):', caseSensitive: false).firstMatch(value)?.group(1)?.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      final rest = value.substring(value.indexOf(':') + 1).replaceFirst(RegExp(r'^/+'), '');
      return _address('$scheme://$rest');
    }
    if (value.contains('://')) return null;
    if (scheme != null && !scheme.contains('.') && !_searchOperators.contains(scheme)) return null;

    // An explicitly typed address that is forbidden must not become a search
    // containing a localhost token, custom protocol payload or credentials.
    final authority = value.split(RegExp(r'[/\?#]')).first;
    final hasSearchOperator = scheme != null && _searchOperators.contains(scheme);
    final addressLike =
        !hasSearchOperator &&
        !RegExp(r'\s').hasMatch(authority) &&
        (authority.contains('.') ||
            authority.contains('@') ||
            authority.startsWith('[') ||
            authority.toLowerCase() == 'localhost' ||
            authority.toLowerCase().startsWith('localhost:') ||
            RegExp(r'^0x[0-9a-f]+$', caseSensitive: false).hasMatch(authority) ||
            (value != authority && RegExp(r'^[0-9]+$').hasMatch(authority)));
    if (addressLike) return _address('https://$value');
    if (value.startsWith('/') || value.startsWith('[')) return null;

    final url = engine.search(value);
    return BrowserPolicy.allows(url) ? BrowserNavigationIntent(url: url, query: value) : null;
  }

  static BrowserNavigationIntent? _address(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && BrowserPolicy.allows(uri) ? BrowserNavigationIntent(url: uri) : null;
  }

  /// Automatic history and restored tabs keep only a search endpoint's
  /// necessary query. Explicit bookmarks retain the address the user saved;
  /// model references continue using BrowserPolicy.savedUrl (no query at all).
  static Uri restorableUrl(Uri url) {
    final path = BrowserPolicy.savedUrl(url);
    if (url.scheme != 'https' || !BrowserPolicy.allows(url)) return path;
    final host = url.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final parameter = switch ((host, url.path)) {
      ('bing.com', '/search') || ('google.com', '/search') => 'q',
      ('baidu.com', '/s') => 'wd',
      ('duckduckgo.com', '') || ('duckduckgo.com', '/') => 'q',
      _ => null,
    };
    if (parameter == null) return path;
    try {
      final values = url.queryParametersAll[parameter];
      if (values == null || values.length != 1 || values.single.trim().isEmpty) return path;
      return path.replace(queryParameters: {parameter: values.single});
    } on FormatException {
      // Browsable URLs can contain non-UTF-8 query bytes. Do not let their
      // decoding break tab/history persistence, or retain the raw parameters.
      return path;
    }
  }
}
