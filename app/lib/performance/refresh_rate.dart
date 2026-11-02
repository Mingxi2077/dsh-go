import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'performance_policy.dart';

/// Requests the fastest rate at the current resolution, subject to system policy.
/// A request is not a measurement of rendered FPS. Auto follows Flutter frames
/// and input; Android independently follows native touch/scroll activity so an
/// idle Flutter tree cannot cancel a WebView fling. Max requests continuously in
/// the foreground; system clears our preferences.
class RefreshRateService with WidgetsBindingObserver {
  RefreshRateService._();

  static final RefreshRateService instance = RefreshRateService._();

  /// The channel MainActivity already serves for the app.
  @visibleForTesting
  static MethodChannel channel = const MethodChannel('dsh/app');

  /// How long after the last frame the preference is released.
  static const idleAfter = Duration(milliseconds: 700);

  RefreshRateMode _mode = RefreshRateMode.auto;
  bool _active = false;
  bool _started = false;
  bool _foreground = false;
  bool _observing = false;
  bool _frameListenerInstalled = false;
  Timer? _idle;
  Future<void> _activation = Future<void>.value();

  RefreshRateMode get mode => _mode;

  /// Safe to call twice. Tests can explicitly enable activity observation;
  /// ordinary widget tests only send settings and do not leave idle timers.
  void start({bool? observeActivity}) {
    if (_started) return;
    _started = true;
    final binding = WidgetsBinding.instance;
    _foreground = binding.lifecycleState == null || binding.lifecycleState == AppLifecycleState.resumed;
    _observing = observeActivity ?? !Platform.environment.containsKey('FLUTTER_TEST');
    if (_observing) {
      binding.addObserver(this);
      binding.pointerRouter.addGlobalRoute(_onPointer);
      // Persistent callbacks cannot be removed. Install once, and gate it on
      // _started/_observing so test resets cannot accumulate live listeners.
      if (!_frameListenerInstalled) {
        _frameListenerInstalled = true;
        binding.addPersistentFrameCallback(_onFrame);
      }
    }
    unawaited(_sendMode());
    if (_observing) unawaited(requestActivity());
  }

  /// Called by the settings row and by the stored preference after launch.
  Future<void> setMode(RefreshRateMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    _release();
    final sent = _sendMode();
    if (_observing && mode == RefreshRateMode.auto) unawaited(requestActivity());
    await sent;
  }

  /// Call before a programmatic AnimationController.forward/reverse or route
  /// transition. Native touch dispatch already does this for touch-driven UI.
  /// Awaiting this acknowledges the request, not a completed display-mode switch.
  /// Later Flutter frames extend the lease without per-frame channel calls.
  Future<void> requestActivity() {
    if (!_started || !_foreground || _mode != RefreshRateMode.auto) return Future<void>.value();
    _idle?.cancel();
    _idle = Timer(idleAfter, _release);
    if (!_active) {
      _active = true;
      _activation = _sendActive(true);
    }
    return _activation;
  }

  void _onFrame(Duration _) {
    if (_started && _observing) unawaited(requestActivity());
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent ||
        event is PointerMoveEvent ||
        event is PointerUpEvent ||
        event is PointerSignalEvent) {
      unawaited(requestActivity());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _release();
      return;
    }
    // The engine outlives MainActivity: resend even an unchanged setting when
    // Android recreates its channel/window, then request before the first frame.
    unawaited(_sendMode());
    unawaited(requestActivity());
  }

  void _release() {
    _idle?.cancel();
    _idle = null;
    if (!_active) return;
    _active = false;
    unawaited(_sendActive(false));
  }

  /// Read-only numeric metadata. reportedRefreshRateHz is Android's app-visible
  /// display rate; it is NOT a measurement of Flutter/WebView FPS.
  Future<Map<Object?, Object?>?> diagnostics() async {
    try {
      return await channel.invokeMapMethod<Object?, Object?>('getRefreshRateDiagnostics');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _sendMode() => _send('setRefreshRateMode', {'mode': _mode.name});

  Future<void> _sendActive(bool active) => _send('setFrameActive', {'active': active});

  Future<void> _send(String method, Map<String, Object?> arguments) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Unsupported platform, or the activity is between channel attachments.
    } on PlatformException {
      // A display preference must not break input or animation.
    }
  }

  /// Test seam: forget the listener, the timer and the current mode.
  @visibleForTesting
  void resetForTest() {
    _idle?.cancel();
    _idle = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      WidgetsBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    }
    _observing = false;
    _mode = RefreshRateMode.auto;
    _active = false;
    _foreground = false;
    _started = false;
    _activation = Future<void>.value();
  }
}
