import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/attachments.dart';
import '../state/draft_store.dart';
import '../state/hosts_state.dart';
import '../state/sessions_state.dart';
import 'browser_downloads.dart';

/// Explicit attachment inserts; the visible composer updates only its tray.
final browserDownloadDraftUpdatesProvider = NotifierProvider<BrowserDownloadDraftUpdates, Map<String, int>>(
  BrowserDownloadDraftUpdates.new,
);

class BrowserDownloadDraftUpdates extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};
  void signal(String key) => state = {key: (state[key] ?? 0) + 1};
}

Future<bool> addBrowserDownloadToDraft(
  WidgetRef ref, {
  required HostRef host,
  required String? sessionId,
  required String downloadId,
}) async {
  final key = draftStorageKey(hostKey: '${host.kind.name}:${host.id}', sessionId: sessionId);
  bool current() =>
      ref.context.mounted &&
      ref.read(activeHostProvider) == host &&
      ref.read(currentSessionProvider) == sessionId &&
      ref.read(draftStoreProvider).loaded &&
      !ref.read(draftStoreProvider.notifier).isForgotten(key);
  if (!current()) return false;
  final attachment = await ref.read(browserDownloadsProvider.notifier).readAttachment(downloadId);
  if (!current()) return false;
  final draft = ref.read(draftStoreProvider).drafts[key];
  final previous = draft?.attachments ?? const <DraftAttachment>[];
  if (previous.length >= maxAttachments ||
      previous.fold<int>(attachment.size, (n, a) => n + a.size) > 60 * 1024 * 1024) {
    throw PlatformException(code: 'too_large');
  }
  ref.read(draftStoreProvider.notifier).save(key, draft?.text ?? '', [
    ...previous,
    attachment,
  ], webQuotes: draft?.webQuotes ?? const []);
  if (!current()) return false;
  ref.read(browserDownloadDraftUpdatesProvider.notifier).signal(key);
  return true;
}
