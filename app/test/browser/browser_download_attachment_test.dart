import 'dart:async';

import 'package:dsh_app/browser/browser_download_attachment.dart';
import 'package:dsh_app/browser/browser_downloads.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

class _Files extends BrowserDownloadPlatform {
  Completer<Uint8List>? gate;
  @override
  Stream<Object?> get changes => const Stream.empty();
  @override
  Future<T?> callNative<T>(String method, [Map<String, Object?>? args]) async {
    final Object? result = switch (method) {
      'snapshot' => {
        'items': [
          {'id': 'one', 'filename': 'notes.txt', 'status': 'completed', 'received': 3},
        ],
      },
      'readAttachment' => await (gate?.future ?? Future.value(Uint8List.fromList([65, 66, 67]))),
      _ => null,
    };
    return result as T?;
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final change in ['none', 'host', 'session', 'delete']) {
    testWidgets('download attachment preserves typed prompt and refuses late $change owner changes', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final files = _Files();
      final harness = ChatHarness();
      late WidgetRef widgetRef;
      await tester.pumpWidget(
        testApp(
          Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              return const ChatScreen();
            },
          ),
          overrides: [...harness.overrides, browserDownloadPlatformProvider.overrideWithValue(files)],
        ),
      );
      await pumpFrames(tester, 3);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      final sessionId = container.read(currentSessionProvider);
      final key = draftStorageKey(hostKey: 'local:local', sessionId: sessionId);
      container.read(browserDownloadsProvider);
      await pumpFrames(tester, 2);
      await tester.enterText(find.byType(TextField), '请解释文件');
      files.gate = Completer<Uint8List>();
      final result = addBrowserDownloadToDraft(widgetRef, host: HostRef.local, sessionId: sessionId, downloadId: 'one');
      await tester.pump();
      if (change == 'host') container.read(activeHostProvider.notifier).select(const HostRef.ssh('other'));
      if (change == 'session') container.read(currentSessionProvider.notifier).select('other');
      if (change == 'delete') container.read(draftStoreProvider.notifier).forget(key);
      files.gate!.complete(Uint8List.fromList([65, 66, 67]));
      await pumpFrames(tester, 3);
      expect(await result, change == 'none');
      final draft = container.read(draftStoreProvider).drafts[key];
      if (change == 'none') {
        expect(draft!.text, '请解释文件');
        expect(draft.attachments.single.name, 'notes.txt');
        expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '请解释文件');
        expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items.single.name, 'notes.txt');
      } else {
        expect(draft?.attachments ?? <DraftAttachment>[], isEmpty);
      }
      expect(harness.controllers.values.expand((chat) => chat.sent), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
