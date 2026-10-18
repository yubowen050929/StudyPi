import 'dart:async';

import 'package:Kelivo/core/services/api/stream/stream_chunk.dart';
import 'package:Kelivo/core/database/generation_run.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/controllers/chat_actions.dart';
import 'package:Kelivo/features/home/controllers/chat_controller.dart';
import 'package:Kelivo/features/home/controllers/generation_controller.dart';
import 'package:Kelivo/features/home/controllers/home_view_model.dart';
import 'package:Kelivo/features/home/controllers/stream_controller.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';
import 'package:Kelivo/features/home/services/message_generation_service.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/business_test_harness.dart';

class _RecordingChatService extends ChatService {
  final terminalStates = <GenerationRunState>[];
  Completer<void>? firstFinalizeHold;

  @override
  Future<GenerationRun?> finalizeGenerationRunSilent({
    required ChatMessage message,
    required List<Map<String, dynamic>> toolEvents,
    required String? generationRunId,
    required GenerationRunState? expectedState,
    required int? expectedStateRevision,
    required GenerationRunState terminalState,
    int? checkpointSeq,
    String? errorCode,
  }) async {
    terminalStates.add(terminalState);
    if (terminalStates.length == 1) await firstFinalizeHold?.future;
    return null;
  }
}

ChatMessage _message(String id) => ChatMessage(
  id: id,
  role: 'assistant',
  conversationId: 'conversation-1',
  isStreaming: true,
);

Future<ChatActions> _pumpActions(
  WidgetTester tester,
  ChatService service,
  SettingsProvider settings,
) async {
  late ChatActions actions;
  await tester.pumpWidget(
    ChangeNotifierProvider<SettingsProvider>.value(
      value: settings,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final chatController = ChatController(chatService: service);
            final streamController = StreamController(
              onStateChanged: () {},
              getSettingsProvider: () => settings,
              getCurrentConversationId: () => 'conversation-1',
            );
            final builder = MessageBuilderService(
              chatService: service,
              contextProvider: context,
            );
            final generation = GenerationController(
              chatService: service,
              chatController: chatController,
              streamController: streamController,
              messageBuilderService: builder,
              contextProvider: context,
              onStateChanged: () {},
              getTitleForLocale: (_) => 'title',
            );
            final messages = MessageGenerationService(
              chatService: service,
              messageBuilderService: builder,
              generationController: generation,
              streamController: streamController,
              contextProvider: context,
            );
            final viewModel = HomeViewModel(
              chatService: service,
              messageBuilderService: builder,
              messageGenerationService: messages,
              generationController: generation,
              streamController: streamController,
              chatController: chatController,
              contextProvider: context,
              getTitleForLocale: (_) => 'title',
            );
            actions = viewModel.debugChatActions;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  addTearDown(actions.streamController.dispose);
  addTearDown(actions.chatController.dispose);
  addTearDown(settings.dispose);
  addTearDown(service.dispose);
  return actions;
}

void _start(ChatActions actions, ChatMessage message) {
  actions.debugTrackActiveMessage(message);
  actions.streamController.markStreamingStarted(message.id);
  actions.chatController.setConversationLoading(message.conversationId, true);
}

StreamingState _state(SettingsProvider settings, ChatMessage message) {
  return StreamingState(
    GenerationContext(
      assistantMessage: message,
      apiMessages: const [],
      userImagePaths: const [],
      allowImagesApiRouting: false,
      providerKey: 'test',
      modelId: 'test-model',
      assistant: null,
      settings: settings,
      config: ProviderConfig(
        id: 'test',
        enabled: true,
        name: 'Test',
        apiKey: '',
        baseUrl: '',
      ),
      toolDefs: const [],
      supportsReasoning: true,
      enableReasoning: true,
      streamOutput: true,
      generateTitleOnFinish: false,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const {});

  for (final cancelledError in [false, true]) {
    for (final replacement in [false, true]) {
      testWidgets('ignores late prepare error after Stop '
          '(cancelled=$cancelledError, replacement=$replacement)', (
        tester,
      ) async {
        final service = _RecordingChatService();
        final settings = SettingsProvider(createBusinessTestPreferences());
        final actions = await _pumpActions(tester, service, settings);
        final errors = <String>[];
        actions.onStreamError = errors.add;
        final old = _message('old');
        _start(actions, old);

        await actions.cancelStreamingById(old.conversationId);
        expect(service.terminalStates, [GenerationRunState.cancelled]);
        service.terminalStates.clear();
        if (replacement) _start(actions, _message('new'));

        await actions.handleSendGenerationFailure(
          error: cancelledError
              ? http.ClientException('cancelled')
              : StateError('late preparation failure'),
          conversationId: old.conversationId,
          assistantMessage: old,
        );

        expect(
          service.terminalStates,
          isEmpty,
          reason: 'Stop already persisted the authoritative terminal state',
        );
        expect(errors, isEmpty);
        expect(
          actions.activeStreamingMessageId(old.conversationId),
          replacement ? 'new' : null,
        );
        expect(
          actions.chatController.isConversationLoading(old.conversationId),
          replacement,
        );
        expect(actions.streamController.isAnyMessageStreaming, replacement);
        actions.chatController.setConversationLoading(
          old.conversationId,
          false,
        );
        await tester.pump(const Duration(seconds: 10));
      });
    }
  }

  testWidgets('a delayed failure finalizer cannot clear a replacement run', (
    tester,
  ) async {
    final service = _RecordingChatService();
    final hold = service.firstFinalizeHold = Completer<void>();
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    final settings = SettingsProvider(createBusinessTestPreferences());
    final actions = await _pumpActions(tester, service, settings);
    final errors = <String>[];
    actions.onStreamError = errors.add;
    final old = _message('old');
    _start(actions, old);

    final failing = actions.handleSendGenerationFailure(
      error: StateError('preparation failure'),
      conversationId: old.conversationId,
      assistantMessage: old,
    );
    expect(service.terminalStates, [GenerationRunState.failed]);
    await actions.cancelStreamingById(old.conversationId);
    _start(actions, _message('new'));
    hold.complete();
    await failing;

    expect(actions.activeStreamingMessageId(old.conversationId), 'new');
    expect(
      actions.chatController.isConversationLoading(old.conversationId),
      isTrue,
    );
    expect(actions.streamController.isAnyMessageStreaming, isTrue);
    expect(errors, isEmpty);
    actions.chatController.setConversationLoading(old.conversationId, false);
    await tester.pump(const Duration(seconds: 10));
  });

  for (final sameMessage in [false, true]) {
    for (final event in ['chunk', 'error', 'finish']) {
      testWidgets(
        'cancelled stream ignores late $event (sameMessage=$sameMessage)',
        (tester) async {
          final service = _RecordingChatService();
          final settings = SettingsProvider(createBusinessTestPreferences());
          final actions = await _pumpActions(tester, service, settings);
          final errors = <String>[];
          actions.onStreamError = errors.add;
          final old = _state(settings, _message('old'));
          _start(actions, old.ctx.assistantMessage);
          actions.debugTrackStreamingState(old);
          await actions.cancelStreamingById(old.conversationId);
          service.terminalStates.clear();

          final replacement = _state(
            settings,
            _message(sameMessage ? 'old' : 'new'),
          );
          _start(actions, replacement.ctx.assistantMessage);
          actions.debugTrackStreamingState(replacement);
          switch (event) {
            case 'chunk':
              await actions.debugHandleStreamChunk(
                const ReasoningDelta(id: 'late', text: 'stale reasoning'),
                old,
              );
              expect(
                actions.streamController.getReasoningData(old.messageId)?.text,
                isNot('stale reasoning'),
              );
            case 'error':
              await actions.debugHandleStreamError(
                StateError('late failure'),
                old,
              );
            case 'finish':
              await actions.debugFinishStreaming(old);
          }

          expect(service.terminalStates, isEmpty);
          expect(errors, isEmpty);
          expect(
            actions.activeStreamingMessageId(old.conversationId),
            replacement.messageId,
          );
          expect(
            actions.chatController.isConversationLoading(old.conversationId),
            isTrue,
          );
          expect(actions.streamController.isAnyMessageStreaming, isTrue);
          actions.chatController.setConversationLoading(
            old.conversationId,
            false,
          );
          await tester.pump(const Duration(seconds: 10));
        },
      );
    }
  }

  testWidgets('late completion handoff cannot finish the replacement run', (
    tester,
  ) async {
    final service = _RecordingChatService();
    final settings = SettingsProvider(createBusinessTestPreferences());
    final actions = await _pumpActions(tester, service, settings);
    final handoff = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    actions.onAssistantMessageFinished = (_) async {
      handoff.complete();
      await release.future;
    };
    final sideEffects = <String>[];
    actions.onMaybeGenerateSummary = (_) => sideEffects.add('summary');
    actions.onMaybeGenerateSuggestions = (_) => sideEffects.add('suggestions');
    actions.onStreamFinished = (_) => sideEffects.add('finished');
    final old = _state(settings, _message('old'));
    _start(actions, old.ctx.assistantMessage);
    actions.debugTrackStreamingState(old);
    final finishing = actions.debugFinishStreaming(old);
    await handoff.future;
    await actions.cancelStreamingById(old.conversationId);
    final replacement = _state(settings, _message('new'));
    _start(actions, replacement.ctx.assistantMessage);
    actions.debugTrackStreamingState(replacement);
    release.complete();
    await finishing;

    expect(sideEffects, isEmpty);
    expect(actions.activeStreamingMessageId(old.conversationId), 'new');
    expect(
      actions.chatController.isConversationLoading(old.conversationId),
      isTrue,
    );
    actions.chatController.setConversationLoading(old.conversationId, false);
    await tester.pump(const Duration(seconds: 10));
  });
}
