// Ways into 网页 (the session web workspace, docs/design/browser-workspace.md):
// 全部功能's entry, and an http(s) link tapped in a reply of an open
// conversation. DSH's authenticated web UI, `dshgo://`, and workspace files
// keep their own routes; public share/market links use the browser too.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../browser/browser_omnibox.dart';
import '../../browser/browser_page_controller.dart';
import '../../l10n/l10n.dart';
import '../../browser/browser_policy.dart';
import '../../browser/browser_workspace.dart';
import '../../browser/browser_return.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import 'browser_page.dart';

/// The workspace key of [host]: `kind:id`, as the backend expects.
String browserHostKey(HostRef host) => '${host.kind.name}:${host.id}';

/// The tabs and references of [sessionId] on [host] (null: its 新对话).
BrowserScope browserScopeFor(HostRef host, String? sessionId) =>
    BrowserScope(hostKey: browserHostKey(host), sessionId: sessionId);

/// Makes the live page of one tab; tests swap in a fake.
typedef BrowserPageFactory = BrowserPageController Function({
  required Uri initialUrl,
  required void Function(Uri url, String title) onPageChanged,
});

final browserPageFactoryProvider = Provider<BrowserPageFactory>(
  (ref) =>
      ({required initialUrl, required onPageChanged}) =>
          BrowserPageController(initialUrl: initialUrl, onPageChanged: onPageChanged),
);

/// Draws a live page; tests draw a box instead of a platform view.
typedef BrowserViewBuilder = Widget Function(BuildContext context, BrowserPageController page);

final browserViewBuilderProvider = Provider<BrowserViewBuilder>(
  (ref) =>
      (context, page) => WebViewWidget(controller: page.webView),
);

/// Hands a page's address to the system share sheet; tests record it.
typedef BrowserShare = Future<void> Function(Uri url, String title);

final browserShareProvider = Provider<BrowserShare>(
  (ref) =>
      (url, title) async =>
          SharePlus.instance.share(ShareParams(text: url.toString(), subject: title.isEmpty ? null : title)),
);

/// Opens an address in the system browser; tests record it.
typedef BrowserExternalOpen = Future<void> Function(Uri url);

final browserExternalOpenProvider = Provider<BrowserExternalOpen>(
  (ref) =>
      (url) async => launchUrl(url, mode: LaunchMode.externalApplication),
);

/// [engine]'s name in the app's language (必应 in Chinese).
String browserEngineName(BrowserSearchEngine engine, L10n l10n) =>
    engine == BrowserSearchEngine.bing ? l10n.browserEngineBing : engine.label;

/// Opens 网页 for [sessionId] on the active host, at [url] when given.
Future<void> openBrowser(BuildContext context, {String? sessionId, Uri? url}) {
  final host = ProviderScope.containerOf(context, listen: false).read(activeHostProvider);
  return Navigator.of(context).push(BrowserPage.route(host: host, sessionId: sessionId, url: url));
}

/// Reopen the exact tab, without treating its address as a new navigation.
/// A stale side tag cannot switch hosts or recreate a deleted conversation.
Future<bool> reopenBrowserReturn(BuildContext context, BrowserReturnItem item) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final origin = ModalRoute.of(context);
  bool current() =>
      context.mounted &&
      (origin?.isCurrent ?? false) &&
      container.read(activeHostProvider) == item.host &&
      container.read(currentSessionProvider) == item.scope.sessionId &&
      identical(container.read(browserReturnProvider).itemFor(item.scope, tabId: item.tabId), item) &&
      container.read(browserWorkspaceProvider).tabs.any((tab) => tab.id == item.tabId && tab.scope == item.scope);
  if (!current()) return false;
  await container.read(browserWorkspaceProvider.notifier).activate(item.tabId);
  if (!context.mounted || !current()) return false;
  unawaited(Navigator.of(context).push(BrowserPage.route(host: item.host, sessionId: item.scope.sessionId)));
  return true;
}

/// A public http(s) page opens in 网页 for [sessionId] on the active host.
/// Other schemes and local/private addresses are not handled here.
bool openReplyBrowserLink(BuildContext context, String url, {String? sessionId}) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) return false;
  if (!BrowserPolicy.allows(uri)) return false;
  try {
    ProviderScope.containerOf(context, listen: false);
  } on StateError {
    // No provider scope above this text: nothing to open it in.
    return false;
  }
  unawaited(openBrowser(context, sessionId: sessionId, url: uri));
  return true;
}
