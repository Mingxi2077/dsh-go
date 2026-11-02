// 网页: one conversation's browser (docs/design/browser-daily-use.md). Top:
// close · address (web pages only) · tabs. Middle: the open tab — a native
// 首页 whose middle box is the one address field, or its live page. Bottom:
// back · forward · home · quote · more, hidden while typing. Up to three tabs
// keep their live page (BrowserPagePool); only the open one is in the tree,
// so switching back shows a page as it was. 标签页 is a card overview over
// the whole page (docs/design/browser-motion-refresh.md): the page's
// in-memory snapshot flies into its card while the live WebView stays
// offstage, untransformed.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../browser/browser_conversation_activity.dart';
import '../../browser/browser_downloads.dart';
import '../../browser/browser_download_helpers.dart';
import '../../browser/browser_library.dart';
import '../../browser/browser_omnibox.dart';
import '../../browser/browser_page_controller.dart';
import '../../browser/browser_policy.dart';
import '../../browser/browser_return.dart';
import '../../browser/browser_selection.dart';
import '../../browser/browser_site_icons.dart';
import '../../browser/browser_workspace.dart';
import '../../l10n/l10n.dart';
import '../../performance/refresh_rate.dart';
import '../../state/connection_state.dart' show hostNameProvider;
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../common/pressable.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/web_view_page.dart' show RendererGone, WebKeyboard;
import '../chat/widgets/whale_tail.dart';
import 'browser_chrome.dart';
import 'browser_conversation_button.dart';
import 'browser_download_sheet.dart';
import 'browser_downloads_page.dart';
import 'browser_entry.dart';
import 'browser_home.dart';
import 'browser_library_page.dart';
import 'browser_menu.dart';
import 'browser_page_pool.dart';
import 'browser_quote_sheet.dart';
import 'browser_site.dart';
import 'browser_suggestions.dart';
import 'browser_tabs_overview.dart';

class BrowserPage extends ConsumerStatefulWidget {
  const BrowserPage({super.key, required this.host, this.sessionId, this.initialUrl});

  /// Whose tabs and drafts: fixed for the page's life, whatever host is
  /// chosen while it is open.
  final HostRef host;

  /// The conversation (null: that host's 新对话).
  final String? sessionId;

  /// Opened in a tab when the page appears (a link from a reply).
  final Uri? initialUrl;

  static Route<void> route({required HostRef host, String? sessionId, Uri? url}) => MaterialPageRoute<void>(
    builder: (_) => BrowserPage(host: host, sessionId: sessionId, initialUrl: url),
  );

  static const bar = BrowserChrome.bar;
  static const edge = BrowserChrome.edge;

  @override
  ConsumerState<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends ConsumerState<BrowserPage> {
  late final BrowserScope _scope = browserScopeFor(widget.host, widget.sessionId);
  late final BrowserWorkspaceController _workspace = ref.read(browserWorkspaceProvider.notifier);
  late final BrowserLibraryController _library = ref.read(browserLibraryProvider.notifier);

  /// Live pages of up to three tabs, and each one's listener.
  final _pool = BrowserPagePool();
  final _listeners = <String, VoidCallback>{};

  /// Tabs whose renderer went away: 「网页已关闭 · 重新打开」 until reopened.
  final _gone = <String>{};

  /// What each live page last put in the history (its revision and address).
  final _recorded = <String, (int, Uri)>{};

  /// Each page's last error, to say 「不能在这里打开」 once per block.
  final _errors = <String, String?>{};

  bool _syncQueued = false;

  /// 标签页 is open over the page, and the page's rect it grew out of.
  bool _overview = false;
  Rect _overviewOrigin = Rect.zero;
  bool _openingOverview = false;
  bool _overviewRevealing = false;

  /// Bumped by every move off the visible page (and by opening the
  /// overview): a move still waiting for its snapshot runs only if no newer
  /// one came.
  int _moveGeneration = 0;
  final _overviewKey = GlobalKey<BrowserTabsOverviewState>();
  final _stackKey = GlobalKey();
  final _contentKey = GlobalKey();

  /// Each live page's favicon attempt: the document revision asked for and
  /// whether one was kept (released with the page in [_forget]).
  final _icons = <String, ({int revision, bool kept})>{};

  /// Last snapshot of each tab (in memory, this page only), oldest first.
  final _previews = <String, BrowserTabPreview>{};
  static const _maxPreviews = 20;

  bool _editing = false;
  bool _newTab = false;
  bool _invalid = false;
  final _address = TextEditingController();
  final _addressFocus = FocusNode();

  bool _dark = false;
  double _systemScale = 1;

  final _keyboard = WebKeyboard();

  /// 首页: this edit's keyboard has been up; and the generation of pending
  /// "keyboard went away" checks.
  bool _homeKeyboardShown = false;
  double _homeKeyboardPeak = 0;
  int _homeKeyboardCheck = 0;
  double _keyboardRaw = 0;
  Timer? _keyboardRest;

  /// Last observed keyboard height by window width (for 首页 animation).
  final _knownKeyboard = <int, double>{};

  /// The conversation's title when the page opened (another host's list
  /// isn't loaded).
  String? _chatTitle;

  /// Native text selection action for ready pages: registered after the frame.
  BrowserSelectionBinding? _selection;
  bool _selectionQueued = false;
  bool _quoteSheetOpen = false;
  bool _returningToChat = false;

  /// Download confirmation: only one at a time.
  bool _downloadSheetOpen = false;

  /// 首页 placeholder: tracks the home tab to refresh hint on tab entry.
  String? _lastHomeTabId;
  int _homePlaceholderIndex = 0;

  String _homePlaceholder() {
    final l10n = context.l10n;
    final choices = l10n.browserAddressHintPlaceholders.split('\n');
    if (choices.isEmpty) return l10n.browserAddressHint;
    return choices[_homePlaceholderIndex % choices.length];
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(browserWorkspaceProvider, (_, _) => _queueSync());
    ref.listenManual(browserWorkspaceProvider.select((s) => s.persistenceFailed), (was, failed) {
      if (failed && was == false) _toast(appL10n.browserTabsUnsaved);
    });
    ref.listenManual(browserLibraryProvider.select((s) => s.persistenceFailed), (was, failed) {
      if (failed && was == false) _toast(appL10n.browserLibraryUnsaved);
    });
    ref.listenManual(browserLibraryProvider.select((s) => s.textZoom), (_, _) => _restyle());
    _addressFocus.addListener(() {
      // A new focus (or its loss) is a new edit: earlier keyboard checks lapse.
      _homeKeyboardShown = false;
      _homeKeyboardPeak = 0;
      _homeKeyboardCheck++;
      if (_addressFocus.hasFocus) {
        // 首页's box is the field itself: focusing it is starting to edit.
        if (!_editing && _onHome) {
          setState(() {
            _editing = true;
            _newTab = false;
            _invalid = false;
          });
        }
      } else if (_editing) {
        setState(_resetEdit);
      }
    });
    if (widget.sessionId != null && ref.read(activeHostProvider) == widget.host) _chatTitle = _liveTitle();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _workspace.ready;
    } catch (_) {}
    if (!mounted) return;
    try {
      if (widget.initialUrl case final url?) {
        await _open(url);
      } else if (ref.read(browserWorkspaceProvider).tabsFor(_scope).isEmpty) {
        // Never a blank browser: a new one starts on its home page.
        await _workspace.showHome(_scope);
      }
    } on StateError {
      if (mounted) _toast(context.l10n.browserTabLimit);
    }
    _queueSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    if (dark != _dark || scale != _systemScale) {
      _dark = dark;
      _systemScale = scale;
      _restyle();
    }
    _followKeyboard();
  }

  /// The pages' text: the app's text size times 网页文字大小.
  int get _textZoom => (_systemScale * ref.read(browserLibraryProvider).textZoom).round().clamp(50, 300);

  void _restyle() {
    final zoom = _textZoom;
    for (final page in _pool.pages) {
      if (!page.rendererGone) unawaited(page.appearance(dark: _dark, textZoom: zoom).catchError((_) {}));
    }
  }

  /// The keyboard moves the page once per slide ([WebKeyboard]).
  void _followKeyboard() {
    final raw = MediaQuery.viewInsetsOf(context).bottom;
    if (raw == _keyboardRaw) return;
    _keyboardRaw = raw;
    final width = MediaQuery.sizeOf(context).width;
    _keyboard.report(raw, width);
    _keyboardRest?.cancel();
    _keyboardRest = Timer(WebKeyboard.rest, () {
      if (mounted && _keyboard.settle(_keyboardRaw, width)) setState(() {});
    });
    _followHomeKeyboard(raw);
  }

  /// 首页 editing ends when its keyboard goes away. Android's back first goes
  /// to the IME, which only hides itself: Flutter sees no pop, just the inset
  /// falling to 0 while the field keeps focus. Only after this edit's keyboard
  /// was really up (a 0 right after focusing is the keyboard not there yet;
  /// a hardware keyboard never shows one), and only if nothing changed by the
  /// frame after: a newer inset, focus or edit retires the check.
  void _followHomeKeyboard(double raw) {
    _homeKeyboardCheck++;
    if (!_editing || !_onHome || !_addressFocus.hasFocus) return;
    if (raw > 0) {
      _homeKeyboardShown = true;
      // Keep the open height for the next edit. The closing IME emits ever
      // smaller insets; caching those would predict a seat at the bottom.
      if (raw >= _homeKeyboardPeak) {
        _homeKeyboardPeak = raw;
        final width = MediaQuery.sizeOf(context).width.round();
        _knownKeyboard[width] = raw;
      }
      return;
    }
    if (!_homeKeyboardShown) return;
    final check = _homeKeyboardCheck;
    // Never mid-build: didChangeDependencies runs inside it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || check != _homeKeyboardCheck || !_homeKeyboardShown) return;
      if (!_editing || !_onHome || !_addressFocus.hasFocus) return;
      if (MediaQuery.viewInsetsOf(context).bottom > 0) return;
      _endEdit();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _selection?.dispose();
    _keyboardRest?.cancel();
    for (final tab in _pool.tabs.toList()) {
      _unlisten(tab);
    }
    // The WebViews leave the tree with this page; then they are destroyed.
    final pages = _pool.drain();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final page in pages) {
        page.dispose();
      }
    });
    for (final preview in _previews.values) {
      unawaited(preview.image.evict());
    }
    _previews.clear();
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  /// Native selection-menu action: shown only when the visible page is ready
  /// and not editing, hidden when the overview or quote sheet is open.
  void _updateSelection() {
    if (_selectionQueued) return;
    _selectionQueued = true;
    _selection ??= BrowserSelectionBinding();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionQueued = false;
      if (!mounted) return;
      final route = ModalRoute.of(context);
      final tab = _selected;
      final page = tab == null || tab.url == null ? null : _pool[tab.id];
      final ready = page != null && page.ready && !page.rendererGone;
      if (route?.isCurrent == true && ready && !_overview && !_editing && !_quoteSheetOpen) {
        _selection?.show(
          page: page,
          label: appL10n.browserQuote,
          onQuote: (content) => _quote(initialContent: content),
        );
      } else {
        _selection?.hide();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Live pages

  /// After the change that asked for it: never mid-build.
  void _queueSync() {
    if (_syncQueued) return;
    _syncQueued = true;
    scheduleMicrotask(() {
      _syncQueued = false;
      if (mounted) _sync();
    });
  }

  bool get _onHome {
    final state = ref.read(browserWorkspaceProvider);
    return state.loaded && state.selectedFor(_scope)?.url == null;
  }

  BrowserTab? get _selected {
    final state = ref.read(browserWorkspaceProvider);
    return state.loaded ? state.selectedFor(_scope) : null;
  }

  /// The open tab's live page, when it is a web page that has one.
  BrowserPageController? get _page {
    final tab = _selected;
    return tab == null || tab.url == null ? null : _pool[tab.id];
  }

  void _sync() {
    final state = ref.read(browserWorkspaceProvider);
    if (!state.loaded) return;
    final tabs = {for (final t in state.tabsFor(_scope)) t.id: t};
    _gone.removeWhere((id) => !tabs.containsKey(id) || tabs[id]!.url == null);
    // A closed tab's snapshot goes with it; one of an address the tab has
    // left is never shown again.
    for (final id in _previews.keys.toList()) {
      final tab = tabs[id];
      if (tab == null || _previewFor(tab) == null) _dropPreview(id);
    }
    final retired = <BrowserPageController>[];
    // Closed tabs and tabs gone back to 首页 give their page up.
    for (final id in _pool.tabs.toList()) {
      if (tabs[id]?.url == null) retired.add(_drop(id)!);
    }
    final tab = state.selectedFor(_scope);
    final url = tab?.url;
    if (tab != null && url != null && !_gone.contains(tab.id)) {
      if (_pool.contains(tab.id)) {
        _pool.touch(tab.id);
      } else {
        // A new page for the tab: whatever was captured of the old one is
        // not this document.
        _dropPreview(tab.id);
        final page = _make(tab.id, url);
        if (page != null) {
          for (final evicted in _pool.put(tab.id, page)) {
            _forget(evicted.tab, evicted.page);
            retired.add(evicted.page);
          }
          // Own the tab before initialization can notify or finish.
          page.configureNavigation(tab.id);
          unawaited(page.initialize(dark: _dark, textZoom: _textZoom).catchError((_) {}));
        }
      }
    }
    _updateSelection();
    setState(() {});
    _dispose(retired);
  }

  BrowserPageController? _make(String tab, Uri url) {
    late final BrowserPageController page;
    try {
      page = ref.read(browserPageFactoryProvider)(
        initialUrl: url,
        onPageChanged: (url, title) {
          // Only the page that owns the tab writes it: an old one never
          // overwrites what replaced it.
          if (mounted && identical(_pool[tab], page)) {
            unawaited(_workspace.updatePage(tab, url: url, title: title).catchError((_) {}));
          }
        },
      );
      page.onDownloadRequested = (request) => _handleDownload(request, page, tab);
    } on FormatException {
      // A saved address the policy no longer opens: the tab goes.
      unawaited(_workspace.close(tab).catchError((_) => null));
      return null;
    }
    void listener() => _onPage(tab, page);
    _listeners[tab] = listener;
    page.addListener(listener);
    return page;
  }

  /// [tab]'s page out of the pool (not disposed yet).
  BrowserPageController? _drop(String tab) {
    final page = _pool.take(tab);
    if (page != null) _forget(tab, page);
    return page;
  }

  void _unlisten(String tab) {
    final page = _pool[tab];
    if (page != null) _forget(tab, page);
  }

  /// [page] no longer listened to or recorded for [tab].
  void _forget(String tab, BrowserPageController page) {
    final listener = _listeners.remove(tab);
    if (listener != null) page.removeListener(listener);
    _recorded.remove(tab);
    _errors.remove(tab);
    _icons.remove(tab);
    page.onDownloadRequested = null;
  }

  /// Out of the tree this frame, destroyed after it.
  void _dispose(List<BrowserPageController> pages) {
    if (pages.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final page in pages) {
        page.dispose();
      }
    });
  }

  void _onPage(String tab, BrowserPageController page) {
    if (!mounted || !identical(_pool[tab], page)) return;
    final preview = _previews[tab];
    // A navigation, reload, SPA history change, failure or lost renderer
    // (each a new revision) retires the snapshot of the old document.
    if (preview != null &&
        (!identical(preview.owner, page) || preview.revision != page.revision || page.rendererGone)) {
      _dropPreview(tab);
      // The overview may be showing it.
      if (_overview) setState(() {});
    }
    final open = _selected?.id == tab;
    final error = page.error;
    if (error != _errors[tab]) {
      _errors[tab] = error;
      if (error == 'blocked_url' && open) _toast(appL10n.browserBlocked);
    }
    if (page.rendererGone) {
      // Every tab whose page went with the renderer can be reopened.
      setState(() => _gone.add(tab));
      _dispose([_drop(tab)!]);
      return;
    }
    if (page.ready) {
      // Once per page and address: not on every rebuild or title change.
      final mark = (page.revision, page.url);
      if (_recorded[tab] != mark) {
        _recorded[tab] = mark;
        unawaited(_library.recordVisit(page.url, page.title).catchError((_) {}));
      }
      // Once per document; never from a notification it caused.
      if (_icons[tab]?.revision != page.revision) unawaited(_fetchIcon(tab, page));
    }
    if (open) setState(() {});
  }

  void _reopen(String tab) {
    setState(() => _gone.remove(tab));
    _queueSync();
  }

  // ---------------------------------------------------------------------------
  // Going places

  /// [url] in a tab: the one already on that address, else a new one.
  Future<void> _open(Uri url) async {
    final existing = ref.read(browserWorkspaceProvider).tabsFor(_scope).where((t) => t.url == url).firstOrNull;
    try {
      if (existing != null) {
        await _workspace.activate(existing.id);
      } else {
        await _workspace.open(_scope, url);
      }
    } on StateError catch (e) {
      if (mounted) _toast(e.message == 'tab_limit' ? context.l10n.browserTabLimit : context.l10n.browserLoadFailed);
    } on FormatException {
      if (mounted) _toast(context.l10n.browserBlocked);
    }
  }

  /// [url] in the open tab (its home page, its live page, or a page that
  /// closed), or in a new tab with [newTab].
  Future<void> _go(Uri url, {bool newTab = false}) async {
    final tab = _selected;
    if (newTab || tab == null) {
      try {
        await _workspace.open(_scope, url);
      } on StateError {
        if (mounted) _toast(context.l10n.browserTabLimit);
      } on FormatException {
        if (mounted) _toast(context.l10n.browserBlocked);
      }
      return;
    }
    final page = _pool[tab.id];
    if (tab.url != null && page != null && !page.rendererGone) {
      try {
        await page.load(url);
      } catch (_) {
        if (mounted) _toast(context.l10n.browserLoadFailed);
      }
      return;
    }
    // The home page, or a page whose renderer went: a new live page there.
    _gone.remove(tab.id);
    try {
      await _workspace.navigate(tab.id, url);
    } on FormatException {
      if (mounted) _toast(context.l10n.browserBlocked);
    } on StateError {
      if (mounted) _toast(context.l10n.browserLoadFailed);
    }
    _queueSync();
  }

  Future<void> _home() async {
    try {
      await _workspace.showHome(_scope);
    } on StateError {
      if (mounted) _toast(context.l10n.browserTabLimit);
    }
  }

  Future<void> _newHomeTab() async {
    try {
      await _workspace.openHome(_scope);
    } on StateError {
      if (mounted) _toast(context.l10n.browserTabLimit);
    }
  }

  Future<BrowserTab?> _close(String id) async {
    final closed = await _workspace.close(id);
    // The last one closed: a home page, never a blank browser.
    if (mounted && ref.read(browserWorkspaceProvider).tabsFor(_scope).isEmpty) await _home();
    return closed;
  }

  Future<bool> _restore(BrowserTab tab) async {
    try {
      await _workspace.restoreTab(tab);
      return true;
    } on StateError {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<void> _closeAll() async {
    await _workspace.closeAll(_scope);
    if (mounted) await _home();
  }

  // ---------------------------------------------------------------------------
  // The address

  void _startEdit({bool newTab = false}) {
    if (_onHome && !newTab) {
      // The box on 首页 is the field: focus it where it is.
      _addressFocus.requestFocus();
      return;
    }
    final page = _page;
    final text = newTab || page == null ? '' : page.url.toString();
    _address.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    _selection?.hide();
    setState(() {
      _editing = true;
      _newTab = newTab;
      _invalid = false;
    });
  }

  void _resetEdit() {
    _homeKeyboardShown = false;
    _homeKeyboardCheck++;
    // 首页's box goes back to its hint.
    if (_onHome) _address.clear();
    _editing = false;
    _newTab = false;
    _invalid = false;
  }

  void _endEdit() {
    _addressFocus.unfocus();
    if (_editing) {
      setState(_resetEdit);
      _updateSelection();
    }
  }

  /// What was typed: an address goes there, words are searched; a blocked
  /// address or protocol says so and is never searched for.
  Future<void> _submit(String raw) async {
    final intent = BrowserOmnibox.resolve(raw, engine: ref.read(browserLibraryProvider).engine);
    if (intent == null) {
      setState(() => _invalid = raw.trim().isNotEmpty);
      _addressFocus.requestFocus();
      return;
    }
    await _pick(intent.url);
  }

  /// A suggestion, or what Enter would open.
  Future<void> _pick(Uri url) async {
    final newTab = _newTab;
    _endEdit();
    if (newTab) {
      unawaited(RefreshRateService.instance.requestActivity());
      await _leavePage(() => _go(url, newTab: true));
    } else {
      await _go(url);
    }
  }

  // ---------------------------------------------------------------------------
  // Actions

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _retry() async {
    final page = _page;
    if (page == null) return;
    try {
      if (page.error != null && page.error != 'blocked_url') {
        await page.load(page.url);
      } else {
        await page.reload();
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // 标签页

  void _dropPreview(String tab) {
    final preview = _previews.remove(tab);
    if (preview != null) unawaited(preview.image.evict());
  }

  /// [tab]'s snapshot, while it still shows what the tab would show: the same
  /// address and, while its page is live, the same page and document. A
  /// snapshot outlives its page leaving the pool (the card keeps the last
  /// picture) but not a new page made for the tab.
  BrowserTabPreview? _previewFor(BrowserTab tab) {
    final preview = _previews[tab.id];
    if (preview == null || !preview.shows(tab)) return null;
    final live = _pool[tab.id];
    if (live != null && (!identical(live, preview.owner) || live.revision != preview.revision)) return null;
    return preview;
  }

  /// A snapshot of the open page as it is on screen now. It is kept only if,
  /// when it arrives, the same tab still has the same live page on the same
  /// document and address, still visible; never throws (the caller goes on
  /// without one). Decoding is the caller's choice and never adds it back.
  Future<void> _capture({Duration wait = const Duration(milliseconds: 700)}) async {
    final tab = _selected;
    final page = _page;
    // Offstage under the overview, or not a live page: nothing to draw.
    if (_overview || tab == null || page == null || !page.ready || _gone.contains(tab.id)) return;
    // A favicon that came after the page finished: one more try now.
    if (_icons[tab.id] case (revision: final r, kept: false) when r == page.revision) {
      unawaited(_fetchIcon(tab.id, page, retry: true));
    }
    final revision = page.revision;
    final url = page.url;
    Uint8List? bytes;
    try {
      bytes = await page.capturePreview().timeout(wait);
    } catch (_) {
      return;
    }
    if (bytes == null || bytes.isEmpty || !mounted) return;
    final now = ref.read(browserWorkspaceProvider).tabsFor(_scope).where((t) => t.id == tab.id).firstOrNull;
    final saved = now?.url;
    if (saved == null ||
        _gone.contains(tab.id) ||
        !identical(_pool[tab.id], page) ||
        !page.ready ||
        page.revision != revision ||
        page.url != url) {
      return;
    }
    _dropPreview(tab.id);
    _previews[tab.id] = BrowserTabPreview(image: MemoryImage(bytes), url: saved, revision: revision, owner: page);
    while (_previews.length > _maxPreviews) {
      _dropPreview(_previews.keys.first);
    }
  }

  /// [page]'s own favicon, as WebView loaded it, handed to the in-memory icon
  /// store for its site: only while the same tab still has the same live,
  /// ready page on the same document and address. Nothing new is fetched
  /// from the network here.
  Future<void> _fetchIcon(String tab, BrowserPageController page, {bool retry = false}) async {
    if (!page.ready) return;
    final revision = page.revision;
    final url = page.url;
    final tried = _icons[tab];
    if (tried != null && tried.revision == revision && (tried.kept || !retry)) return;
    _icons[tab] = (revision: revision, kept: false);
    bool current() =>
        mounted &&
        identical(_pool[tab], page) &&
        page.ready &&
        !_gone.contains(tab) &&
        page.revision == revision &&
        page.url == url &&
        ref.read(browserWorkspaceProvider).tabsFor(_scope).any((t) => t.id == tab && t.url != null);
    Uint8List? bytes;
    try {
      bytes = await page.siteIcon();
    } catch (_) {
      return;
    }
    final origin = browserSiteOrigin(url);
    if (bytes == null || bytes.isEmpty || origin == null || !current()) return;
    bool kept;
    try {
      kept = await ref.read(browserSiteIconsProvider).remember(url, bytes, isCurrent: current);
    } catch (_) {
      return;
    }
    if (!kept || !mounted) return;
    if (_icons[tab]?.revision == revision) _icons[tab] = (revision: revision, kept: true);
    ref.invalidate(browserSiteIconProvider(origin));
  }

  /// Every snapshot decoded (at most [wait]), so a flight's first frame
  /// isn't blank. Only reads the map: one dropped meanwhile stays dropped.
  Future<void> _decodePreviews({Duration wait = const Duration(milliseconds: 300)}) async {
    final images = [for (final p in _previews.values) p.image];
    if (images.isEmpty) return;
    try {
      await Future.wait([for (final image in images) precacheImage(image, context)]).timeout(wait);
    } catch (_) {}
  }

  /// Leaving the visible page for another tab: its snapshot first, then
  /// [action] — unless a newer move, the overview or a tab switch came in
  /// meanwhile; then this one is dropped, never run against another tab.
  Future<void> _leavePage(Future<void> Function() action) async {
    final generation = ++_moveGeneration;
    final from = _selected?.id;
    await _capture(wait: const Duration(milliseconds: 400));
    if (!mounted || generation != _moveGeneration || _overview || _selected?.id != from) return;
    await action();
  }

  /// Where the open tab is drawn, in the page's own coordinates.
  Rect _contentRect() {
    final content = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (content == null || stack == null || !content.hasSize) return Offset.zero & MediaQuery.sizeOf(context);
    return content.localToGlobal(Offset.zero, ancestor: stack) & content.size;
  }

  Future<void> _showTabs() async {
    if (_overview || _openingOverview) return;
    _openingOverview = true;
    // A move still waiting on its snapshot never runs under the overview.
    _moveGeneration++;
    _endEdit();
    _selection?.hide();
    // Reset revealing flag when opening overview.
    _overviewRevealing = false;
    try {
      await _capture();
      if (mounted) await _decodePreviews();
    } finally {
      _openingOverview = false;
    }
    if (!mounted || _overview) return;
    unawaited(RefreshRateService.instance.requestActivity());
    setState(() {
      _overview = true;
      _overviewOrigin = _contentRect();
    });
  }

  void _overviewDismissed() {
    if (mounted) {
      setState(() {
        _overview = false;
        _overviewRevealing = false;
      });
      _updateSelection();
    }
  }

  void _revealOverviewPage() {
    if (mounted && _overview) {
      setState(() => _overviewRevealing = true);
    }
  }

  Future<void> _more() async {
    final page = _page;
    final url = page?.url;
    final bookmark = url == null ? null : ref.read(browserLibraryProvider).bookmarkFor(url);
    final choice = await showBrowserMenu(context, page: url, bookmarked: bookmark != null);
    if (!mounted || choice == null) return;
    final l10n = context.l10n;
    switch (choice) {
      case BrowserMenuChoice.bookmark when url != null:
        if (bookmark != null) {
          final removed = await showBookmarkEditor(context, bookmark: bookmark);
          if (removed && mounted) _toast(context.l10n.browserBookmarkRemoved);
        } else {
          try {
            await _library.saveBookmark(url, title: page?.title ?? '');
            if (mounted) _toast(l10n.browserBookmarkSaved);
          } on StateError catch (e) {
            if (mounted) _toast(e.message == 'bookmark_limit' ? l10n.browserBookmarkLimit : l10n.browserLoadFailed);
          } on FormatException {
            if (mounted) _toast(l10n.browserBlocked);
          }
        }
      case BrowserMenuChoice.share when url != null:
        await ref.read(browserShareProvider)(url, page?.title ?? '').catchError((_) {});
      case BrowserMenuChoice.copy when url != null:
        await Clipboard.setData(ClipboardData(text: url.toString()));
        if (mounted) _toast(l10n.commonCopied);
      case BrowserMenuChoice.external when url != null:
        await ref.read(browserExternalOpenProvider)(url).catchError((_) {});
      case BrowserMenuChoice.library:
        await _openLibrary(BrowserLibraryTab.bookmarks);
      case BrowserMenuChoice.downloads:
        await _openDownloads();
      case BrowserMenuChoice.textSize:
        await showBrowserTextSizeSheet(context);
      case BrowserMenuChoice.engine:
        await showBrowserEngineSheet(context);
      default:
        break;
    }
  }

  Future<void> _openDownloads() async {
    final goToChat = await Navigator.of(context)
        .push<bool>(BrowserDownloadsPage.route(host: widget.host, sessionId: widget.sessionId));
    if (goToChat == true && mounted) await _goToChat();
  }

  Future<void> _handleDownload(BrowserDownloadRequest request, BrowserPageController page, String tabId) async {
    if (!mounted) return;
    final controller = ref.read(browserDownloadsProvider.notifier);
    final revision = page.revision;
    final sourceUrl = page.url;
    bool current() =>
        mounted &&
        ModalRoute.of(context)?.isCurrent == true &&
        ref.read(activeHostProvider) == widget.host &&
        _selected?.id == tabId &&
        identical(_pool[tabId], page) &&
        !page.rendererGone &&
        page.revision == revision &&
        page.url == sourceUrl;
    if (!current() || _overview || _quoteSheetOpen || _editing || _downloadSheetOpen) {
      await controller.reject(request);
      return;
    }
    setState(() => _downloadSheetOpen = true);
    try {
      // A sheet only returns consent and the displayed folder. No transfer has
      // started yet. The source document must still own the tab after the await.
      final folderId = await showBrowserDownloadConfirmation(context, request);
      if (folderId == null || !current()) return;
      await controller.confirm(request, folderId: folderId);
    } on PlatformException catch (e) {
      if (mounted) _toast(browserDownloadErrorText(context, e.code));
    } on Object {
      if (mounted) _toast(context.l10n.browserDownloadError);
    } finally {
      await controller.reject(request);
      if (mounted) setState(() => _downloadSheetOpen = false);
    }
  }

  Future<void> _openLibrary(BrowserLibraryTab tab) async {
    final url = await openBrowserLibrary(context, tab: tab);
    if (url != null && mounted) await _go(url);
  }

  Future<void> _clearHistory() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.browserHistoryClear),
        content: Text(l10n.browserHistoryClearConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.commonCancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.commonConfirm)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _library.clearHistory();
      if (mounted) _toast(l10n.browserHistoryClear);
    } catch (_) {
      if (mounted) _toast(l10n.browserLoadFailed);
    }
  }

  String? _liveTitle() {
    final id = widget.sessionId;
    if (id == null) return null;
    return ref.read(sessionsProvider).value?.where((s) => s.sessionId == id).firstOrNull?.title?.trim();
  }

  /// The conversation and host the quote goes to.
  BrowserQuoteTarget _target() {
    final l10n = context.l10n;
    final host = widget.host;
    final String chat;
    if (widget.sessionId == null) {
      chat = l10n.commonNewChat;
    } else {
      if (ref.read(activeHostProvider) == host) _chatTitle = _liveTitle() ?? _chatTitle;
      final title = _chatTitle;
      chat = title == null || title.isEmpty ? l10n.commonUntitledChat : title;
    }
    final name = host.isLocal ? null : ref.read(hostNameProvider(host));
    return (chat: chat, host: hostLabel(host.kind, name));
  }

  Future<void> _quote({BrowserPageContent? initialContent}) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || _quoteSheetOpen) return;
    final page = _page;
    if (page == null || !page.ready) return;
    // initialContent must bind to the current page.
    if (initialContent != null && BrowserPolicy.savedUrl(page.url) != initialContent.url) return;
    _selection?.hide();
    setState(() => _quoteSheetOpen = true);
    unawaited(RefreshRateService.instance.requestActivity());
    final added = await showBrowserQuoteSheet(
      context,
      page: page,
      scope: _scope,
      target: _target(),
      initialContent: initialContent,
    );
    if (mounted) {
      setState(() => _quoteSheetOpen = false);
      _updateSelection();
    }
    if (!added || !mounted) return;
    final l10n = context.l10n;
    // Back to the conversation only while its host is still the one in use.
    final reachable = ref.read(activeHostProvider) == widget.host;
    _toast(
      l10n.browserAddedToDraft,
      action: reachable
          ? SnackBarAction(label: l10n.browserReturnToChat, onPressed: () => unawaited(_goToChat()))
          : null,
    );
  }

  Future<void> _goToChat() async {
    if (_returningToChat || !mounted || ref.read(activeHostProvider) != widget.host) return;
    _returningToChat = true;
    try {
      final tab = _selected;
      final page = tab?.url == null ? null : _pool[tab!.id];
      // Save return item for pages with valid URL (ready or loading), preview only when ready
      if (page != null && tab!.url != null && !page.rendererGone && !_overview) {
        final revision = page.revision;
        Uint8List? bytes;
        if (page.ready) {
          try {
            bytes = await page.capturePreview().timeout(const Duration(milliseconds: 400));
          } catch (_) {}
        }
        if (!mounted ||
            ref.read(activeHostProvider) != widget.host ||
            _selected?.id != tab.id ||
            !identical(_pool[tab.id], page) ||
            page.revision != revision ||
            !ModalRoute.of(context)!.isCurrent) {
          return;
        }
        final currentTab = ref.read(browserWorkspaceProvider).tabsFor(_scope).where((t) => t.id == tab.id).firstOrNull;
        if (currentTab?.url != null) {
          ref
              .read(browserReturnProvider.notifier)
              .remember(
                host: widget.host,
                sessionId: widget.sessionId,
                tabId: tab.id,
                url: page.url,
                title: page.title,
                preview: bytes,
              );
        }
      }
      if (!mounted || !ModalRoute.of(context)!.isCurrent) return;
      unawaited(RefreshRateService.instance.requestActivity());
      ref.read(currentSessionProvider.notifier).select(widget.sessionId);
      Navigator.of(context).popUntil((route) => route.isFirst);
    } finally {
      _returningToChat = false;
    }
  }

  Future<void> _back() async {
    if (_overview) {
      await _overviewKey.currentState?.leave();
      return;
    }
    if (_editing) {
      _endEdit();
      return;
    }
    final page = _page;
    final tab = _selected;
    if (page != null && page.canGoBack) {
      await page.back();
    } else if (tab != null && tab.homeBack) {
      await _workspace.returnHome(tab.id);
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _forward() async {
    final page = _page;
    final tab = _selected;
    if (page != null && page.canGoForward) {
      await page.forward();
    } else if (tab != null && tab.isHome && tab.forwardUrl != null) {
      await _workspace.resumeFromHome(tab.id);
    }
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _updateSelection();
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    // Typing removes the toolbar from the tree. Keep its conversation follow
    // attached to this route so a task ending during input is not missed.
    ref.listen(browserConversationActivityProvider((host: widget.host, sessionId: widget.sessionId)), (_, _) {});
    final workspace = ref.watch(browserWorkspaceProvider);
    ref.watch(browserLibraryProvider.select((s) => s.loaded));
    final tabs = workspace.tabsFor(_scope);
    final selected = workspace.loaded ? workspace.selectedFor(_scope) : null;
    final home = workspace.loaded && (selected == null || selected.url == null);
    // Entering a new home tab (or returning from web to home): pick a fresh hint.
    if (home) {
      final homeId = selected?.id;
      if (homeId != _lastHomeTabId) {
        _lastHomeTabId = homeId;
        _homePlaceholderIndex = math.Random().nextInt(1000);
      }
    } else {
      // Left home: clear the record so next home entry counts as new.
      _lastHomeTabId = null;
    }
    final page = home || selected == null ? null : _pool[selected.id];
    final typing = _keyboard.height > 0;
    final sides = EdgeInsets.only(left: media.padding.left, right: media.padding.right);
    final gesture = math.max(media.viewPadding.bottom, BrowserPage.edge);
    final narrow = media.size.width <= 360;
    // The bottom capsule: 44 keys in 4 of padding, 8 above, the gesture area below.
    final toolbarHeight = 52 + 8 + gesture;
    final homeEditing = home && _editing;

    Widget content;
    if (!workspace.loaded) {
      content = const Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (home) {
      final width = MediaQuery.sizeOf(context).width.round();
      content = BrowserHome(
        scope: _scope,
        field: _homeField(context),
        editing: _editing,
        input: _address,
        bottomReserve: toolbarHeight,
        knownKeyboard: _knownKeyboard[width],
        active: !_overview && (ModalRoute.of(context)?.isCurrent ?? true),
        onSearch: _startEdit,
        onOpen: (url) => unawaited(_go(url)),
        onPick: (url) => unawaited(_pick(url)),
        onOpenTab: (id) => unawaited(_workspace.activate(id)),
        onHistory: () {
          _endEdit();
          unawaited(_openLibrary(BrowserLibraryTab.history));
        },
      );
    } else if (_gone.contains(selected!.id)) {
      content = RendererGone(label: context.l10n.webPageClosed, onReopen: () => _reopen(selected.id));
    } else if (page == null) {
      // The tab's page is being made (the next microtask).
      content = const SizedBox.expand();
    } else {
      content = BrowserPageView(key: ObjectKey(page), page: page, onRetry: () => unawaited(_retry()));
    }

    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      // 首页 lays itself out to the screen's bottom (its box follows the
      // keyboard frame by frame); the capsule floats over it.
      extendBody: home,
      // In the bar's seat, so toasts float above the capsule instead of
      // over it; gone while typing.
      bottomNavigationBar: typing || homeEditing
          ? null
          : Padding(
              padding:
                  sides + EdgeInsets.fromLTRB(narrow ? 0 : BrowserPage.edge, 8, narrow ? 0 : BrowserPage.edge, gesture),
              // Its own height only: the bar's seat lets a child grow.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [_toolbar(context, page, home: home)],
              ),
            ),
      body: Padding(
        padding: EdgeInsets.only(top: media.padding.top, bottom: typing && !home ? _keyboard.height : 0),
        child: Column(
          children: [
            Padding(
              padding: sides + const EdgeInsets.fromLTRB(BrowserPage.edge, 4, BrowserPage.edge, 8),
              child: _topBar(context, tabs.length, page),
            ),
            BrowserAddressProblem(visible: _editing && _invalid),
            Expanded(
              child: Padding(
                key: _contentKey,
                padding: sides,
                // Suggestions cover the page while typing; the page
                // (and its WebView) stays where it is underneath. Under
                // 标签页 the WebView is offstage: never painted, never
                // transformed, kept alive.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(offstage: _overview && !_overviewRevealing, child: content),
                    if (_editing && !home)
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _address,
                        builder: (context, value, _) => value.text.trim().isEmpty
                            ? const SizedBox.shrink()
                            : ColoredBox(
                                color: theme.colorScheme.surface,
                                child: BrowserSuggestions(input: value.text, onOpen: (url) => unawaited(_pick(url))),
                              ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return PopScope(
      canPop: !_overview && !_editing && !(page?.canGoBack ?? false) && !(_selected?.homeBack ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: dshSystemOverlay(theme.brightness),
        child: AppBackdrop(
          glow: false,
          child: Stack(
            key: _stackKey,
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring: _overview,
                child: ExcludeSemantics(excluding: _overview, child: scaffold),
              ),
              if (_overview)
                BrowserTabsOverview(
                  key: _overviewKey,
                  scope: _scope,
                  previews: {for (final tab in workspace.tabsFor(_scope)) tab.id: ?_previewFor(tab)},
                  origin: _overviewOrigin,
                  actions: BrowserTabsActions(
                    newTab: _newHomeTab,
                    close: _close,
                    restore: _restore,
                    closeAll: _closeAll,
                  ),
                  onDismissed: _overviewDismissed,
                  onRevealPage: _revealOverviewPage,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, int tabCount, BrowserPageController? page) {
    final l10n = context.l10n;
    final homeEdit = _onHome && _editing;
    final scheme = Theme.of(context).colorScheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: BrowserPage.bar,
      child: BackdropGroup(
        child: homeEdit
            ? Row(
                children: [
                  GlassIconButton(
                    key: const ValueKey('browser-home-back'),
                    icon: AppIcons.back,
                    tooltip: l10n.commonBack,
                    onPressed: _endEdit,
                  ),
                  Expanded(
                    child: Center(child: Text(l10n.browserSearch, style: Theme.of(context).textTheme.titleSmall)),
                  ),
                  GlassIconButton(
                    key: const ValueKey('browser-clear-history'),
                    icon: AppIcons.delete,
                    tooltip: l10n.browserHistoryClear,
                    onPressed: () => _clearHistory(),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: page == null && _onHome
                        // 首页 has its own box in the middle: one field, never two.
                        ? const SizedBox.shrink()
                        : _editing
                        ? _addressField(context)
                        : _addressPill(context, page),
                  ),
                  const SizedBox(width: 8),
                  if (page != null && !_editing)
                    Tooltip(
                      message: l10n.browserReload,
                      child: Semantics(
                        button: true,
                        label: l10n.browserReload,
                        excludeSemantics: true,
                        child: Pressable(
                          child: SizedBox.square(
                            dimension: BrowserChrome.bar,
                            child: GlassSurface(
                              key: const ValueKey('browser-refresh'),
                              tier: GlassTier.chrome,
                              circle: true,
                              grouped: true,
                              onTap: () => unawaited(_retry()),
                              child: Center(
                                child: BrowserReloadIcon(
                                  loading: page.loading,
                                  reducedMotion: reducedMotion,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (page != null && !_editing) const SizedBox(width: 8),
                  BrowserTabsButton(count: tabCount, onPressed: () => unawaited(_showTabs())),
                ],
              ),
      ),
    );
  }

  Widget _addressPill(BuildContext context, BrowserPageController? page) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final site = page == null ? null : browserSite(page.url);
    final showWhale = page != null;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final whaleActive = !_overview && (ModalRoute.of(context)?.isCurrent ?? true);
    return Semantics(
      button: true,
      label: site ?? l10n.browserAddressHint,
      hint: site == null ? null : l10n.browserAddressHint,
      excludeSemantics: true,
      child: GlassSurface(
        key: const ValueKey('browser-address'),
        tier: GlassTier.chrome,
        stadium: true,
        grouped: true,
        onTap: () => _startEdit(),
        child: SizedBox.expand(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (showWhale) ...[
                  RepaintBoundary(
                    child: WhaleTail(
                      height: 20,
                      color: whaleColorFor(theme.brightness),
                      level: 2,
                      still: !page.loading || reducedMotion || !whaleActive,
                    ),
                  ),
                  const SizedBox(width: 6),
                ] else if (site == null) ...[
                  Icon(AppIcons.search, size: 18, color: colors.textTertiary),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    site ?? l10n.browserAddressHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: site == null
                        ? theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)
                        : theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _addressField(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    const none = OutlineInputBorder(borderSide: BorderSide.none);
    return GlassSurface(
      tier: GlassTier.chrome,
      stadium: true,
      grouped: true,
      child: SizedBox.expand(
        child: TextField(
          key: const ValueKey('browser-address-field'),
          controller: _address,
          focusNode: _addressFocus,
          autofocus: true,
          // Plain text with suggestions on: with them off, Flutter's Android
          // embedding asks for a visible-password field, which some phones
          // answer with a secure keyboard that can't type Chinese.
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          enableSuggestions: true,
          textAlignVertical: TextAlignVertical.center,
          style: theme.textTheme.bodyMedium,
          onChanged: (_) {
            if (_invalid) setState(() => _invalid = false);
          },
          // Submitting a bad address keeps the keyboard up to fix it.
          onEditingComplete: () {},
          onSubmitted: (value) => unawaited(_submit(value)),
          // The glass capsule is the field's only surface: no theme fill.
          decoration: InputDecoration(
            filled: false,
            isDense: true,
            hintText: l10n.browserAddressHint,
            hintStyle: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
            contentPadding: const EdgeInsets.only(left: 16),
            border: none,
            enabledBorder: none,
            focusedBorder: none,
            suffixIconConstraints: const BoxConstraints.tightFor(width: 44, height: 44),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _address,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : Semantics(
                      button: true,
                      label: l10n.commonClear,
                      excludeSemantics: true,
                      onTap: _address.clear,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _address.clear,
                        child: Icon(AppIcons.clear, size: 18, color: colors.textTertiary),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 首页's field, inside its box. The same element from rest to editing and
  /// back (only its box moves), so the IME connection and composing survive.
  Widget _homeField(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    const none = OutlineInputBorder(borderSide: BorderSide.none);
    final placeholder = _homePlaceholder();
    return Semantics(
      label: l10n.browserAddressHint,
      excludeSemantics: false,
      child: TextField(
        key: const ValueKey('browser-address-field'),
        controller: _address,
        focusNode: _addressFocus,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.go,
        autocorrect: false,
        enableSuggestions: true,
        textAlignVertical: TextAlignVertical.center,
        style: theme.textTheme.bodyLarge,
        onChanged: (_) {
          if (_invalid) setState(() => _invalid = false);
        },
        onEditingComplete: () {},
        onSubmitted: (value) => unawaited(_submit(value)),
        // The home box is the field's only surface: no theme fill or border.
        decoration: InputDecoration(
          filled: false,
          isDense: true,
          hintText: placeholder,
          hintStyle: theme.textTheme.bodyLarge?.copyWith(color: colors.textTertiary),
          contentPadding: const EdgeInsets.only(right: 12),
          border: none,
          enabledBorder: none,
          focusedBorder: none,
          suffixIconConstraints: const BoxConstraints.tightFor(width: 44, height: 44),
          suffixIcon: _clearKey(context),
        ),
      ),
    );
  }

  Widget _clearKey(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _address,
      builder: (context, value, _) => value.text.isEmpty
          ? const SizedBox.shrink()
          : Semantics(
              button: true,
              label: l10n.commonClear,
              excludeSemantics: true,
              onTap: _address.clear,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _address.clear,
                child: Icon(AppIcons.clear, size: 18, color: colors.textTertiary),
              ),
            ),
    );
  }

  Widget _toolbar(BuildContext context, BrowserPageController? page, {required bool home}) {
    final l10n = context.l10n;
    final live = page != null && !page.rendererGone;
    final tab = _selected;
    final canBack = (live && page.canGoBack) || (tab?.homeBack ?? false);
    final canForward = (live && page.canGoForward) || (tab != null && tab.isHome && tab.forwardUrl != null);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // 7 buttons * 44 = 308
        // At 320dp (narrow, no outer edge): maxWidth ~320, use spacing=0 pad=4 => 308+0+8=316
        // At 360dp (narrow, no outer edge): maxWidth ~360, use spacing=3 pad=4 => 308+18+8=334
        // Above 360dp (outer edge 12 each side): more room for spacing
        final double spacing;
        final double edgePad;
        if (width < 336) {
          // 320dp territory
          spacing = 0;
          edgePad = 4.0;
        } else if (width < 400) {
          // 360dp territory
          spacing = 3.0;
          edgePad = 4.0;
        } else {
          // wider screens
          spacing = 4.0;
          edgePad = 4.0;
        }
        return Center(
          child: GlassSurface(
            key: const ValueKey('browser-toolbar'),
            tier: GlassTier.chrome,
            stadium: true,
            padding: EdgeInsets.all(edgePad),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: spacing,
              children: [
                BrowserToolButton(
                  icon: AppIcons.back,
                  tooltip: l10n.browserBack,
                  onPressed: canBack ? () => unawaited(_back()) : null,
                ),
                BrowserToolButton(
                  icon: AppIcons.forward,
                  tooltip: l10n.browserForward,
                  onPressed: canForward ? () => unawaited(_forward()) : null,
                ),
                BrowserToolButton(
                  key: const ValueKey('browser-home-key'),
                  icon: AppIcons.home,
                  tooltip: l10n.browserHome,
                  onPressed: home ? null : () => unawaited(_leavePage(_home)),
                ),
                BrowserToolButton(
                  key: const ValueKey('browser-quote'),
                  icon: AppIcons.quote,
                  tooltip: l10n.browserQuote,
                  onPressed: live && page.ready ? () => unawaited(_quote()) : null,
                ),
                BrowserConversationButton(
                  key: const ValueKey('browser-return-to-chat'),
                  target: (host: widget.host, sessionId: widget.sessionId),
                  tooltip: l10n.browserReturnToChat,
                  active: !_overview && !_editing && (ModalRoute.of(context)?.isCurrent ?? true),
                  onPressed: () => unawaited(_goToChat()),
                ),
                BrowserToolButton(
                  key: const ValueKey('browser-more'),
                  icon: AppIcons.more,
                  tooltip: l10n.commonMore,
                  onPressed: () => unawaited(_more()),
                ),
                BrowserToolButton(
                  key: const ValueKey('browser-close'),
                  icon: AppIcons.close,
                  tooltip: l10n.browserClose,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
