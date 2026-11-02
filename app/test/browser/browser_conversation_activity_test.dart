import 'package:dsh_app/browser/browser_conversation_activity.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

class _RawChatController extends FakeChatController {
  _RawChatController(super.sessionId, super.initial, this.log);
  List<SessionLogEvent> log;
  @override
  Iterable<SessionLogEvent> get events => log;
}

ChatState conversationState({
  bool running = false,
  int? start,
  int? end,
  String reason = 'completed',
  DshConnectionState? connection = DshConnectionState.connected,
}) => ChatState(
  loading: false,
  connection: connection,
  running: running,
  turns: [
    if (start != null)
      TurnTrace(
        turn: start,
        startSeq: start,
        start: DateTime(2026),
        spans: const [],
        endSeq: end,
        end: end == null ? null : DateTime(2026, 1, 1, 0, 1),
        endReason: end == null ? null : TurnEndReason(reason),
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const target = (host: HostRef.local, sessionId: 'chat');
  final provider = browserConversationActivityProvider(target);
  late ChatHarness harness;
  late ProviderContainer container;

  void start(ChatState initial, {List<SessionLogEvent>? raw}) {
    harness = ChatHarness(session: 'chat');
    container = ProviderContainer(
      overrides: [
        currentSessionProvider.overrideWith(() => FixedSession('chat')),
        chatProvider.overrideWith2(
          (id) => harness.controllers[id] = raw == null
              ? FakeChatController(id, initial)
              : _RawChatController(id, initial, raw),
        ),
      ],
    );
    container.read(chatOnScreenProvider.notifier).set(false);
    container.listen(provider, (_, _) {});
  }

  void emit(ChatState next) => harness.controllers['chat']!.emit(next);
  BrowserConversationActivity read() => container.read(provider);

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => container.dispose());

  test('initial completed history is seen; a running task then a normal end becomes unread', () {
    start(conversationState(start: 1, end: 5));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(running: true, start: 6));
    expect(read(), BrowserConversationActivity.running);
    emit(conversationState(start: 6, end: 9));
    expect(read(), BrowserConversationActivity.completed);
    emit(conversationState(start: 6, end: 9));
    expect(read(), BrowserConversationActivity.completed);
    expect(harness.controllers['chat']!.sent, isEmpty);
  });

  test('a task already running when the browser opens is tracked', () {
    start(conversationState(running: true, start: 3));
    expect(read(), BrowserConversationActivity.running);
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.completed);
  });

  test('fresh follow on an already connected mux needs no replayed connection event', () {
    start(conversationState(running: true, start: 3, connection: null));
    expect(read(), BrowserConversationActivity.running);
    emit(conversationState(start: 3, end: 7, connection: null));
    expect(read(), BrowserConversationActivity.completed);
  });

  test('null connection cannot bypass the follow synchronization guard', () {
    start(conversationState(running: true, start: 3, connection: null).copyWith(syncing: true));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(running: true, start: 3, connection: null));
    expect(read(), BrowserConversationActivity.running);
  });

  test('a long turn with its start outside the loaded window still reports its durable end', () {
    start(conversationState(running: true), raw: []);
    expect(read(), BrowserConversationActivity.running);
    final controller = harness.controllers['chat']! as _RawChatController;
    controller.log = [TurnEndedEvent(500, DateTime(2026), const {}, turn: 1, reason: const TurnEndReason('completed'))];
    emit(conversationState());
    expect(read(), BrowserConversationActivity.completed);
  });

  test('loading an older start for a historical end cannot create an unread completion', () {
    start(
      conversationState(),
      raw: [TurnEndedEvent(500, DateTime(2026), const {}, turn: 1, reason: const TurnEndReason('completed'))],
    );
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 1, end: 500));
    expect(read(), BrowserConversationActivity.idle);
  });

  test('a very short task published in a single frame is still noticed', () {
    start(conversationState(start: 1, end: 5));
    emit(conversationState(start: 6, end: 8));
    expect(read(), BrowserConversationActivity.completed);
  });

  test('idle status alone and an old turn end do not prove completion', () {
    start(conversationState(start: 1, end: 5));
    emit(conversationState(running: true, start: 1, end: 5));
    expect(read(), BrowserConversationActivity.running);
    emit(conversationState(start: 1, end: 5));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 6, end: 8));
    expect(read(), BrowserConversationActivity.completed);
  });

  for (final reason in ['aborted', 'error', 'blocked', 'interrupted', 'max-tokens', 'unknown']) {
    test('$reason does not show a successful completion', () {
      start(conversationState(running: true, start: 3));
      emit(conversationState(start: 3, end: 7, reason: reason));
      expect(read(), BrowserConversationActivity.idle);
    });
  }

  test('loss of stream and retained snapshots wait for a verified reconnect', () {
    start(conversationState(running: true, start: 3));
    emit(conversationState(running: true, start: 3).copyWith(streamLost: true));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 3, end: 7).copyWith(syncing: true));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 3, end: 7).copyWith(resyncing: true));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.completed);
  });

  test('initial loading or retained history never becomes a new completion', () {
    start(conversationState(start: 3, end: 7).copyWith(loading: true));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.idle);
  });

  test('next run clears the blue dot; stale previous end cannot finish it', () {
    start(conversationState(running: true, start: 3));
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.completed);
    emit(conversationState(running: true, start: 8));
    expect(read(), BrowserConversationActivity.running);
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 8, end: 12));
    expect(read(), BrowserConversationActivity.completed);
  });

  test('queued turns keep running and only the latest normal end shows a dot', () {
    start(conversationState(running: true, start: 3));
    emit(conversationState(running: true, start: 8));
    expect(read(), BrowserConversationActivity.running);
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.idle);
    emit(conversationState(start: 8, end: 12));
    expect(read(), BrowserConversationActivity.completed);
  });

  test('viewing a different conversation does not clear the dot; viewing its owner does', () {
    start(conversationState(running: true, start: 3));
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.completed);
    container.read(currentSessionProvider.notifier).select('other');
    container.read(chatOnScreenProvider.notifier).set(true);
    expect(read(), BrowserConversationActivity.completed);
    container.read(currentSessionProvider.notifier).select('chat');
    expect(read(), BrowserConversationActivity.idle);
    container.read(chatOnScreenProvider.notifier).set(false);
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.idle);
  });

  test('new conversation and same session ID on another host do not borrow activity', () {
    start(conversationState(running: true, start: 3));
    const other = (host: HostRef.ssh('other'), sessionId: 'chat');
    const blank = (host: HostRef.local, sessionId: null);
    expect(container.read(browserConversationActivityProvider(other)), BrowserConversationActivity.idle);
    expect(container.read(browserConversationActivityProvider(blank)), BrowserConversationActivity.idle);
    expect(read(), BrowserConversationActivity.running);
  });

  test('switching hosts hides activity and returning does not resurrect its old dot', () {
    start(conversationState(running: true, start: 3));
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.completed);
    container.read(activeHostProvider.notifier).select(const HostRef.ssh('other'));
    expect(read(), BrowserConversationActivity.idle);
    container.read(activeHostProvider.notifier).select(HostRef.local);
    expect(read(), BrowserConversationActivity.idle);
  });

  test('chat remains acknowledged if completion is observed while it is visible', () {
    start(conversationState(running: true, start: 3));
    container.read(chatOnScreenProvider.notifier).set(true);
    emit(conversationState(start: 3, end: 7));
    expect(read(), BrowserConversationActivity.idle);
  });
}
