import 'package:Kelivo/core/services/api/tool_call_cancellation.dart';
import 'package:Kelivo/core/services/chat/generation_attempt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GenerationAttempt attempt() =>
      GenerationAttempt(conversationId: 'c', messageId: 'm');

  test('an action that finishes the attempt still returns its result', () async {
    // A resumed tool-answer generation reaches its terminal state inside run().
    final a = attempt();
    final result = await a.run(() async {
      await Future<void>.delayed(Duration.zero);
      a.finish();
      return 'done';
    });
    expect(result, 'done');
    expect(a.isFinished, isTrue);
    expect(a.check, throwsA(isA<ToolCallCancelledException>()));
  });

  test('cancellation during the action discards its result', () async {
    final a = attempt();
    final future = a.run(() async {
      a.cancel();
      return 'late';
    });
    await expectLater(future, throwsA(isA<ToolCallCancelledException>()));
  });

  test('a finished attempt cannot start new work', () async {
    final a = attempt()..finish();
    await expectLater(
      a.run(() async => 'never'),
      throwsA(isA<ToolCallCancelledException>()),
    );
  });
}
