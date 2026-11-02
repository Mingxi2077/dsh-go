// A quote picked in 网页 waits in the reference inbox for its own
// conversation: the same host and the same session (none: that host's
// 新对话). The chat screen takes it once that composer is showing and its
// saved drafts are in, and adds an independent reference card. Nothing is
// sent.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_workspace.dart';
import '../../state/draft_store.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import 'browser_entry.dart';

/// The scope of the composer on screen: the active host and conversation.
final activeBrowserScopeProvider = Provider<BrowserScope>(
  (ref) => browserScopeFor(ref.watch(activeHostProvider), ref.watch(currentSessionProvider)),
);

/// True while a quote for the composer on screen waits and the saved drafts
/// are in (taking it earlier would let the restored draft replace it).
final browserReferenceReadyProvider = Provider<bool>((ref) {
  if (!ref.watch(draftStoreProvider.select((s) => s.loaded))) return false;
  final scope = ref.watch(activeBrowserScopeProvider);
  return ref.watch(browserReferenceInboxProvider).any((reference) => reference.scope == scope);
});
