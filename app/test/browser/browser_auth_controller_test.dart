// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/browser/browser_auth_controller.dart';
import 'package:dsh_app/browser/browser_links.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../web/support/fake_webview.dart';

class AuthWebPlatform extends FakeWebViewPlatform {
  @override
  AuthWebController get controller => controllers.single as AuthWebController;

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = AuthWebController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      AuthNavigationDelegate(params);
}

class AuthWebController extends FakeWebViewController {
  AuthWebController(super.params);
  void Function(PlatformWebViewPermissionRequest)? permission;
  final modes = <JavaScriptMode>[];
  final userAgents = <String?>[];
  Completer<void>? loadGate;
  AuthNavigationDelegate get navigation => delegate! as AuthNavigationDelegate;

  @override
  Future<void> setOnPlatformPermissionRequest(void Function(PlatformWebViewPermissionRequest) callback) async =>
      permission = callback;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async => modes.add(mode);
  @override
  Future<void> setUserAgent(String? userAgent) async => userAgents.add(userAgent);
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    await super.loadRequest(params);
    await loadGate?.future;
  }
}

class AuthNavigationDelegate extends FakeNavigationDelegate {
  AuthNavigationDelegate(super.params);
  NavigationRequestCallback? navigation;
  UrlChangeCallback? urlChange;
  ProgressCallback? progress;
  HttpAuthRequestCallback? httpAuth;
  SslAuthErrorCallback? sslAuth;
  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback callback) async => navigation = callback;
  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async => urlChange = callback;
  @override
  Future<void> setOnProgress(ProgressCallback callback) async => progress = callback;
  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback callback) async => httpAuth = callback;
  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback callback) async => sslAuth = callback;
}

class AuthPermission extends PlatformWebViewPermissionRequest {
  AuthPermission(this.record) : super(types: {WebViewPermissionResourceType.camera});
  final List<String> record;
  @override
  Future<void> deny() async => record.add('deny');
  @override
  Future<void> grant() async => record.add('grant');
}

class AuthSslError extends PlatformSslAuthError {
  AuthSslError() : super(certificate: null, description: 'sensitive error');
  bool cancelled = false;
  bool proceeded = false;
  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Future<void> proceed() async => proceeded = true;
}

class AuthGuardPlatform extends FakeIslandPlatform {
  final attaching = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> attach(int webViewId, {required bool dark, required int textZoom}) async {
    attaching.complete();
    await release.future;
    return super.attach(webViewId, dark: dark, textZoom: textZoom);
  }
}

class CallbackHeaders implements HttpHeaders {
  final removed = <String>[];
  @override
  void removeAll(String name) => removed.add(name);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CallbackResponse implements HttpClientResponse {
  CallbackResponse({this.statusCode = 200});
  @override
  final int statusCode;
  bool drained = false;
  Completer<void>? drainGate;
  @override
  Future<T> drain<T>([T? futureValue]) async {
    drained = true;
    await drainGate?.future;
    return futureValue as T;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CallbackRequest implements HttpClientRequest {
  final response = CallbackResponse();
  @override
  final CallbackHeaders headers = CallbackHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  bool sent = false;
  bool aborted = false;
  Future<HttpClientResponse>? responseFuture;
  @override
  Future<HttpClientResponse> close() async {
    sent = true;
    return await (responseFuture ?? Future.value(response));
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CallbackClient implements HttpClient {
  final outgoing = CallbackRequest();
  final urls = <Uri>[];
  final closures = <bool>[];
  Completer<HttpClientRequest>? opening;
  @override
  Duration? connectionTimeout;
  @override
  String Function(Uri)? findProxy;
  @override
  Future<bool> Function(Uri, String, String?)? authenticate;
  @override
  Future<bool> Function(String, int, String, String?)? authenticateProxy;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return await (opening?.future ?? Future.value(outgoing));
  }

  @override
  void close({bool force = false}) => closures.add(force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AuthWebPlatform web;
  late FakeIslandPlatform islands;
  late IslandPlatform savedIslands;
  late WebViewPlatform? savedWeb;
  late Completer<void> completed;
  late bool current;
  late List<CallbackClient> clients;
  late List<Uri> external;
  late List<BrowserAuthController> controllers;
  final authorize = Uri.parse('https://platform.deepseek.com/authorize?authorize_id=engine-only');
  const rawCallback = 'http://127.0.0.1:3080/oauth/callback?code=secret-code&state=secret-state';

  BrowserAuthorization request({Uri? origin, Uri? url, Future<bool> Function(Uri)? forumRedirect}) =>
      BrowserAuthorization(
        id: Object(),
        url: url ?? authorize,
        callbackOrigin: origin ?? Uri.parse('http://127.0.0.1:3080'),
        completed: completed.future,
        isCurrent: () => current,
        cancel: () async => fail('the controller must not cancel its owner'),
        onForumRedirect: forumRedirect,
      );

  BrowserAuthController make({
    BrowserAuthorization? auth,
    HttpClient Function()? factory,
    BrowserLinkHandler? opener,
    Duration timeout = const Duration(seconds: 15),
  }) {
    final controller = BrowserAuthController(
      auth ?? request(),
      createHttpClient:
          factory ??
          () {
            final client = CallbackClient();
            clients.add(client);
            return client;
          },
      externalOpen:
          opener ??
          (url) async {
            external.add(url);
            return true;
          },
      callbackTimeout: timeout,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  Future<NavigationDecision> navigate(String url, {bool main = true}) async =>
      await web.controller.navigation.navigation!(NavigationRequest(url: url, isMainFrame: main));

  setUp(() {
    savedWeb = WebViewPlatform.instance;
    WebViewPlatform.instance = web = AuthWebPlatform();
    savedIslands = IslandPlatform.instance;
    IslandPlatform.instance = islands = FakeIslandPlatform();
    completed = Completer<void>();
    current = true;
    clients = [];
    external = [];
    controllers = [];
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    if (!completed.isCompleted) completed.complete();
    await settle();
    IslandPlatform.instance = savedIslands;
    if (savedWeb != null) WebViewPlatform.instance = savedWeb;
  });

  test('initializes once with guard, original UA, no channels or browser reads', () async {
    final controller = make();
    await controller.initialize(dark: true);
    await controller.initialize(dark: false);
    expect(web.controller.loads, [authorize]);
    expect(web.controller.channels, isEmpty);
    expect(web.controller.scripts, isEmpty);
    expect(web.controller.userAgents, isEmpty);
    expect(web.controller.calls, ['setNavigationDelegate', 'loadRequest']);
    expect(islands.attached, [(id: web.controller.webViewIdentifier, dark: true, textZoom: 100)]);
    expect(controller.loading, isTrue);
    web.controller.start();
    web.controller.navigation.progress!(40);
    expect(controller.progress, 40);
    web.controller.finish();
    expect(controller.loading, isFalse);
    expect(controller.progress, 100);
    expect(controller.error, isNull);
  });

  test('permission, HTTP auth, and SSL requests are always denied', () async {
    final controller = make();
    await controller.initialize(dark: false);
    final permissions = <String>[];
    web.controller.permission!(AuthPermission(permissions));
    var cancelled = false;
    web.controller.navigation.httpAuth!(
      HttpAuthRequest(
        onProceed: (_) => fail('HTTP credentials must not be supplied'),
        onCancel: () => cancelled = true,
        host: 'example.com',
      ),
    );
    final ssl = AuthSslError();
    web.controller.navigation.sslAuth!(ssl);
    await settle();
    expect(permissions, ['deny']);
    expect(cancelled, isTrue);
    expect(ssl.cancelled, isTrue);
    expect(ssl.proceeded, isFalse);
  });

  test('public HTTPS navigation works; downgrades and local/non-web targets are blocked', () async {
    final controller = make();
    await controller.initialize(dark: false);
    final next = Uri.parse('https://accounts.example.com/login');
    expect(await navigate(next.toString()), NavigationDecision.navigate);
    expect(controller.currentUrl, next);
    for (final target in ['http://example.com/', 'https://127.0.0.1/', 'file:///token', 'intent://login']) {
      expect(await navigate(target), NavigationDecision.prevent);
      expect(controller.error, 'blocked_url');
      expect(controller.currentUrl, next);
    }
    expect(clients, isEmpty);
  });

  test('main-frame callback is intercepted and delivered once without credentials or redirects', () async {
    final controller = make();
    await controller.initialize(dark: false);
    expect(await navigate(rawCallback, main: false), NavigationDecision.prevent);
    expect(clients, isEmpty);
    expect(await navigate(rawCallback), NavigationDecision.prevent);
    await settle();
    expect(controller.finishing, isTrue);
    expect(controller.currentUrl, authorize);
    expect(web.controller.loads, [authorize]);
    final client = clients.single;
    expect(client.urls, [Uri.parse(rawCallback)]);
    expect(client.findProxy!(authorize), 'DIRECT');
    expect(await client.authenticate!(authorize, 'basic', null), isFalse);
    expect(await client.authenticateProxy!('proxy', 80, 'basic', null), isFalse);
    expect(client.connectionTimeout, const Duration(seconds: 15));
    expect(client.outgoing.followRedirects, isFalse);
    expect(client.outgoing.maxRedirects, 0);
    expect(client.outgoing.persistentConnection, isFalse);
    expect(client.outgoing.headers.removed, containsAll(['authorization', 'proxy-authorization', 'cookie']));
    expect(client.outgoing.response.drained, isTrue);
    expect(client.closures, [true]);
    expect(await navigate(rawCallback), NavigationDecision.prevent);
    expect(clients, hasLength(1));
    expect(web.controller.scripts, isEmpty);
  });

  test('callback and all navigation are blocked while delivery is in progress', () async {
    final response = Completer<HttpClientResponse>();
    final client = CallbackClient()..outgoing.responseFuture = response.future;
    final controller = make(factory: () => client);
    await controller.initialize(dark: false);
    await navigate(rawCallback);
    await navigate(rawCallback);
    expect(await navigate('https://example.com/'), NavigationDecision.prevent);
    await controller.reload();
    expect(client.urls, hasLength(1));
    expect(web.controller.loads, [authorize]);
    response.complete(client.outgoing.response);
    await settle();
    expect(controller.finishing, isTrue);
  });

  test('callback failure is sanitized and a later callback can retry', () async {
    final response = Completer<HttpClientResponse>();
    final first = CallbackClient()..outgoing.responseFuture = response.future;
    var calls = 0;
    final controller = make(factory: () => calls++ == 0 ? first : CallbackClient());
    await controller.initialize(dark: false);
    await navigate(rawCallback);
    response.completeError(StateError(rawCallback));
    await settle();
    expect(controller.finishing, isFalse);
    expect(controller.error, 'callback_failed');
    expect(controller.error, isNot(contains('secret')));
    await navigate(rawCallback);
    await settle();
    expect(calls, 2);
    expect(controller.finishing, isTrue);
    expect(controller.error, isNull);
  });

  test('an engine rejection is drained and leaves callback retry available', () async {
    final response = CallbackResponse(statusCode: 400);
    final client = CallbackClient()..outgoing.responseFuture = Future.value(response);
    final controller = make(factory: () => client);
    await controller.initialize(dark: false);
    await navigate(rawCallback);
    await settle();
    expect(response.drained, isTrue);
    expect(controller.error, 'callback_failed');
    expect(controller.finishing, isFalse);
  });

  test('timeout covers response draining, closes the socket, and permits retry', () async {
    final client = CallbackClient();
    final gate = Completer<void>();
    client.outgoing.response.drainGate = gate;
    final controller = make(factory: () => client, timeout: const Duration(milliseconds: 20));
    await controller.initialize(dark: false);
    await navigate(rawCallback);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.error, 'callback_timeout');
    expect(controller.finishing, isFalse);
    expect(client.closures, contains(true));
    gate.complete();
    await settle();
    expect(controller.error, 'callback_timeout');
  });

  for (final end in ['stale', 'complete', 'dispose']) {
    test('$end during opening aborts the request before GET is sent', () async {
      final client = CallbackClient()..opening = Completer<HttpClientRequest>();
      final controller = make(factory: () => client);
      await controller.initialize(dark: false);
      await navigate(rawCallback);
      switch (end) {
        case 'stale':
          current = false;
        case 'complete':
          completed.complete();
        case 'dispose':
          controller.dispose();
      }
      await settle();
      client.opening!.complete(client.outgoing);
      await settle();
      expect(client.outgoing.sent, isFalse);
      expect(client.outgoing.aborted, isTrue);
      expect(client.closures, contains(true));
    });
  }

  test('timeout while opening cannot send a late request', () async {
    final client = CallbackClient()..opening = Completer<HttpClientRequest>();
    final controller = make(factory: () => client, timeout: const Duration(milliseconds: 20));
    await controller.initialize(dark: false);
    await navigate(rawCallback);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    client.opening!.complete(client.outgoing);
    await settle();
    expect(client.outgoing.aborted, isTrue);
    expect(client.outgoing.sent, isFalse);
    expect(controller.error, 'callback_timeout');
  });

  test('completion stops activity without destroying a mounted view', () async {
    final controller = make();
    await controller.initialize(dark: false);
    await navigate(rawCallback);
    completed.complete();
    await settle();
    expect(controller.finishing, isFalse);
    expect(controller.loading, isFalse);
    expect(web.controller.scripts, ['window.stop();']);
    expect(web.controller.modes.last, JavaScriptMode.disabled);
    expect(islands.destroyed, isEmpty);
    final loads = web.controller.loads.length;
    await controller.reload();
    expect(await controller.openExternal(), isFalse);
    expect(await navigate(rawCallback), NavigationDecision.prevent);
    web.controller.start();
    web.controller.finish();
    web.controller.fail();
    expect(web.controller.loads, hasLength(loads));
    expect(controller.error, isNull);
  });

  test('failed completion does not expose the underlying error', () async {
    final controller = make();
    await controller.initialize(dark: false);
    completed.completeError(StateError(rawCallback));
    await settle();
    expect(controller.error, 'authorization_failed');
    expect(controller.loading, isFalse);
  });

  test('stale authorization cannot initialize, navigate, reload, or launch externally', () async {
    final controller = make();
    current = false;
    await controller.initialize(dark: false);
    await controller.reload();
    expect(await controller.openExternal(), isFalse);
    expect(web.controller.loads, isEmpty);
    expect(external, isEmpty);
    expect(controller.loading, isFalse);
  });

  test('external fallback and reload always use the original authorization URL', () async {
    final controller = make();
    await controller.initialize(dark: false);
    await navigate('https://example.com/token?access_token=private');
    expect(await controller.openExternal(), isTrue);
    expect(external, [authorize]);
    await controller.reload();
    expect(web.controller.loads, [authorize, authorize]);
    expect(controller.currentUrl, authorize);
    web.controller.finish();
    expect(controller.loading, isTrue);
    web.controller.start();
    web.controller.finish();
    expect(controller.loading, isFalse);
    await navigate(rawCallback);
    expect(await controller.openExternal(), isTrue);
    expect(external, [authorize, authorize]);
  });

  test('external launch returning after disposal is ignored', () async {
    final launch = Completer<bool>();
    final controller = make(opener: (_) => launch.future);
    final opened = controller.openExternal();
    controller.dispose();
    launch.complete(true);
    expect(await opened, isFalse);
  });

  test('dispose before initialize destroys once without guard attachment', () async {
    final controller = make();
    controller.dispose();
    controller.dispose();
    await controller.initialize(dark: false);
    await settle();
    expect(islands.destroyed, [web.controller.webViewIdentifier]);
    expect(islands.attached, isEmpty);
    expect(web.controller.loads, isEmpty);
  });

  test('dispose waits for pending guard attachment before native destruction', () async {
    final guard = AuthGuardPlatform();
    IslandPlatform.instance = guard;
    final controller = make();
    final init = controller.initialize(dark: false);
    await guard.attaching.future;
    controller.dispose();
    expect(guard.destroyed, isEmpty);
    guard.release.complete();
    await init;
    await settle();
    expect(guard.destroyed, [web.controller.webViewIdentifier]);
    expect(web.controller.loads, isEmpty);
  });

  test('completion during guard attachment prevents the first load', () async {
    final guard = AuthGuardPlatform();
    IslandPlatform.instance = guard;
    final controller = make();
    final init = controller.initialize(dark: false);
    await guard.attaching.future;
    completed.complete();
    await settle();
    guard.release.complete();
    await init;
    expect(web.controller.loads, isEmpty);
    expect(guard.destroyed, isEmpty);
  });

  test('renderer loss ends callback activity; system fallback remains available', () async {
    final client = CallbackClient()..opening = Completer<HttpClientRequest>();
    final controller = make(factory: () => client);
    await controller.initialize(dark: false);
    await navigate(rawCallback);
    islands.gone();
    await settle();
    client.opening!.complete(client.outgoing);
    await settle();
    web.controller.start();
    web.controller.finish();
    await controller.reload();
    expect(controller.error, 'renderer_gone');
    expect(controller.loading, isFalse);
    expect(controller.finishing, isFalse);
    expect(client.outgoing.sent, isFalse);
    expect(web.controller.loads, [authorize]);
    expect(await controller.openExternal(), isTrue);
  });

  test('a stale load failure cannot replace a newer navigation state', () async {
    final controller = make();
    final gate = Completer<void>();
    web.controller.loadGate = gate;
    final init = controller.initialize(dark: false);
    await settle();
    final next = Uri.parse('https://accounts.example.com/login');
    await navigate(next.toString());
    gate.completeError(StateError('old error'));
    await init;
    expect(controller.currentUrl, next);
    expect(controller.error, isNull);
  });

  test('real HTTP callback sends no credentials, drains HTML and never follows a redirect', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = <HttpRequest>[];
    server.listen((incoming) async {
      received.add(incoming);
      incoming.response.statusCode = 302;
      incoming.response.headers.set(HttpHeaders.locationHeader, '/must-not-load');
      incoming.response.write('<script>location.href="/must-not-execute"</script>');
      await incoming.response.close();
    });
    final controller = make(
      auth: request(origin: Uri.parse('http://127.0.0.1:${server.port}')),
      factory: HttpClient.new,
    );
    await controller.initialize(dark: false);
    await navigate('http://127.0.0.1:${server.port}/oauth/callback?code=secret-code&state=secret-state');
    // Bound the asynchronous socket exchange without depending on fixed timing.
    for (var i = 0; i < 100 && received.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(received, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(received, hasLength(1));
    expect(received.single.method, 'GET');
    expect(received.single.uri.path, '/oauth/callback');
    expect(received.single.headers.value(HttpHeaders.authorizationHeader), isNull);
    expect(received.single.headers.value(HttpHeaders.proxyAuthorizationHeader), isNull);
    expect(received.single.headers.value(HttpHeaders.cookieHeader), isNull);
    expect(controller.finishing, isTrue);
    expect(controller.error, isNull);
    expect(web.controller.loads, [authorize]);
    expect(web.controller.scripts, isEmpty);
  });

  test('forum redirect is capability scoped, intercepted once, and waits for producer completion', () async {
    final received = <Uri>[];
    final result = Completer<bool>();
    final controller = make(
      auth: request(
        forumRedirect: (uri) {
          received.add(uri);
          return result.future;
        },
      ),
    );
    await controller.initialize(dark: false);
    const raw = 'dshgo://forum/auth?payload=encrypted-private';
    expect(await navigate(raw, main: false), NavigationDecision.prevent);
    expect(received, isEmpty);
    expect(await navigate(raw), NavigationDecision.prevent);
    expect(controller.finishing, isTrue);
    await navigate(raw);
    await navigate(rawCallback);
    expect(received, [Uri.parse(raw)]);
    result.complete(true);
    await settle();
    expect(controller.finishing, isTrue, reason: 'handler acceptance alone does not finish the login');
    expect(controller.currentUrl, authorize);
    expect(web.controller.loads, [authorize]);
    expect(clients, isEmpty);
    expect(external, isEmpty);
    completed.complete();
    await settle();
    expect(controller.finishing, isFalse);
  });

  test('forum redirect without a forum producer never launches or loads', () async {
    final controller = make();
    await controller.initialize(dark: false);
    expect(await navigate('dshgo://forum/auth?payload=private'), NavigationDecision.prevent);
    expect(controller.error, 'blocked_url');
    expect(controller.finishing, isFalse);
    expect(web.controller.loads, [authorize]);
    expect(clients, isEmpty);
    expect(external, isEmpty);
  });

  for (final throwsError in [false, true]) {
    test('forum failure is sanitized and permits retry (throws: $throwsError)', () async {
      var calls = 0;
      final controller = make(
        auth: request(
          forumRedirect: (_) async {
            calls++;
            if (calls > 1) return true;
            if (throwsError) throw StateError('private payload and key');
            return false;
          },
        ),
      );
      await controller.initialize(dark: false);
      await navigate('dshgo://forum/auth?payload=private');
      await settle();
      expect(controller.error, 'callback_failed');
      expect(controller.finishing, isFalse);
      await navigate('dshgo://forum/auth?payload=retry');
      await settle();
      expect(calls, 2);
      expect(controller.error, isNull);
      expect(controller.finishing, isTrue);
    });
  }

  test('forum timeout and a late failure cannot disturb a successful retry', () async {
    final first = Completer<bool>();
    var calls = 0;
    final controller = make(
      auth: request(forumRedirect: (_) => calls++ == 0 ? first.future : Future.value(true)),
      timeout: const Duration(milliseconds: 20),
    );
    await controller.initialize(dark: false);
    await navigate('dshgo://forum/auth?payload=first');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.error, 'callback_timeout');
    expect(controller.finishing, isFalse);
    await navigate('dshgo://forum/auth?payload=second');
    await settle();
    first.completeError(StateError('old private error'));
    await settle();
    expect(calls, 2);
    expect(controller.error, isNull);
    expect(controller.finishing, isTrue);
  });

  for (final end in ['complete', 'stale', 'dispose', 'renderer']) {
    test('forum handler returning after $end cannot revive authorization', () async {
      final result = Completer<bool>();
      final controller = make(auth: request(forumRedirect: (_) => result.future));
      await controller.initialize(dark: false);
      await navigate('dshgo://forum/auth?payload=private');
      switch (end) {
        case 'complete':
          completed.complete();
        case 'stale':
          current = false;
        case 'dispose':
          controller.dispose();
        case 'renderer':
          islands.gone();
      }
      await settle();
      result.completeError(StateError('late private payload'));
      await settle();
      expect(controller.error, end == 'renderer' ? 'renderer_gone' : isNull);
      expect(await navigate('dshgo://forum/auth?payload=late'), NavigationDecision.prevent);
      expect(clients, isEmpty);
      expect(external, isEmpty);
    });
  }
}
