import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/hosts_state.dart';
import 'browser_policy.dart';
import 'browser_workspace.dart';

/// A way back to the quoted page in its original host/conversation. In memory
/// only; it carries no extracted text, account URL or persisted screenshot.
class BrowserReturnItem {
  const BrowserReturnItem({
    required this.host,
    required this.scope,
    required this.tabId,
    required this.url,
    required this.title,
    this.preview,
  });
  final HostRef host;
  final BrowserScope scope;
  final String tabId;
  final Uri url;
  final String title;
  final Uint8List? preview;
}

class BrowserReturnState {
  const BrowserReturnState([this.items = const {}]);
  final Map<String, BrowserReturnItem> items;
  List<BrowserReturnItem> itemsFor(BrowserScope scope) =>
      List.unmodifiable(items.values.where((item) => item.scope == scope).toList().reversed);
  BrowserReturnItem? itemFor(BrowserScope scope, {String? tabId}) =>
      tabId == null ? itemsFor(scope).firstOrNull : (items[tabId]?.scope == scope ? items[tabId] : null);
}

final browserReturnProvider = NotifierProvider<BrowserReturnController, BrowserReturnState>(
  BrowserReturnController.new,
);

class BrowserReturnController extends Notifier<BrowserReturnState> {
  static const maxPreviewBytes = 512 * 1024;
  static const maxTotalPreviewBytes = 4 * 1024 * 1024;

  @override
  BrowserReturnState build() {
    ref.listen(browserWorkspaceProvider, (_, next) {
      if (!next.loaded || state.items.isEmpty) return;
      final keep = <String, BrowserReturnItem>{};
      for (final entry in state.items.entries) {
        if (next.tabs.any((tab) => tab.id == entry.value.tabId && tab.scope == entry.value.scope)) {
          keep[entry.key] = entry.value;
        }
      }
      if (keep.length != state.items.length) state = BrowserReturnState(Map.unmodifiable(keep));
    });
    return const BrowserReturnState();
  }

  bool remember({
    required HostRef host,
    required String? sessionId,
    required String tabId,
    required Uri url,
    required String title,
    Uint8List? preview,
  }) {
    final scope = BrowserScope(hostKey: '${host.kind.name}:${host.id}', sessionId: sessionId);
    final workspace = ref.read(browserWorkspaceProvider);
    if (!workspace.loaded ||
        !BrowserPolicy.allows(url) ||
        !workspace.tabs.any((tab) => tab.id == tabId && tab.scope == scope && tab.url == url)) {
      return false;
    }
    // Check the PNG signature, and bound the aggregate retained bytes to 4MiB.
    final png =
        preview != null &&
        preview.length >= 8 &&
        preview.length <= maxPreviewBytes &&
        preview[0] == 137 &&
        preview[1] == 80 &&
        preview[2] == 78 &&
        preview[3] == 71 &&
        preview[4] == 13 &&
        preview[5] == 10 &&
        preview[6] == 26 &&
        preview[7] == 10;
    final items = {...state.items}..remove(tabId);
    final retainedBytes = items.values.fold<int>(0, (sum, item) => sum + (item.preview?.length ?? 0));
    // Bound screenshots, not the user's tags. Workspace bounds the tab count.
    items[tabId] = BrowserReturnItem(
      host: host,
      scope: scope,
      tabId: tabId,
      url: url,
      title: cleanBrowserTitle(title),
      preview: png && retainedBytes + preview.length <= maxTotalPreviewBytes ? Uint8List.fromList(preview) : null,
    );
    state = BrowserReturnState(Map.unmodifiable(items));
    return true;
  }

  void dismiss(BrowserScope scope, {String? tabId}) {
    final items = {...state.items}..removeWhere((id, item) => item.scope == scope && (tabId == null || id == tabId));
    if (items.length != state.items.length) state = BrowserReturnState(Map.unmodifiable(items));
  }
}
