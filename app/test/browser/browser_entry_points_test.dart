import 'package:dsh_app/browser/browser_links.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/balance_state.dart' show deepSeekTopUpUrl;
import 'package:dsh_app/state/star_prompt.dart' show starLinkOpenerProvider, starProjectPage;
import 'package:dsh_app/ui/chat/balance_widgets.dart' show openTopUp;
import 'package:dsh_app/ui/engine_settings/schema_documentation.dart';
import 'package:dsh_app/ui/forum/forum_post_body.dart' show openForumLink;
import 'package:dsh_app/ui/plugins/native/native_taps.dart' show openConfirmedLink;
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget body) => MaterialApp(
  theme: buildLightTheme(),
  home: Scaffold(body: body),
);

Future<BuildContext> _origin(WidgetTester tester) async {
  late BuildContext origin;
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) {
          origin = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return origin;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final opened = <Uri>[];
  final systemCalls = <MethodCall>[];
  BrowserLinkHandler? previous;
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');

  setUp(() {
    opened.clear();
    systemCalls.clear();
    previous = BrowserLinks.openPage;
    BrowserLinks.openPage = (url) async {
      opened.add(url);
      return true;
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (call) async {
      systemCalls.add(call);
      return false;
    });
  });

  tearDown(() {
    BrowserLinks.openPage = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, null);
    expect(systemCalls, isEmpty, reason: 'business page entry points must use the internal handler');
  });

  test('forum links preserve HTTP(S), query and fragment through the shared entry', () async {
    final urls = [
      Uri.parse('http://forum.example.com/t/topic/42?source=app#post-3'),
      Uri.parse('https://forum.example.com/t/topic/42?source=app#post-3'),
    ];
    for (final url in urls) {
      await openForumLink(url);
    }
    await openForumLink(Uri.parse('dshgo://forum/auth?payload=example'));
    await openForumLink(Uri.parse('file:///private.txt'));
    expect(opened, urls);
  });

  test('top-up opens the platform page without a BuildContext', () async {
    await openTopUp();
    expect(opened, [Uri.parse(deepSeekTopUpUrl)]);
  });

  test('the default star provider uses the shared entry and reports rejected opening', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final open = container.read(starLinkOpenerProvider);
    expect(await open(starProjectPage), isTrue);
    expect(opened, [starProjectPage]);
    BrowserLinks.openPage = (_) async => false;
    expect(await open(starProjectPage), isFalse);
  });

  testWidgets('plugin links require confirmation and cancellation never opens a page', (tester) async {
    final context = await _origin(tester);
    final url = Uri.parse('https://example.com/plugin?from=action#help');
    final confirmed = openConfirmedLink(context, url);
    await tester.pumpAndSettle();
    expect(find.text(appL10n.pluginsOpenBrowserHost(url.host)), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, appL10n.commonOpen));
    await tester.pumpAndSettle();
    await confirmed;
    expect(opened, [url]);

    final cancelled = openConfirmedLink(context, url);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, appL10n.commonCancel));
    await tester.pumpAndSettle();
    await cancelled;
    expect(opened, [url]);
  });

  testWidgets('plugin links check current ownership before and after confirmation', (tester) async {
    final context = await _origin(tester);
    final url = Uri.parse('https://example.com/plugin');
    var current = false;
    await openConfirmedLink(context, url, stillCurrent: () => current);
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(opened, isEmpty);

    current = true;
    final pending = openConfirmedLink(context, url, stillCurrent: () => current);
    await tester.pumpAndSettle();
    current = false;
    await tester.tap(find.widgetWithText(FilledButton, appL10n.commonOpen));
    await tester.pumpAndSettle();
    await pending;
    expect(opened, isEmpty);
  });

  testWidgets('confirmation cannot open a page after its originating widget is removed', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    late BuildContext origin;
    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, show, _) => show
              ? Builder(
                  builder: (context) {
                    origin = context;
                    return const SizedBox.shrink();
                  },
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
    final pending = openConfirmedLink(origin, Uri.parse('https://example.com/plugin'));
    await tester.pumpAndSettle();
    visible.value = false;
    await tester.pump();
    expect(origin.mounted, isFalse);
    await tester.tap(find.widgetWithText(FilledButton, appL10n.commonOpen));
    await tester.pumpAndSettle();
    await pending;
    expect(opened, isEmpty);
  });

  testWidgets('a scoped opener replaces the default only after confirmation', (tester) async {
    final context = await _origin(tester);
    final scoped = <Uri>[];
    final url = Uri.parse('https://example.com/from-reply');
    final pending = openConfirmedLink(
      context,
      url,
      opener: (uri) async {
        scoped.add(uri);
      },
    );
    await tester.pumpAndSettle();
    expect(scoped, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, appL10n.commonOpen));
    await tester.pumpAndSettle();
    await pending;
    expect(scoped, [url]);
    expect(opened, isEmpty);
  });

  testWidgets('schema documentation uses its default shared browser launcher on tap', (tester) async {
    const url = 'https://example.com/docs?language=en#setup';
    await tester.pumpWidget(
      _app(
        const SchemaDocumentationSheet(
          title: 'Plugin',
          entries: [SchemaDocumentationEntry(r'$.source', null, null, url)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, url));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(url)]);
    expect(find.byType(SchemaDocumentationSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
