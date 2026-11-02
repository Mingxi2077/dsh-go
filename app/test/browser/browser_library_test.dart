import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/browser/browser_library.dart';
import 'package:dsh_app/browser/browser_workspace.dart' show BrowserStorage;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage implements BrowserStorage {
  String? value;
  Future<String?>? readWait;
  Completer<void>? writeWait;
  bool fail = false;
  final writes = <String>[];
  @override
  Future<String?> read() async => readWait == null ? value : await readWait;
  @override
  Future<void> write(String raw) async {
    final wait = writeWait;
    writeWait = null;
    if (wait != null) await wait.future;
    if (fail) throw StateError('storage_failed');
    value = raw;
    writes.add(raw);
  }
}

Map<String, Object?> _item(String id, String url, {String title = 'Page', int at = 1000}) => {
  'id': id,
  'url': url,
  'title': title,
  'at': at,
};
String _data({
  List<Object?> bookmarks = const [],
  List<Object?> history = const [],
  String engine = 'bing',
  int zoom = 100,
}) => jsonEncode({'v': 1, 'bookmarks': bookmarks, 'history': history, 'engine': engine, 'textZoom': zoom});

void main() {
  late _Storage storage;
  late ProviderContainer c;
  BrowserLibraryController controller() => c.read(browserLibraryProvider.notifier);
  BrowserLibraryState state() => c.read(browserLibraryProvider);
  setUp(() {
    storage = _Storage();
    c = ProviderContainer(overrides: [browserLibraryStorageProvider.overrideWithValue(storage)]);
  });
  tearDown(() => c.dispose());

  test('explicit bookmark preserves selected URL, edits its identity, deletes without resurrection', () async {
    final original = Uri.parse('https://example.com/docs?version=2#install');
    final first = await controller().saveBookmark(original, title: ' Install ');
    expect(state().bookmarkFor(original)?.title, 'Install');
    final edited = await controller().saveBookmark(
      Uri.parse('https://example.com/next?q=2'),
      title: 'Next',
      id: first.id,
    );
    expect(edited.id, first.id);
    expect(state().bookmarks, hasLength(1));
    expect(state().bookmarkFor(original), isNull);
    expect(jsonDecode(storage.value!)['bookmarks'][0]['url'], 'https://example.com/next?q=2');
    await controller().removeBookmark(first.id);
    await expectLater(controller().saveBookmark(original, id: first.id), throwsStateError);
    expect(state().bookmarks, isEmpty);
  });

  test('bookmark duplicates canonical roots and editing onto another bookmark merge predictably', () async {
    final first = await controller().saveBookmark(Uri.parse('https://example.com'), title: 'One');
    final same = await controller().saveBookmark(Uri.parse('https://example.com/'), title: 'Renamed');
    expect(first.id, same.id);
    final other = await controller().saveBookmark(Uri.parse('https://github.com/'));
    await controller().saveBookmark(other.url, id: first.id);
    expect(state().bookmarks.single.id, first.id);
    for (final address in ['file:///tmp/private', 'http://localhost/', 'javascript:alert(1)']) {
      await expectLater(controller().saveBookmark(Uri.parse(address)), throwsFormatException);
    }
  });

  test('successful history is deduplicated, bounded and safe to restore without carrying arbitrary tokens', () async {
    storage.value = _data(
      history: List.generate(
        BrowserLibraryController.maxHistory,
        (i) => _item('h$i', 'https://example.com/$i', at: i + 1),
      ),
    );
    await controller().recordVisit(Uri.parse('https://example.com/new?token=SECRET#SECRET'), 'New');
    expect(state().history, hasLength(BrowserLibraryController.maxHistory));
    expect(state().history.first.url.toString(), 'https://example.com/new');
    expect(state().history.any((h) => h.id == 'h0'), isFalse);
    final id = state().history.first.id;
    await controller().recordVisit(Uri.parse('https://example.com/new?other=private'), 'New title');
    expect(state().history.first.id, id);
    expect(state().history.where((h) => h.id == id), hasLength(1));
    await controller().recordVisit(BrowserSearchEngine.baidu.search('怎么打开网页'), '搜索');
    expect(state().history.first.url.queryParameters['wd'], '怎么打开网页');
    expect(storage.value, isNot(contains('SECRET')));
    await controller().removeHistory(id);
    expect(state().history.any((h) => h.id == id), isFalse);
  });

  test('bookmark, engine and text size survive restart; history clear leaves them intact', () async {
    await controller().saveBookmark(Uri.parse('https://example.com/docs?q=1'), title: 'Docs');
    await controller().setEngine(BrowserSearchEngine.duckduckgo);
    await controller().setTextZoom(125);
    await controller().recordVisit(Uri.parse('https://github.com/'), 'GitHub');
    await controller().clearHistory();
    final next = ProviderContainer(overrides: [browserLibraryStorageProvider.overrideWithValue(storage)]);
    addTearDown(next.dispose);
    await next.read(browserLibraryProvider.notifier).ready;
    final restored = next.read(browserLibraryProvider);
    expect(restored.bookmarks.single.url.queryParameters['q'], '1');
    expect(restored.engine, BrowserSearchEngine.duckduckgo);
    expect(restored.textZoom, 125);
    expect(restored.history, isEmpty);
  });

  test('suggestions match local titles and addresses, prefer bookmarks and do not duplicate targets', () async {
    await controller().recordVisit(Uri.parse('https://example.com/docs'), '使用手册');
    await controller().recordVisit(Uri.parse('https://github.com/'), 'GitHub');
    await controller().saveBookmark(Uri.parse('https://example.com/docs'), title: '使用手册收藏');
    expect(state().suggestions('手册').single.bookmarked, isTrue);
    expect(state().suggestions('GITHUB').single.url.host, 'github.com');
    expect(state().suggestions('not present'), isEmpty);
    expect(state().suggestions('', limit: 1), hasLength(1));
    expect(state().suggestions('', limit: 0), isEmpty);
  });

  test('mutations wait for restore and retain saved bookmarks', () async {
    final delayed = Completer<String?>();
    storage.readWait = delayed.future;
    final adding = controller().saveBookmark(Uri.parse('https://github.com/'), title: 'New');
    expect(state().loaded, isFalse);
    delayed.complete(_data(bookmarks: [_item('old', 'https://example.com/docs')]));
    await adding;
    expect(state().bookmarks.map((b) => b.id), contains('old'));
    expect(state().bookmarks, hasLength(2));
  });

  test('a blocked older write cannot resurrect cleared history on disk', () async {
    await controller().ready;
    final pendingWrite = Completer<void>();
    storage.writeWait = pendingWrite;
    final recording = controller().recordVisit(Uri.parse('https://example.com/'), 'Visit');
    await Future<void>.delayed(Duration.zero);
    final clearing = controller().clearHistory();
    await Future<void>.delayed(Duration.zero);
    expect(state().history, isEmpty);
    pendingWrite.complete();
    await Future.wait([recording, clearing]);
    expect(jsonDecode(storage.value!)['history'], isEmpty);
  });

  test('corrupt records do not hide good records; settings fall back and failed writes can recover', () async {
    storage.value = _data(
      bookmarks: [
        {'id': 'broken'},
        _item('local', 'http://127.0.0.1/'),
        _item('time', 'https://example.com/time', at: 9000000000000000000),
        _item('good', 'https://example.com/'),
      ],
      engine: 'missing',
      zoom: 900,
    );
    await controller().ready;
    expect(state().bookmarks.single.id, 'good');
    expect(state().engine, BrowserSearchEngine.bing);
    expect(state().textZoom, 200);
    storage.fail = true;
    await controller().setTextZoom(100);
    expect(state().persistenceFailed, isTrue);
    storage.fail = false;
    await controller().flush();
    expect(state().persistenceFailed, isFalse);
    expect(jsonDecode(storage.value!)['textZoom'], 100);
  });

  test('full bookmarks reject a new item but allow editing existing ones', () async {
    storage.value = _data(
      bookmarks: List.generate(BrowserLibraryController.maxBookmarks, (i) => _item('b$i', 'https://example.com/$i')),
    );
    await expectLater(controller().saveBookmark(Uri.parse('https://example.com/new')), throwsStateError);
    await controller().saveBookmark(Uri.parse('https://example.com/changed'), id: 'b0', title: 'Changed');
    expect(state().bookmarks, hasLength(BrowserLibraryController.maxBookmarks));
    expect(state().bookmarks.first.title, 'Changed');
  });
}
