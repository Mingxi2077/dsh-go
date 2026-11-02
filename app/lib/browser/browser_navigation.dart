import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'browser_models.dart';
import 'browser_policy.dart';

/// Only opaque Android saveState bundles live in the native cache. Neither
/// bundles nor a synthetic URL history cross this channel or reach storage.
abstract class BrowserNavigationPlatform {
  Future<bool> restore(int id, String key, int generation, Uri expectedUrl);
  Future<void> save(int id, String key, int generation, Uri expectedUrl);
  Future<void> drop(String key);
}

class MethodChannelBrowserNavigationPlatform extends BrowserNavigationPlatform {
  MethodChannelBrowserNavigationPlatform([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('dsh/islands');
  final MethodChannel _channel;

  Future<Object?> _call(String method, Map<String, Object> arguments) async {
    try {
      return await _channel.invokeMethod<Object>(method, arguments);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> restore(int id, String key, int generation, Uri expectedUrl) async =>
      await _call('browserNavigationRestore', {
        'id': id,
        'key': key,
        'generation': generation,
        'url': expectedUrl.toString(),
      }) ==
      true;

  @override
  Future<void> save(int id, String key, int generation, Uri expectedUrl) async {
    await _call('browserNavigationSave', {
      'id': id,
      'key': key,
      'generation': generation,
      'url': expectedUrl.toString(),
    });
  }

  @override
  Future<void> drop(String key) async {
    await _call('browserNavigationDrop', {'key': key});
  }
}

/// Process-local tab incarnations, bound by the workspace before UI creation.
/// Close/undo and scope deletion retire the old capability synchronously. A
/// controller created for a missing/closed tab cannot register it again.
/// History is best effort after memory eviction and is never cross-process.
class BrowserNavigation {
  BrowserNavigation({BrowserNavigationPlatform? platform})
    : _platform = platform ?? MethodChannelBrowserNavigationPlatform();

  static BrowserNavigation instance = BrowserNavigation();
  static const maxTabs = 80;
  static const maxEntryBytes = 1024 * 1024;
  static const maxTotalBytes = 16 * 1024 * 1024;
  final BrowserNavigationPlatform _platform;
  final _entries = <String, _NavigationEntry>{};

  void synchronize(Object owner, Iterable<BrowserTab> tabs) {
    final current = {for (final tab in tabs.take(maxTabs)) tab.id: tab};
    for (final entry in _entries.values.toList()) {
      if (identical(entry.owner, owner) && current[entry.id]?.scope != entry.scope) _retire(entry);
    }
    for (final tab in current.values) {
      final old = _entries[tab.id];
      if (old != null && identical(old.owner, owner) && old.scope == tab.scope) continue;
      if (old != null) _retire(old);
      if (_entries.length >= maxTabs) continue;
      final key = List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _entries[tab.id] = _NavigationEntry(owner, tab.id, tab.scope, key);
    }
  }

  void release(Object owner) {
    for (final entry in _entries.values.where((e) => identical(e.owner, owner)).toList()) {
      _retire(entry);
    }
  }

  /// A new address entered on Home cuts off its old forward branch, even when
  /// it happens to use the same URL. Resume-from-home deliberately keeps it.
  void reset(String tabId) {
    final entry = _entries[tabId];
    if (entry == null) return;
    _retire(entry);
  }

  BrowserNavigationLease? bind(String tabId) {
    final entry = _entries[tabId];
    return entry == null ? null : BrowserNavigationLease._(this, entry, ++entry.sequence);
  }

  void _retire(_NavigationEntry entry) {
    entry.retired = true;
    _entries.remove(entry.id);
    // Queue after any in-flight native restore/save. Even a close followed by
    // immediate undo cannot reuse this key, and no late save can resurrect it.
    unawaited(entry.enqueue(() => _platform.drop(entry.key)));
  }
}

class _NavigationEntry {
  _NavigationEntry(this.owner, this.id, this.scope, this.key);
  final Object owner;
  final String id;
  final BrowserScope scope;
  final String key;
  bool retired = false;
  int sequence = 0;
  int claimed = 0;
  Future<void> pending = Future.value();

  Future<void> enqueue(Future<void> Function() operation) {
    return pending = pending.then((_) => operation()).catchError((Object _) {
      // Missing plugins, process teardown and native failures degrade to the
      // persisted (sanitized) current URL, without poisoning the queue.
    });
  }
}

/// One ordinary browser controller. The auth controller never gets a lease.
class BrowserNavigationLease {
  BrowserNavigationLease._(this._navigation, this._entry, this._generation);
  final BrowserNavigation _navigation;
  final _NavigationEntry _entry;
  final int _generation;
  bool _invalid = false;
  bool _released = false;
  bool get current => !_invalid && !_entry.retired && _entry.claimed <= _generation;

  Future<bool> restore(int id, Uri expectedUrl, {required bool Function() isAlive}) async {
    var restored = false;
    await _entry.enqueue(() async {
      if (!current || !isAlive() || !BrowserPolicy.allows(expectedUrl)) return;
      _entry.claimed = _generation;
      restored = await _navigation._platform.restore(id, _entry.key, _generation, expectedUrl);
    });
    return restored && current && isAlive();
  }

  /// Call synchronously from dispose, before awaiting initialization. This
  /// reserves the queue slot so a replacement waits for save AND destruction.
  Future<void> release({
    required Future<void> initialized,
    required int? Function() identifier,
    required Uri expectedUrl,
    required bool save,
    required Future<void> Function() destroy,
  }) {
    if (_released) return Future.value();
    _released = true;
    return _entry.enqueue(() async {
      try {
        await initialized;
        final id = identifier();
        if (save && current && _entry.claimed == _generation && id != null && BrowserPolicy.allows(expectedUrl)) {
          await _navigation._platform.save(id, _entry.key, _generation, expectedUrl);
          // Renderer loss/close can arrive while Android waits for detach.
          // Purge before the next queued restore can consume that result.
          if (!current) await _navigation._platform.drop(_entry.key);
        }
      } finally {
        await destroy();
      }
    });
  }

  /// Renderer loss invalidates this view before its asynchronous disposal.
  void invalidate() {
    if (_invalid) return;
    _invalid = true;
    unawaited(
      _entry.enqueue(() async {
        if (!_entry.retired && _entry.claimed == _generation) await _navigation._platform.drop(_entry.key);
      }),
    );
  }
}
