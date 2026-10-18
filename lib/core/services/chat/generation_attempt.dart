import 'dart:async';

import 'package:uuid/uuid.dart';

import '../api/tool_call_cancellation.dart';

/// One attempt, not one conversation or persisted assistant message.
/// A recovered tool answer can start a new attempt for the same message.
class GenerationAttempt {
  GenerationAttempt({required this.conversationId, required this.messageId})
    : requestId = 'generation:${const Uuid().v4()}';

  final String conversationId;
  final String messageId;
  final String requestId;
  final Completer<void> _cancelledCompleter = Completer<void>();
  bool _cancelled = false;
  bool _finished = false;

  bool get isCancelled => _cancelled;
  bool get isFinished => _finished;

  late final cancellation = ToolCallCancellation(
    isCancelled: () => _cancelled || _finished,
    cancelled: _cancelledCompleter.future,
  );

  void check() => cancellation.throwIfCancelled();

  void cancel() {
    _cancelled = true;
    if (!_cancelledCompleter.isCompleted) _cancelledCompleter.complete();
  }

  void finish() {
    _finished = true;
  }

  /// Stop waiting promptly, but consume late errors from non-cancellable I/O.
  /// The action must check again before starting another side effect.
  ///
  /// An action may itself drive the attempt to its terminal state (a resumed
  /// generation finishes inside it), so only cancellation — including being
  /// superseded, which cancels — discards a completed result.
  Future<T> run<T>(Future<T> Function() action) async {
    check();
    final result = await Future.any<T>([
      action(),
      _cancelledCompleter.future.then<T>(
        (_) => throw const ToolCallCancelledException(),
      ),
    ]);
    if (_cancelled) throw const ToolCallCancelledException();
    return result;
  }
}
