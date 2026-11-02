import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/chat_state.dart';
import '../state/hosts_state.dart';
import '../state/notify_state.dart' show viewedChatProvider;

/// A browser keeps the conversation it opened for, even if selection changes.
typedef BrowserConversationTarget = ({HostRef host, String? sessionId});

enum BrowserConversationActivity { idle, running, completed }

typedef _ActivitySample = ({bool ready, bool running, int? start, int? end, bool completed});

_ActivitySample _sample(ChatState chat, Iterable<SessionLogEvent> events) {
  final last = chat.turns.lastOrNull;
  int? start = last?.startSeq;
  int? end = last?.endSeq;
  var completed = last?.endReason?.isCompleted == true;
  // traceTurns omits a turn when its start is outside the loaded history
  // window. Long turns still have a durable end: don't require a full trace
  // (or fetch older pages) just to report their outcome. Also seed old ends
  // here, so loading an older start later cannot turn history into a new dot.
  if (last == null) {
    for (final event in events) {
      if (event is TurnStartedEvent) {
        start = event.seq;
        end = null;
        completed = false;
      } else if (event is TurnEndedEvent) {
        end = event.seq;
        completed = event.reason.isCompleted;
      }
    }
  }
  return (
    // The mux's states stream does not replay its initial connected value.
    // A follow opened on an already connected mux can have connection == null
    // throughout a healthy task. controlReady proves its fresh generation;
    // an explicit non-connected event still blocks stale activity.
    ready:
        !chat.loading &&
        !chat.resyncing &&
        chat.controlReady &&
        (chat.connection == null || chat.connection == DshConnectionState.connected),
    running: chat.running,
    start: start,
    end: end,
    completed: completed,
  );
}

/// Observes the existing conversation follow, without polling or acquiring an
/// interaction lease. A durable, new normal turn end is the proof of completion;
/// losing the connection or merely observing `running == false` is not.
final browserConversationActivityProvider = NotifierProvider.autoDispose
    .family<BrowserConversationActivityController, BrowserConversationActivity, BrowserConversationTarget>(
      BrowserConversationActivityController.new,
    );

class BrowserConversationActivityController extends Notifier<BrowserConversationActivity> {
  BrowserConversationActivityController(this.target);

  final BrowserConversationTarget target;
  bool _seeded = false;
  bool _wasRunning = false;
  bool _unseenCompletion = false;
  int _lastEnd = 0;
  int _endAfter = 0;

  @override
  BrowserConversationActivity build() {
    _seeded = false;
    _wasRunning = false;
    _unseenCompletion = false;
    _lastEnd = 0;
    _endAfter = 0;
    // chatProvider is keyed by session ID and follows the active host. Never
    // attach a browser belonging to a different host to that stream.
    final active = ref.watch(activeHostProvider);
    final session = target.sessionId;
    if (session == null || active != target.host) return BrowserConversationActivity.idle;

    ref.listen(viewedChatProvider, (_, viewed) {
      if (viewed?.host == target.host && viewed?.sessionId == session) {
        _unseenCompletion = false;
        if (state == BrowserConversationActivity.completed) state = BrowserConversationActivity.idle;
      }
    });
    final controller = ref.watch(chatProvider(session).notifier);
    final source = chatProvider(session).select((chat) => _sample(chat, controller.events));
    ref.listen(source, (_, next) => state = _observe(next));
    return _observe(ref.read(source));
  }

  BrowserConversationActivity _observe(_ActivitySample next) {
    // Retain the sequence watermark across reconnects, but don't display stale
    // activity until the follow has a fresh, connected snapshot again.
    if (!next.ready) return BrowserConversationActivity.idle;
    if (!_seeded) {
      _seeded = true;
      _lastEnd = next.end ?? 0;
      _endAfter = _lastEnd;
    }
    if (next.running) {
      _unseenCompletion = false;
      if (!_wasRunning && next.end != null && next.end! > _endAfter) {
        // A status-start can arrive before its turn-start; the old finished
        // turn cannot become this new run's completion.
        _endAfter = next.end!;
      }
      if (next.start != null && next.start! > _endAfter) _endAfter = next.start!;
      _wasRunning = true;
      return BrowserConversationActivity.running;
    }
    _wasRunning = false;
    final end = next.end;
    if (end != null && end > _lastEnd) {
      _lastEnd = end;
      // Handles a very short run whose start and end were published in one
      // frame, as well as an idle status arriving before the durable turn end.
      if (end > _endAfter) _unseenCompletion = next.completed;
    }
    final viewed = ref.read(viewedChatProvider);
    if (viewed?.host == target.host && viewed?.sessionId == target.sessionId) _unseenCompletion = false;
    return _unseenCompletion ? BrowserConversationActivity.completed : BrowserConversationActivity.idle;
  }
}
