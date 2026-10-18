import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/api/chat_api_service.dart';
import 'package:Kelivo/core/services/api/retry_policy.dart';
import 'package:Kelivo/core/services/api/tool_call_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final alreadyCancelled in [false, true]) {
    test(
      'parent cancellation stops child HTTP (already=$alreadyCancelled)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final entered = Completer<void>();
        final release = Completer<void>();
        final stopped = Completer<void>();
        var requests = 0;
        server.listen((request) async {
          await request.drain<void>();
          requests++;
          if (!entered.isCompleted) entered.complete();
          if (!alreadyCancelled) await release.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'late response'},
                },
              ],
            }),
          );
          await request.response.close();
        });
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          ChatApiService.cancelRequest('child-http');
          await server.close(force: true);
        });
        if (alreadyCancelled) stopped.complete();
        final cancellation = ToolCallCancellation(
          isCancelled: () => stopped.isCompleted,
          cancelled: stopped.future,
        );
        final result = cancellation
            .runStream(
              () => ChatApiService.sendMessageStream(
                config: ProviderConfig(
                  id: 'parent-cancellation-test',
                  enabled: true,
                  name: 'Loopback',
                  apiKey: 'fixture',
                  baseUrl: 'http://127.0.0.1:${server.port}/v1',
                  providerType: ProviderKind.openai,
                ),
                modelId: 'test-model',
                requestId: 'child-http',
                messages: const [
                  {'role': 'user', 'content': 'test'},
                ],
                stream: false,
              ),
            )
            .toList();
        if (!alreadyCancelled) {
          await entered.future.timeout(const Duration(seconds: 5));
          stopped.complete();
        }
        try {
          await expectLater(
            result.timeout(const Duration(seconds: 1)),
            throwsA(predicate(isUserCancelError)),
          );
          expect(requests, alreadyCancelled ? 0 : 1);
        } finally {
          if (!release.isCompleted) release.complete();
        }
      },
    );
  }
}
