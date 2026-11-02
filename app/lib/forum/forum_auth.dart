// Signing in to the forum with a Discourse User API Key, the mechanism the
// official DiscourseHub app uses.
//
// ```text
// signIn() ─► key pair (made once, kept in secure storage) + nonce
//          ─► temporary authorization page: <forum>/user-api-key/new?public_key=…&nonce=…
//               &auth_redirect=dshgo://forum/auth&scopes=…&padding=oaep
//             the user logs in (GitHub / LINUX DO / Gitee / e-mail) and approves
//          ─► dshgo://forum/auth?payload=<base64 RSA>   (lib/links router)
// handleRedirect() ─► decrypt, check the nonce, keep the key ─► /session/current.json
// signOut() ─► POST /user-api-key/revoke, forget the key
// ```
//
// The pending nonce is stored too: Android may kill the app while the browser
// is up, and the redirect then cold-starts it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../browser/browser_auth_controller.dart' show BrowserAuthPolicy;
import '../browser/browser_links.dart';
import '../remote/secret_store.dart' show SecretStore;
import '../state/account_state.dart' show EmbeddedAccountBrowser, accountBrowserProvider;
import '../l10n/l10n.dart';
import 'discourse_client.dart';
import 'forum_config.dart';
import 'forum_crypto.dart';
import 'forum_models.dart';
import 'forum_state.dart';

/// Android Keystore-backed storage for the forum's key pair and API key.
class SecureForumStore implements SecretStore {
  SecureForumStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _k(String key) => 'forum.$key';

  @override
  Future<String?> read(String key) => _storage.read(key: _k(key));

  @override
  Future<void> write(String key, String value) => _storage.write(key: _k(key), value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: _k(key));
}

final forumSecretStoreProvider = Provider<SecretStore>((ref) => SecureForumStore());

/// Makes (or, in tests, hands out) the install's RSA key pair.
final forumKeyPairFactoryProvider = Provider<Future<ForumKeyPair> Function()>((ref) => generateForumKeyPair);

enum ForumAuthPhase {
  /// Reading the stored key at startup.
  restoring,
  signedOut,

  /// The browser is open on the approval page.
  waiting,
  signedIn,
}

class ForumAuthState {
  const ForumAuthState({this.phase = ForumAuthPhase.restoring, this.credentials, this.user, this.error});

  final ForumAuthPhase phase;
  final ForumCredentials? credentials;

  /// Null right after sign-in until `/session/current.json` answers.
  final ForumCurrentUser? user;

  /// The last sign-in problem, one short line.
  final String? error;

  bool get signedIn => phase == ForumAuthPhase.signedIn && credentials != null;

  /// The number on the bell.
  int get unread => user?.allUnread ?? 0;

  ForumAuthState copyWith({
    ForumAuthPhase? phase,
    ForumCredentials? credentials,
    ForumCurrentUser? user,
    String? error,
    bool clearError = false,
  }) => ForumAuthState(
    phase: phase ?? this.phase,
    credentials: credentials ?? this.credentials,
    user: user ?? this.user,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Storage keys (namespaced `forum.` by [SecureForumStore]).
abstract final class _Keys {
  static const keyPair = 'rsa';
  static const clientId = 'client';
  static const pending = 'pending';
  static String session(String base) => 'session:$base';
}

class _ForumAuthorization {
  _ForumAuthorization(this.base, this.generation) : nonce = randomHex(16);

  final String base;
  final int generation;
  final String nonce;
  final completed = Completer<void>();
}

class _RetiredForumAuthorization implements Exception {
  const _RetiredForumAuthorization();
}

/// Serialize storage transactions even across provider rebuilds. Secure-store
/// writes cannot be cancelled; a retired commit is rolled back before a newer
/// operation can read or overwrite it. Keys themselves stay in secure storage.
class _ForumStoreQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

final _storeQueues = Expando<_ForumStoreQueue>();
_ForumStoreQueue _queue(SecretStore store) => _storeQueues[store] ??= _ForumStoreQueue();

class ForumAuthController extends Notifier<ForumAuthState> {
  late String _base;
  ForumKeyPair? _keys;
  int _generation = 0;
  // Explicit account actions also cancel native redirects waiting for initial
  // preferences. A provider rebuild while restoring the saved base does not.
  int _intentGeneration = 0;
  _ForumAuthorization? _authorization;
  Object? _redirectOperation;

  SecretStore get _store => ref.read(forumSecretStoreProvider);

  @override
  ForumAuthState build() {
    _base = ref.watch(forumBaseUrlProvider);
    final generation = ++_generation;
    _retireAuthorization();
    ref.onDispose(() {
      _generation++;
      _retireAuthorization();
      // Keep a persisted nonce: an OS redirect may cold-start the app.
    });
    unawaited(_restore(_base, generation, _store));
    return const ForumAuthState();
  }

  bool _current(int generation, String base) => ref.mounted && generation == _generation && base == _base;

  bool _owns(_ForumAuthorization authorization) =>
      _current(authorization.generation, authorization.base) &&
      identical(_authorization, authorization) &&
      !authorization.completed.isCompleted;

  void _retireAuthorization() {
    final authorization = _authorization;
    _authorization = null;
    _redirectOperation = null;
    if (authorization != null && !authorization.completed.isCompleted) authorization.completed.complete();
  }

  _ForumAuthorization _beginAuthorization() {
    _intentGeneration++;
    _generation++;
    _retireAuthorization();
    return _authorization = _ForumAuthorization(_base, _generation);
  }

  static void _requireCurrent(bool Function() current) {
    if (!current()) throw const _RetiredForumAuthorization();
  }

  Future<void> _restore(String base, int generation, SecretStore store) async {
    ForumCredentials? credentials;
    try {
      final raw = await _queue(store).run(() => store.read(_Keys.session(base)));
      final json = raw == null ? null : jsonDecode(raw);
      if (json is Map && json['key'] is String && json['client'] is String) {
        credentials = ForumCredentials(key: json['key'] as String, clientId: json['client'] as String);
      }
    } catch (_) {
      credentials = null;
    }
    if (!_current(generation, base) || state.phase != ForumAuthPhase.restoring) return;
    if (credentials == null) {
      state = const ForumAuthState(phase: ForumAuthPhase.signedOut);
      return;
    }
    state = ForumAuthState(phase: ForumAuthPhase.signedIn, credentials: credentials);
    unawaited(refreshUser());
  }

  ForumApi _api(ForumCredentials? credentials) => ref.read(forumApiFactoryProvider)(Uri.parse(_base), credentials);

  Future<ForumKeyPair> _keyPair(
    SecretStore store,
    Future<ForumKeyPair> Function() factory,
    bool Function() current,
  ) async {
    _requireCurrent(current);
    if (_keys case final keys?) return keys;
    try {
      final raw = await store.read(_Keys.keyPair);
      _requireCurrent(current);
      final keys = raw == null ? null : ForumKeyPair.fromJson(jsonDecode(raw));
      if (keys != null && keys.bits >= 2048) return _keys = keys;
    } on _RetiredForumAuthorization {
      rethrow;
    } catch (_) {
      // Unreadable: make a new pair.
    }
    _requireCurrent(current);
    final keys = await factory();
    _requireCurrent(current);
    await store.write(_Keys.keyPair, jsonEncode(keys.toJson()));
    _requireCurrent(current);
    return _keys = keys;
  }

  Future<String> _clientId(SecretStore store, bool Function() current) async {
    _requireCurrent(current);
    final stored = await store.read(_Keys.clientId);
    _requireCurrent(current);
    if (stored != null && stored.isNotEmpty) return stored;
    final id = randomHex(16);
    await store.write(_Keys.clientId, id);
    _requireCurrent(current);
    return id;
  }

  /// The approval page for a fresh nonce.
  Future<Uri> authorizeUrl() => _authorizeUrl(_beginAuthorization());

  Future<Uri> _authorizeUrl(_ForumAuthorization authorization) {
    final store = _store;
    final factory = ref.read(forumKeyPairFactoryProvider);
    bool current() => _owns(authorization);
    return _queue(store).run(() async {
      final keys = await _keyPair(store, factory, current);
      _requireCurrent(current);
      final clientId = await _clientId(store, current);
      _requireCurrent(current);
      await store.write(_Keys.pending, jsonEncode({'nonce': authorization.nonce, 'base': authorization.base}));
      if (!current()) {
        await _deletePending(store, authorization);
        throw const _RetiredForumAuthorization();
      }
      final base = Uri.parse(authorization.base);
      final path = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
      return base.replace(
        path: '$path/user-api-key/new',
        queryParameters: {
          'application_name': forumApplicationName,
          'client_id': clientId,
          'scopes': forumScopes.join(','),
          'public_key': keys.publicPem,
          'nonce': authorization.nonce,
          'auth_redirect': forumAuthRedirect,
          'padding': 'oaep',
        },
      );
    });
  }

  /// Opens an isolated authorization surface. False when no browser opened.
  Future<bool> signIn() async {
    final authorization = _beginAuthorization();
    state = state.copyWith(phase: ForumAuthPhase.waiting, clearError: true);
    try {
      final url = await _authorizeUrl(authorization);
      if (!_owns(authorization)) return false;
      final browser = ref.read(accountBrowserProvider);
      final opened = browser is EmbeddedAccountBrowser
          ? await browser.authorize(
              BrowserAuthorization(
                id: authorization,
                url: url,
                completed: authorization.completed.future,
                isCurrent: () => _owns(authorization),
                cancel: () async {
                  if (_owns(authorization)) cancel();
                },
                onForumRedirect: (uri) =>
                    _owns(authorization) ? _handleRedirect(uri, authorization: authorization) : Future.value(false),
              ),
            )
          : await browser.open(url);
      if (!_owns(authorization)) return false;
      if (opened) return true;
      _retireAuthorization();
      state = state.copyWith(phase: ForumAuthPhase.signedOut, error: appL10n.stateBrowserOpenFailed);
    } on _RetiredForumAuthorization {
      return false;
    } catch (_) {
      if (_owns(authorization)) {
        _retireAuthorization();
        state = state.copyWith(phase: ForumAuthPhase.signedOut, error: appL10n.stateSignInStartFailed);
      }
    }
    return false;
  }

  /// Back from the browser without a key.
  void cancel() {
    final authorization = _authorization;
    final store = _store;
    _intentGeneration++;
    _generation++;
    _retireAuthorization();
    if (authorization != null) {
      unawaited(_queue(store).run(() => _deletePending(store, authorization)).catchError((Object _) {}));
    }
    if (state.phase == ForumAuthPhase.waiting) {
      state = state.copyWith(phase: ForumAuthPhase.signedOut, clearError: true);
    }
  }

  static Future<void> _deletePending(SecretStore store, _ForumAuthorization authorization) async {
    final raw = await store.read(_Keys.pending);
    final pending = raw == null ? null : jsonDecode(raw);
    if (pending is Map && pending['nonce'] == authorization.nonce && pending['base'] == authorization.base) {
      await store.delete(_Keys.pending);
    }
  }

  /// `dshgo://forum/auth?payload=…`. True when it signed the user in.
  /// No in-memory attempt is required after a cold start: the encrypted nonce
  /// must still match the pending record in secure storage.
  Future<bool> handleRedirect(Uri uri) async {
    final authorization = _authorization;
    if (authorization != null) return _handleRedirect(uri, authorization: authorization);
    if (!ref.mounted || BrowserAuthPolicy.parseForumCallback(uri.toString()) == null) return false;
    final container = ref.container;
    final intent = _intentGeneration;
    try {
      // ForumBaseUrlController started reading this same preferences future
      // during build. Settle its initial address before binding a cold redirect.
      await SharedPreferences.getInstance();
      // The first getInstance caller unwraps an extra future. Let its _load
      // continuation run before reading the dependent notifier again.
      await Future<void>.delayed(Duration.zero);
    } catch (_) {
      // As in ForumBaseUrlController, unavailable preferences keep the default.
    }
    try {
      // Flush a pending dependency rebuild; the old ref is already unmounted
      // during invalidation. A disposed container must not be used again.
      if (!identical(container.read(forumAuthProvider.notifier), this)) return false;
    } catch (_) {
      return false;
    }
    if (!ref.mounted || intent != _intentGeneration || _authorization != null) {
      return false;
    }
    return _handleRedirect(uri);
  }

  Future<bool> _handleRedirect(Uri uri, {_ForumAuthorization? authorization}) async {
    if (!ref.mounted || BrowserAuthPolicy.parseForumCallback(uri.toString()) == null || _redirectOperation != null) {
      return false;
    }
    final store = _store;
    final factory = ref.read(forumKeyPairFactoryProvider);
    final generation = _generation;
    final activeBase = _base;
    final operation = _redirectOperation = Object();
    bool current() =>
        _current(generation, activeBase) &&
        identical(_redirectOperation, operation) &&
        (authorization == null || _owns(authorization));
    try {
      return await _queue(store).run(() async {
        _requireCurrent(current);
        final pendingRaw = await store.read(_Keys.pending);
        _requireCurrent(current);
        final pending = pendingRaw == null ? null : jsonDecode(pendingRaw);
        if (pending is! Map || pending['nonce'] is! String || (pending['nonce'] as String).isEmpty) {
          throw const FormatException('no sign-in in progress');
        }
        final base = pending['base'] is String ? pending['base'] as String : activeBase;
        if (authorization != null && (pending['nonce'] != authorization.nonce || base != authorization.base)) {
          throw const _RetiredForumAuthorization();
        }
        final keys = await _keyPair(store, factory, current);
        _requireCurrent(current);
        final json = jsonDecode(utf8.decode(decryptForumPayload(uri.queryParameters['payload']!, keys)));
        if (json is! Map || json['key'] is! String || (json['key'] as String).isEmpty) {
          throw const FormatException('no key in payload');
        }
        if (json['nonce'] != pending['nonce']) throw const FormatException('nonce mismatch');
        final clientId = await _clientId(store, current);
        _requireCurrent(current);
        final credentials = ForumCredentials(key: json['key'] as String, clientId: clientId);
        final sessionKey = _Keys.session(base);
        final previous = await store.read(sessionKey);
        _requireCurrent(current);
        var pendingDeleted = false;
        try {
          await store.write(sessionKey, jsonEncode({'key': credentials.key, 'client': credentials.clientId}));
          _requireCurrent(current);
          pendingDeleted = true;
          await store.delete(_Keys.pending);
          _requireCurrent(current);
        } catch (_) {
          // Storage calls already in flight cannot be cancelled. Undo this
          // transaction while the queue still excludes a successor's writes.
          if (previous == null) {
            await store.delete(sessionKey);
          } else {
            await store.write(sessionKey, previous);
          }
          if (pendingDeleted) await store.write(_Keys.pending, pendingRaw!);
          rethrow;
        }
        _retireAuthorization();
        if (base == _base) {
          state = ForumAuthState(phase: ForumAuthPhase.signedIn, credentials: credentials);
          unawaited(refreshUser());
        }
        return true;
      });
    } on _RetiredForumAuthorization {
      return false;
    } catch (_) {
      if (current() && !state.signedIn) state = state.copyWith(error: appL10n.stateSignInIncompleteRetry);
      return false;
    } finally {
      if (identical(_redirectOperation, operation)) _redirectOperation = null;
    }
  }

  /// Re-reads the signed-in user (unread counts). A dead key signs out.
  Future<void> refreshUser() async {
    final credentials = state.credentials;
    if (credentials == null || !state.signedIn) return;
    final generation = _generation;
    final base = _base;
    bool current() => _current(generation, base) && identical(state.credentials, credentials) && state.signedIn;
    try {
      final user = await _api(credentials).currentUser();
      if (current()) state = state.copyWith(user: user);
    } on ForumException catch (e) {
      if (current() &&
          (e.kind == ForumErrorKind.unauthorized ||
              e.kind == ForumErrorKind.forbidden ||
              e.kind == ForumErrorKind.notFound)) {
        await expire();
      }
    } catch (_) {
      // A failed profile read does not invalidate a committed API key.
    }
  }

  /// The badge after reading notifications here.
  void setUnread(int count) {
    final user = state.user;
    if (user != null) state = state.copyWith(user: user.copyWith(allUnread: count < 0 ? 0 : count));
  }

  /// The key stopped working (revoked on the web, expired): forget it.
  Future<void> expire() async {
    final store = _store;
    final base = _base;
    _intentGeneration++;
    final generation = ++_generation;
    _retireAuthorization();
    await _queue(store).run(() async {
      if (_current(generation, base)) await store.delete(_Keys.session(base));
    });
    if (_current(generation, base)) {
      state = ForumAuthState(phase: ForumAuthPhase.signedOut, error: appL10n.stateSignInExpired);
    }
  }

  /// Revokes the key on the forum (best effort) and forgets it.
  Future<void> signOut() async {
    final credentials = state.credentials;
    final api = credentials == null ? null : _api(credentials);
    final authorization = _authorization;
    final store = _store;
    final base = _base;
    _intentGeneration++;
    final generation = ++_generation;
    _retireAuthorization();
    state = const ForumAuthState(phase: ForumAuthPhase.signedOut);
    await _queue(store).run(() async {
      if (!_current(generation, base)) return;
      await store.delete(_Keys.session(base));
      if (authorization != null) await _deletePending(store, authorization);
    });
    if (api != null) {
      try {
        await api.revokeKey();
      } catch (_) {
        // Offline or already revoked: the key is gone from the phone either way.
      }
    }
  }
}

final forumAuthProvider = NotifierProvider<ForumAuthController, ForumAuthState>(ForumAuthController.new);
