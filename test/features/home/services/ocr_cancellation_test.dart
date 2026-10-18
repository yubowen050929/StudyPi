import 'dart:async';

import 'package:Kelivo/core/services/api/retry_policy.dart';
import 'package:Kelivo/core/services/api/tool_call_cancellation.dart';
import 'package:Kelivo/features/home/services/ocr_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final stage in ['hashes', 'first_image']) {
    testWidgets('Stop during $stage prevents further OCR and artifact writes', (
      tester,
    ) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final stopped = Completer<void>();
      var calls = 0;
      var writes = 0;
      final service = OcrService(
        resolveContentHashes: (paths) async {
          if (stage == 'hashes') {
            entered.complete();
            await release.future;
          }
          return {for (final path in paths) path: 'hash-$path'};
        },
        ocrExecutor: (_) async {
          calls++;
          if (stage == 'first_image' && calls == 1) {
            entered.complete();
            await release.future;
          }
          return 'recognized text';
        },
        persistArtifact: (_, _) async => writes++,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      final context = tester.element(find.byType(SizedBox));
      final cancellation = ToolCallCancellation(
        isCancelled: () => stopped.isCompleted,
        cancelled: stopped.future,
      );
      final result = cancellation.run(
        () => service.getOcrTextForImages(
          const ['/one.png', '/two.png'],
          context,
          revisionId: 'user-1',
        ),
      );
      await entered.future;
      stopped.complete();
      final checked = expectLater(
        result,
        throwsA(predicate(isUserCancelError)),
      );
      release.complete();
      await checked;
      expect(calls, stage == 'hashes' ? 0 : 1);
      expect(writes, 0);
      expect(service.cacheSize, 0);
    });
  }
}
