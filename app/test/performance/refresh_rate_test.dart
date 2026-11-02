import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/performance/refresh_rate.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RefreshRateService.instance.resetForTest();
  });

  tearDown(() => RefreshRateService.instance.resetForTest());

  Future<void> waitLoaded(ProviderContainer container) async {
    final notifier = container.read(performancePrefsProvider.notifier);
    await notifier.ready;
    for (var i = 0; i < 40; i++) {
      if (container.read(performancePrefsProvider).loaded) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('preferences did not finish loading');
  }

  test('the stored choice loads and saves', () async {
    SharedPreferences.setMockInitialValues({'performance.refresh_rate': 'system'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await waitLoaded(container);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.system);
    await container.read(performancePrefsProvider.notifier).setRefreshRate(RefreshRateMode.max);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.max);
    expect((await SharedPreferences.getInstance()).getString('performance.refresh_rate'), 'max');
  });

  test('the default is auto, and old installs read as auto', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await waitLoaded(container);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.auto);
  });

  test('mode changes reach the platform once', () async {
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RefreshRateService.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(RefreshRateService.channel, null));

    final service = RefreshRateService.instance;
    service.start();
    await service.setMode(RefreshRateMode.max);
    await service.setMode(RefreshRateMode.max); // same value: no second call
    await Future<void>.delayed(Duration.zero);

    final modes = calls
        .where((call) => call.method == 'setRefreshRateMode')
        .map((call) => (call.arguments as Map<Object?, Object?>)['mode'])
        .toList();
    expect(modes, ['auto', 'max']);
  });

  group('activity requests', () {
    final service = RefreshRateService.instance;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;

    List<bool> activeCalls() => calls
        .where((call) => call.method == 'setFrameActive')
        .map((call) => (call.arguments as Map)['active'] as bool)
        .toList();

    setUp(() {
      calls = [];
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      messenger.setMockMethodCallHandler(RefreshRateService.channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(RefreshRateService.channel, null));

    testWidgets('programmatic animation can request before its first frame and expire', (tester) async {
      service.start(observeActivity: false);
      await service.requestActivity();
      expect(activeCalls(), [true]); // No pump/frame has happened yet.
      await tester.pump(const Duration(milliseconds: 600));
      await service.requestActivity();
      expect(activeCalls(), [true]); // Renewal does not send another channel message.
      await tester.pump(const Duration(milliseconds: 699));
      expect(activeCalls(), [true]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(activeCalls(), [true, false]);
    });

    testWidgets('startup and Flutter frames renew without per-frame channel traffic', (tester) async {
      service.start(observeActivity: true);
      service.start(observeActivity: true);
      expect(activeCalls(), [true]);
      for (var i = 0; i < 5; i++) {
        tester.binding.scheduleFrame();
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(activeCalls(), [true]);
      expect(calls.where((call) => call.method == 'setRefreshRateMode'), hasLength(1));
      service.resetForTest();
    });

    testWidgets('pointer requests before a Flutter frame after idle', (tester) async {
      await tester.pumpWidget(const SizedBox());
      service.start(observeActivity: true);
      await tester.pump(RefreshRateService.idleAfter);
      expect(activeCalls(), [true, false]);
      tester.binding.pointerRouter.route(const PointerDownEvent(pointer: 42));
      tester.binding.pointerRouter.route(const PointerUpEvent(pointer: 42));
      expect(activeCalls(), [true, false, true]); // Still no animation frame.
      service.resetForTest();
    });

    for (final mode in [RefreshRateMode.system, RefreshRateMode.max]) {
      testWidgets('$mode does not acquire Flutter auto leases', (tester) async {
        service.start(observeActivity: false);
        await service.setMode(mode);
        await service.requestActivity();
        await tester.pump(const Duration(seconds: 2));
        expect(activeCalls(), isEmpty);
      });
    }

    testWidgets('background rejects activity and resume resends the retained mode', (tester) async {
      service.start(observeActivity: true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await service.requestActivity();
      await tester.pump(const Duration(seconds: 1));
      expect(activeCalls(), [true, false]);
      await service.setMode(RefreshRateMode.system);
      calls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(activeCalls(), isEmpty);
      expect(calls.single.method, 'setRefreshRateMode');
      expect(calls.single.arguments, {'mode': 'system'});
      service.resetForTest();
    });

    testWidgets('switching out of auto releases immediately and cannot leak a timer', (tester) async {
      service.start(observeActivity: false);
      await service.requestActivity();
      await service.setMode(RefreshRateMode.system);
      await tester.pump(const Duration(seconds: 1));
      expect(activeCalls(), [true, false]);
      await service.setMode(RefreshRateMode.auto);
      await service.requestActivity();
      expect(activeCalls(), [true, false, true]);
      service.resetForTest();
    });

    testWidgets('reset does not leave an active persistent callback or timer', (tester) async {
      for (var i = 0; i < 3; i++) {
        service.start(observeActivity: true);
        service.resetForTest();
      }
      calls.clear();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, isEmpty);
    });

    test('diagnostics preserves a requested/actual mismatch without claiming FPS', () async {
      messenger.setMockMethodCallHandler(RefreshRateService.channel, (call) async {
        calls.add(call);
        return {'requestedRefreshRateHz': 120.0, 'reportedRefreshRateHz': 60.0, 'measuredAppFps': null};
      });
      final result = await service.diagnostics();
      expect(result?['requestedRefreshRateHz'], 120.0);
      expect(result?['reportedRefreshRateHz'], 60.0);
      expect(result?['measuredAppFps'], isNull);
      expect(calls.single.method, 'getRefreshRateDiagnostics');
      expect(calls.single.arguments, isNull);
    });

    test('unsupported platform is harmless for settings and diagnostics', () async {
      messenger.setMockMethodCallHandler(RefreshRateService.channel, null);
      await service.setMode(RefreshRateMode.system);
      expect(await service.diagnostics(), isNull);
    });
  });
}
