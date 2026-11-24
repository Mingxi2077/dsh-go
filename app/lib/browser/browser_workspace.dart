import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/ssh/ssh_link.dart' show SshWebPreview;
import '../state/draft_store.dart';
import '../state/web_quote.dart';

import 'browser_models.dart';
import 'browser_navigation.dart';
import 'browser_policy.dart';
export 'browser_models.dart';

abstract interface class BrowserStorage {
  Future<String?> read();
  Future<void> write(String value);
}

class PreferencesBrowserStorage implements BrowserStorage {
  static const key = 'browser_workspace_v1';
  @override
  Future<String?> read() async => (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, value)) throw StateError('storage_failed');
  }
}

final browserStorageProvider = Provider<BrowserStorage>((ref) => PreferencesBrowserStorage());
final browserWorkspaceProvider = NotifierProvider<BrowserWorkspaceController, BrowserWorkspaceState>(
  BrowserWorkspaceController.new,
);

class BrowserWorkspaceController extends Notifier<BrowserWorkspaceState> {
  static const maxTabsPerScope = 20;
  static const maxTabs = 80;
  late Future<void> _ready;
  Future<void> _writes = Future.value();
  final _deletedScopes = <BrowserScope>{};
  final _webPreviews = <String, SshWebPreview>{};
  late BrowserNavigation _navigation;
  Future<void> get ready => _ready;

  @override
  BrowserWorkspaceState build() {
    final navigation = _navigation = BrowserNavigation.instance;
    ref.onDispose(() {
      navigation.release(this);
      for (final preview in _webPreviews.values) {
        unawaited(preview.close());
      }
    });
    final storage = ref.read(browserStorageProvider);
    _ready = Future<void>.microtask(() => _restore(storage));
    return const BrowserWorkspaceState();
  }

  Future<void> _restore(BrowserStorage storage) async {
    final tabs = <BrowserTab>[];
    final active = <String, String>{};
    var failed = false;
    try {
      final raw = await storage.read();
      if (raw != null) {
        if (raw.length > 1000000) throw const FormatException('oversized_workspace');
        final json = jsonDecode(raw);
        if (json is! Map || ![1, 2].contains(json['v']) || json['tabs'] is! List) {
          throw const FormatException('invalid_workspace');
        }
        for (final value in (json['tabs'] as List).take(maxTabs * 2)) {
          final tab = BrowserTab.fromJson(value);
          if (tab == null ||
              _deletedScopes.contains(tab.scope) ||
              tabs.any((t) => t.id == tab.id) ||
              tabs.where((t) => t.scope == tab.scope).length >= maxTabsPerScope) {
            continue;
          }
          tabs.add(tab);
          if (tabs.length >= maxTabs) break;
        }
        final ids = json['active'];
        if (ids is Map) {
          for (final tab in tabs) {
            if (ids[tab.scope.key] == tab.id) active[tab.scope.key] = tab.id;
          }
        }
      }
    } on Object {
      failed = true;
    }
    if (!ref.mounted) return;
    _navigation.synchronize(this, tabs);
    state = BrowserWorkspaceState(
      loaded: true,
      persistenceFailed: failed,
      tabs: List.unmodifiable(tabs),
      activeIds: Map.unmodifiable(active),
    );
  }

  Future<BrowserTab> open(BrowserScope scope, Uri url) async {
    if (!BrowserPolicy.allows(url)) throw const FormatException('blocked_url');
    return _open(scope, url);
  }

  Future<BrowserTab> openHome(BrowserScope scope) => _open(scope, null);

  Future<BrowserTab> openWebPreview(BrowserScope scope, SshWebPreview preview) =>
      _open(scope, preview.uri, webPreview: preview);

  Future<BrowserTab> showHome(BrowserScope scope) async {
    await ready;
    if (!ref.mounted) throw StateError('disposed');
    if (_deletedScopes.contains(scope)) throw StateError('scope_deleted');
    final home = state.tabsFor(scope).where((tab) => tab.isHome).firstOrNull;
    if (home == null) return openHome(scope);
    await activate(home.id);
    return home;
  }

  Future<BrowserTab> _open(BrowserScope scope, Uri? url, {SshWebPreview? webPreview}) async {
    await ready;
    if (!ref.mounted) throw StateError('disposed');
    if (_deletedScopes.contains(scope)) throw StateError('scope_deleted');
    if (state.tabs.length >= maxTabs || state.tabsFor(scope).length >= maxTabsPerScope) throw StateError('tab_limit');
    final id = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final tab = BrowserTab(
      id: id,
      scope: scope,
      url: url,
      title: '',
      updatedAt: DateTime.now(),
      webPreview: webPreview,
    );
    if (webPreview != null) {
      _webPreviews[id] = webPreview;
      unawaited(
        webPreview.done.then((_) async {
          if (ref.mounted && _webPreviews.containsKey(id)) await close(id);
        }),
      );
    }
    _set([...state.tabs, tab], {...state.activeIds, scope.key: id});
    if (webPreview == null) await flush();
    return tab;
  }

  Future<void> activate(String id) async {
    await ready;
    if (!ref.mounted) return;
    final tab = state.tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return;
    _set(state.tabs, {...state.activeIds, tab.scope.key: id});
    await flush();
  }

  Future<void> updatePage(String id, {Uri? url, String? title}) async {
    await ready;
    if (!ref.mounted) return;
    final current = state.tabs.where((tab) => tab.id == id).firstOrNull;
    if (current == null || (url != null && !current.allows(url))) return;
    _set([
      for (final tab in state.tabs)
        // A late WebView callback must never turn Home back into a page.
        if (tab.id == id && !tab.isHome)
          tab.copyWith(url: url, title: title == null ? null : cleanBrowserTitle(title))
        else
          tab,
    ], state.activeIds);
    if (current.webPreview == null) await flush();
  }

  /// Navigating a native start page uses its existing tab, not another slot.
  Future<void> navigate(String id, Uri url) async {
    if (!BrowserPolicy.allows(url)) throw const FormatException('blocked_url');
    await ready;
    if (!ref.mounted) return;
    final current = state.tabs.where((tab) => tab.id == id).firstOrNull;
    if (current == null || current.webPreview != null) return;
    if (current.isHome) _navigation.reset(id);
    _set([
      for (final tab in state.tabs)
        if (tab.id == id)
          tab.copyWith(url: url, title: '', homeBack: tab.isHome || tab.homeBack, clearForward: true)
        else
          tab,
    ], state.activeIds);
    await flush();
  }

  /// UI calls this only after native back history is exhausted. Remove the
  /// WebViewWidget, then dispose its controller to save the forward history.
  Future<void> returnHome(String id) async {
    await ready;
    if (!ref.mounted) return;
    _set([
      for (final tab in state.tabs)
        if (tab.id == id && !tab.isHome && tab.homeBack)
          BrowserTab(
            id: tab.id,
            scope: tab.scope,
            url: null,
            title: '',
            updatedAt: DateTime.now(),
            homeBack: true,
            forwardUrl: tab.url,
          )
        else
          tab,
    ], state.activeIds);
    await flush();
  }

  /// Recreate the ordinary controller using this URL and configureNavigation.
  /// Unlike navigate(Home, url), this preserves the native forward branch.
  Future<void> resumeFromHome(String id) async {
    await ready;
    if (!ref.mounted) return;
    _set([
      for (final tab in state.tabs)
        if (tab.id == id && tab.isHome && tab.forwardUrl != null && BrowserPolicy.allows(tab.forwardUrl!))
          tab.copyWith(url: tab.forwardUrl, title: '', homeBack: true, clearForward: true)
        else
          tab,
    ], state.activeIds);
    await flush();
  }

  Future<BrowserTab?> close(String id) async {
    await ready;
    if (!ref.mounted) return null;
    final tab = state.tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab == null) return null;
    final remaining = state.tabs.where((t) => t.id != id).toList();
    final active = {...state.activeIds};
    if (active[tab.scope.key] == id) {
      final sibling = remaining.where((t) => t.scope == tab.scope).lastOrNull;
      if (sibling == null) {
        active.remove(tab.scope.key);
      } else {
        active[tab.scope.key] = sibling.id;
      }
    }
    _set(remaining, active);
    await flush();
    return tab.webPreview == null ? tab : null;
  }

  Future<void> restoreTab(BrowserTab tab) async {
    if (tab.url != null && !BrowserPolicy.allows(tab.url!)) throw const FormatException('blocked_url');
    await ready;
    if (!ref.mounted) return;
    if (_deletedScopes.contains(tab.scope)) throw StateError('scope_deleted');
    if (state.tabs.any((t) => t.id == tab.id)) return;
    if (state.tabs.length >= maxTabs || state.tabsFor(tab.scope).length >= maxTabsPerScope) {
      throw StateError('tab_limit');
    }
    _set([...state.tabs, tab], {...state.activeIds, tab.scope.key: tab.id});
    await flush();
  }

  /// After [ready], give the new chat's tabs to the session just created for it.
  Future<void> assignNewChatTabs(String hostKey, String sessionId) async {
    final source = BrowserScope(hostKey: hostKey);
    final target = BrowserScope(hostKey: hostKey, sessionId: sessionId);
    if (_deletedScopes.contains(target) || state.tabs.any((tab) => tab.scope == target)) return;
    if (!state.tabs.any((tab) => tab.scope == source)) return;
    final active = {...state.activeIds};
    final selected = active.remove(source.key);
    if (selected != null) active[target.key] = selected;
    _set([
      for (final tab in state.tabs)
        if (tab.scope == source) tab.copyWith(scope: target) else tab,
    ], active);
    await flush();
  }

  Future<void> closeAll(BrowserScope scope) async {
    await ready;
    if (!ref.mounted) return;
    _set(state.tabs.where((t) => t.scope != scope).toList(), {...state.activeIds}..remove(scope.key));
    await flush();
  }

  /// Called after the Host confirms deletion; late undo/open cannot revive it.
  Future<void> clear(BrowserScope scope) async {
    _deletedScopes.add(scope);
    await closeAll(scope);
  }

  void _set(List<BrowserTab> tabs, Map<String, String> active) {
    final ids = tabs.map((tab) => tab.id).toSet();
    for (final id in _webPreviews.keys.toList()) {
      if (!ids.contains(id)) unawaited(_webPreviews.remove(id)!.close());
    }
    _navigation.synchronize(this, tabs.where((tab) => tab.webPreview == null));
    state = BrowserWorkspaceState(
      loaded: true,
      persistenceFailed: state.persistenceFailed,
      tabs: List.unmodifiable(tabs),
      activeIds: Map.unmodifiable(active),
    );
  }

  Future<void> flush() async {
    await ready;
    if (!ref.mounted) return;
    final storage = ref.read(browserStorageProvider);
    final value = jsonEncode({
      'v': 2,
      'tabs': state.tabs.where((tab) => tab.webPreview == null).map((tab) => tab.toJson()).toList(),
      'active': Map.of(state.activeIds)..removeWhere((_, id) => _webPreviews.containsKey(id)),
    });
    // Serialize writes so an older completion cannot overwrite a closed tab.
    _writes = _writes.then((_) async {
      var failed = false;
      try {
        await storage.write(value);
      } on Object {
        failed = true;
      }
      if (ref.mounted && state.persistenceFailed != failed) {
        state = BrowserWorkspaceState(
          loaded: state.loaded,
          persistenceFailed: failed,
          tabs: state.tabs,
          activeIds: state.activeIds,
        );
      }
    });
    await _writes;
  }
}

final browserReferenceInboxProvider = NotifierProvider<BrowserReferenceInbox, List<BrowserReference>>(
  BrowserReferenceInbox.new,
);

class BrowserReferenceInbox extends Notifier<List<BrowserReference>> {
  @override
  List<BrowserReference> build() => const [];

  void add(BrowserReference reference) {
    final key = draftStorageKey(hostKey: reference.scope.hostKey, sessionId: reference.scope.sessionId);
    final savedCount = ref.read(draftStoreProvider).drafts[key]?.webQuotes.length ?? 0;
    final waiting = state.where((r) => r.scope == reference.scope).length;
    if (state.length >= DraftWebQuote.limit || savedCount + waiting >= DraftWebQuote.limit) {
      throw StateError('reference_limit');
    }
    state = List.unmodifiable([...state, reference]);
  }

  BrowserReference? take(BrowserScope scope) {
    final i = state.indexWhere((reference) => reference.scope == scope);
    if (i < 0) return null;
    final reference = state[i];
    state = List.unmodifiable([...state]..removeAt(i));
    return reference;
  }

  void discard(BrowserScope scope) {
    state = List.unmodifiable(state.where((reference) => reference.scope != scope));
  }
}
