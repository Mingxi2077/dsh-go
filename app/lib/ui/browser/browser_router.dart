import 'dart:async';

import 'package:flutter/material.dart';

import '../../browser/browser_links.dart';
import '../../state/hosts_state.dart';
import 'browser_page.dart';

/// Connects context-free URL requests to this app's root navigator. Requests
/// acknowledge the push immediately so account watchers keep running.
class AppBrowserRouter {
  AppBrowserRouter({required this.navigatorKey, required this.host, this.authorizationBuilder});

  final GlobalKey<NavigatorState> navigatorKey;
  final HostRef Function() host;
  final Widget Function(BrowserAuthorization request, VoidCallback onSystemBrowserOpened)? authorizationBuilder;
  final _authorizations = <Object, Route<void>>{};
  late final BrowserLinkHandler _pageHandler = _openPage;
  late final BrowserAuthorizationHandler _authHandler = _openAuthorization;
  BrowserLinkHandler? _previousPage;
  BrowserAuthorizationHandler? _previousAuth;
  bool _disposed = false;

  void attach() {
    _previousPage = BrowserLinks.openPage;
    _previousAuth = BrowserLinks.openAuthorization;
    BrowserLinks.openPage = _pageHandler;
    BrowserLinks.openAuthorization = _authHandler;
  }

  Future<bool> _openPage(Uri url) async {
    final navigator = navigatorKey.currentState;
    if (_disposed || navigator == null || !navigator.mounted) return false;
    unawaited(
      navigator.push(BrowserPage.route(host: host(), url: url)).then((_) {
        if (!_disposed) BrowserLinks.didReturn(url);
      }),
    );
    return true;
  }

  Future<bool> _openAuthorization(BrowserAuthorization request) async {
    final navigator = navigatorKey.currentState;
    if (_disposed || navigator == null || !navigator.mounted || !request.isCurrent()) return false;
    final builder = authorizationBuilder;
    // A shell without an authorization surface keeps the existing system flow.
    if (builder == null) {
      final opened = await BrowserLinks.external(request.url);
      if (opened) request.onSystemBrowserOpened?.call();
      return opened;
    }
    if (_authorizations.containsKey(request.id)) return true;
    var settled = false;
    late final Route<void> route;
    void finish() {
      settled = true;
      // Remove this exact page, even if another route now covers it. Never pop
      // a newer page or an unrelated dialog after a late authorization result.
      if (!_disposed && navigator.mounted && route.isActive) navigator.removeRoute(route);
    }

    void handoff() {
      finish();
      request.onSystemBrowserOpened?.call();
    }

    route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'browser-authorization'),
      builder: (_) => builder(request, handoff),
    );
    _authorizations[request.id] = route;
    unawaited(
      navigator.push(route).then((_) async {
        if (identical(_authorizations[request.id], route)) _authorizations.remove(request.id);
        if (!settled && request.isCurrent()) await request.cancel();
      }),
    );
    unawaited(request.completed.then((_) => finish(), onError: (Object _, StackTrace _) => finish()));
    return true;
  }

  void dispose() {
    _disposed = true;
    if (identical(BrowserLinks.openPage, _pageHandler)) BrowserLinks.openPage = _previousPage;
    if (identical(BrowserLinks.openAuthorization, _authHandler)) BrowserLinks.openAuthorization = _previousAuth;
    _authorizations.clear();
  }
}
