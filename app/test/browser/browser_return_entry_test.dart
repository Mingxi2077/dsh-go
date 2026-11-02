import 'dart:async';

import 'package:dsh_app/browser/browser_return.dart';
import 'package:dsh_app/browser/browser_workspace.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/browser/browser_entry.dart';
import 'package:dsh_app/ui/browser/browser_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage implements BrowserStorage {
  Completer<void>? gate;
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async => gate?.future;
}

void main() {
  for (final switchSession in [false, true]) {
    testWidgets(
      'return tag cannot reopen after ${switchSession ? 'session switch' : 'another route'} during activation',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final storage = _Storage();
        final container = ProviderContainer(overrides: [browserStorageProvider.overrideWithValue(storage)]);
        addTearDown(container.dispose);
        late BuildContext origin;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  origin = context;
                  return const Scaffold(body: Text('conversation'));
                },
              ),
            ),
          ),
        );
        container.read(currentSessionProvider.notifier).select('a');
        const scope = BrowserScope(hostKey: 'local:local', sessionId: 'a');
        final workspace = container.read(browserWorkspaceProvider.notifier);
        final url = Uri.parse('https://example.com/');
        final opening = workspace.open(scope, url);
        await tester.pump();
        final tab = await opening;
        expect(
          container
              .read(browserReturnProvider.notifier)
              .remember(host: HostRef.local, sessionId: 'a', tabId: tab.id, url: url, title: 'Example'),
          isTrue,
        );
        final item = container.read(browserReturnProvider).itemFor(scope)!;
        storage.gate = Completer<void>();
        final pending = reopenBrowserReturn(origin, item);
        await tester.pump();
        if (switchSession) {
          container.read(currentSessionProvider.notifier).select('b');
        } else {
          unawaited(
            Navigator.of(origin).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('settings')))),
          );
        }
        storage.gate!.complete();
        await tester.pumpAndSettle();
        expect(await pending, isFalse);
        expect(find.byType(BrowserPage), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
