import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

import 'browser_policy.dart';

/// A short-lived authorization page. Its URL never enters browser storage.
/// The engine owns state/PKCE and credential exchange; the UI only follows it.
class BrowserAuthorization {
  const BrowserAuthorization({
    required this.id,
    required this.url,
    required this.completed,
    required this.isCurrent,
    required this.cancel,
    this.callbackOrigin,
    this.preferSystem = false,
    this.onSystemBrowserOpened,
    this.onForumRedirect,
  });

  final Object id;
  final Uri url;
  final Uri? callbackOrigin;
  final Future<void> completed;
  final bool Function() isCurrent;
  final Future<void> Function() cancel;
  final bool preferSystem;
  final void Function()? onSystemBrowserOpened;

  /// Only the forum producer sets this. The auth controller admits the exact
  /// dshgo://forum/auth callback; nonce/RSA validation remains with that producer.
  final Future<bool> Function(Uri url)? onForumRedirect;
}

typedef BrowserLinkHandler = Future<bool> Function(Uri url);
typedef BrowserAuthorizationHandler = Future<bool> Function(BrowserAuthorization request);

/// Bound by the root app, usable by state controllers without a BuildContext.
/// Handlers acknowledge opening immediately, not when the route is popped.
abstract final class BrowserLinks {
  static BrowserLinkHandler? openPage;
  static BrowserAuthorizationHandler? openAuthorization;
  static final _returns = StreamController<Uri>.broadcast();

  /// Internal navigation does not resume the Android activity. Consumers such
  /// as the wallet use this event to refresh when their page is closed.
  static Stream<Uri> get pageReturns => _returns.stream;
  static void didReturn(Uri url) => _returns.add(BrowserPolicy.savedUrl(url));

  static Future<bool> open(Uri url) async {
    if (url.scheme == 'http' || url.scheme == 'https') {
      if (!BrowserPolicy.allows(url)) return false;
      final handler = openPage;
      return handler != null ? handler(url) : external(url);
    }
    // App routes and local files have their own handlers. Never launch an
    // arbitrary script, file, intent, or plugin-supplied custom scheme here.
    if (!const ['mailto', 'tel', 'sms'].contains(url.scheme)) return false;
    return external(url);
  }

  static Future<bool> authorize(BrowserAuthorization request) async {
    if (!request.isCurrent() || request.url.scheme != 'https' || !BrowserPolicy.allows(request.url)) return false;
    final handler = openAuthorization;
    if (!request.preferSystem && handler != null) return handler(request);
    final opened = await external(request.url);
    if (opened) request.onSystemBrowserOpened?.call();
    return opened;
  }

  /// Explicit system-browser action, also used if an identity provider rejects
  /// embedded browsers. Does not modify or disguise the WebView user agent.
  static Future<bool> external(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
