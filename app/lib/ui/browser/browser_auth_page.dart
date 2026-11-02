// 登录页: a short-lived authorization WebView (docs/design/browser-motion-
// refresh.md, last section). It shows only the real host it is on (never the
// authorize query, code or state), how loading goes, close, retry and an
// explicit 在系统浏览器中打开. No bookmarks, history, quotes, share, tabs or
// snapshots. BrowserAuthController hands the callback to the engine; the root
// router removes this page when the request completes, and closing it is the
// router's cue to cancel. The user agent is the system WebView's own.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../browser/browser_auth_controller.dart';
import '../../browser/browser_links.dart';
import '../../l10n/l10n.dart';
import '../common/empty_view.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'browser_chrome.dart';

class BrowserAuthPage extends StatefulWidget {
  const BrowserAuthPage({super.key, required this.request, required this.onSystemBrowserOpened});

  final BrowserAuthorization request;

  /// The system browser took the request over (the page stays the router's).
  final VoidCallback onSystemBrowserOpened;

  /// Tests swap the controller and the platform view.
  @visibleForTesting
  static BrowserAuthController Function(BrowserAuthorization request) debugController = BrowserAuthController.new;
  @visibleForTesting
  static Widget Function(BrowserAuthController controller) debugView = _platformView;

  static Widget _platformView(BrowserAuthController controller) => WebViewWidget(controller: controller.webView);

  @override
  State<BrowserAuthPage> createState() => _BrowserAuthPageState();
}

class _BrowserAuthPageState extends State<BrowserAuthPage> {
  BrowserAuthController? _controller;

  /// The view of the controller in use; a new key for a rebuilt one.
  int _generation = 0;
  bool _opening = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = _make();
  }

  BrowserAuthController? _make() {
    try {
      return BrowserAuthPage.debugController(widget.request)..addListener(_changed);
    } on FormatException {
      return null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _initialize();
  }

  void _initialize() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    unawaited(_controller?.initialize(dark: dark).catchError((Object _) {}));
  }

  void _changed() {
    if (!mounted) return;
    final controller = _controller;
    if (controller?.error == 'external_open_failed') _toast(context.l10n.browserAuthExternalFailed);
    setState(() {});
  }

  /// [controller] leaves the tree this frame and is destroyed after it.
  void _retire(BrowserAuthController controller) {
    controller.removeListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    if (controller != null) _retire(controller);
    super.dispose();
  }

  bool get _rendererGone => _controller?.error == 'renderer_gone';

  Future<void> _retry() async {
    final controller = _controller;
    if (controller == null) return;
    if (_rendererGone) {
      // The old view is gone: a fresh controller for the same request.
      if (!widget.request.isCurrent()) return;
      _retire(controller);
      setState(() {
        _generation++;
        _controller = _make();
      });
      _initialize();
      return;
    }
    await controller.reload();
  }

  Future<void> _openSystem() async {
    final controller = _controller;
    if (_opening) return;
    setState(() => _opening = true);
    var opened = false;
    try {
      opened = controller != null ? await controller.openExternal() : await BrowserLinks.external(widget.request.url);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    setState(() => _opening = false);
    if (opened) {
      widget.onSystemBrowserOpened();
    } else if (controller == null) {
      _toast(context.l10n.browserAuthExternalFailed);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final controller = _controller;
    final error = controller == null ? 'blocked_url' : controller.error;
    final finishing = controller?.finishing ?? false;
    final loading = controller != null && controller.loading && error == null && !finishing;
    final host = (controller?.currentUrl ?? widget.request.url).host;
    final showView = controller != null && !_rendererGone;

    String? problem;
    switch (error) {
      case null || 'external_open_failed':
        problem = null;
      case 'blocked_url':
        problem = l10n.browserAuthBlocked;
      case 'callback_failed' || 'callback_timeout':
        problem = l10n.browserAuthCallbackFailed;
      case 'authorization_failed':
        problem = l10n.browserAuthFailed;
      case 'renderer_gone':
        problem = l10n.webPageClosed;
      default:
        problem = l10n.browserLoadFailed;
    }
    final canRetry = controller != null && error != 'authorization_failed' && error != 'blocked_url';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        glow: false,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Padding(
            padding: EdgeInsets.only(top: media.padding.top),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    BrowserChrome.edge + media.padding.left,
                    4,
                    BrowserChrome.edge + media.padding.right,
                    8,
                  ),
                  child: SizedBox(
                    height: BrowserChrome.bar,
                    child: Row(
                      children: [
                        GlassIconButton(
                          key: const ValueKey('browser-auth-close'),
                          icon: AppIcons.close,
                          tooltip: l10n.commonClose,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: _Host(host: host)),
                        const SizedBox(width: 8),
                        GlassIconButton(
                          key: const ValueKey('browser-auth-reload'),
                          icon: AppIcons.refresh,
                          tooltip: l10n.browserReload,
                          onPressed: canRetry && !finishing ? () => unawaited(_retry()) : null,
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Out of the tree once its renderer went (and before
                        // its controller is destroyed).
                        if (showView)
                          KeyedSubtree(
                            key: ValueKey('browser-auth-view-$_generation'),
                            child: BrowserAuthPage.debugView(controller),
                          ),
                        if (problem != null)
                          ColoredBox(
                            color: theme.colorScheme.surface,
                            child: Center(
                              child: SingleChildScrollView(
                                child: Semantics(
                                  liveRegion: true,
                                  child: EmptyView(
                                    key: const ValueKey('browser-auth-problem'),
                                    icon: AppIcons.offline,
                                    title: problem,
                                    actionLabel: canRetry ? (_rendererGone ? l10n.webReopen : l10n.commonRetry) : null,
                                    onAction: canRetry ? () => unawaited(_retry()) : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (finishing)
                          ColoredBox(
                            key: const ValueKey('browser-auth-finishing'),
                            color: theme.colorScheme.surface.withValues(alpha: 0.92),
                            child: Center(
                              child: Semantics(
                                liveRegion: true,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(l10n.browserAuthFinishing, style: theme.textTheme.bodyMedium),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (loading)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Semantics(
                              label: l10n.browserAuthLoading,
                              child: LinearProgressIndicator(
                                key: const ValueKey('browser-auth-progress'),
                                value: controller.progress <= 0 ? null : controller.progress / 100,
                                minHeight: 2,
                                borderRadius: BorderRadius.zero,
                                backgroundColor: Colors.transparent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    16 + media.padding.left,
                    8,
                    16 + media.padding.right,
                    8 + media.viewPadding.bottom,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey('browser-auth-system'),
                      onPressed: _opening || finishing ? null : () => unawaited(_openSystem()),
                      icon: const Icon(AppIcons.openExternal, size: 18),
                      label: Text(l10n.browserAuthOpenSystem, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The host the page is really on, with a lock: it is always HTTPS here.
class _Host extends StatelessWidget {
  const _Host({required this.host});

  final String host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Semantics(
      label: '${context.l10n.browserAuthSecure}, $host',
      excludeSemantics: true,
      child: GlassSurface(
        key: const ValueKey('browser-auth-host'),
        tier: GlassTier.chrome,
        stadium: true,
        child: SizedBox.expand(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(AppIcons.lock, size: 16, color: colors.textTertiary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
