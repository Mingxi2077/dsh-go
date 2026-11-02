// The live pages of one 网页: at most [capacity] tabs keep their WebView, the
// one used least recently gives its up first. Only the open tab's page is in
// the widget tree; the others stay as objects, so switching back to one
// shows it as it was instead of loading it again. A page leaves the tree
// before it is destroyed: [take] hands it back, and the caller disposes it
// after the frame that no longer shows it.

import '../../browser/browser_page_controller.dart';

class BrowserPagePool {
  BrowserPagePool({this.capacity = 3}) : assert(capacity > 0);

  final int capacity;

  /// By tab id, least recently used first.
  final _pages = <String, BrowserPageController>{};

  BrowserPageController? operator [](String tab) => _pages[tab];

  bool contains(String tab) => _pages.containsKey(tab);

  Iterable<String> get tabs => _pages.keys;

  Iterable<BrowserPageController> get pages => _pages.values;

  int get length => _pages.length;

  /// [tab] was just shown: the last to give its page up.
  void touch(String tab) {
    final page = _pages.remove(tab);
    if (page != null) _pages[tab] = page;
  }

  /// Keeps [page] for [tab] (most recent) and returns the pages that no
  /// longer fit, least recent first, with their tabs: the caller takes them
  /// out of the tree and disposes them.
  List<({String tab, BrowserPageController page})> put(String tab, BrowserPageController page) {
    final out = <({String tab, BrowserPageController page})>[];
    final old = _pages.remove(tab);
    if (old != null && !identical(old, page)) out.add((tab: tab, page: old));
    _pages[tab] = page;
    while (_pages.length > capacity) {
      final victim = _pages.keys.first;
      out.add((tab: victim, page: _pages.remove(victim)!));
    }
    return out;
  }

  /// Removes and returns [tab]'s page (the caller disposes it).
  BrowserPageController? take(String tab) => _pages.remove(tab);

  /// Every page, emptied (the caller disposes them).
  List<BrowserPageController> drain() {
    final all = _pages.values.toList();
    _pages.clear();
    return all;
  }
}
