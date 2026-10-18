import 'dart:io';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/extension_entity_store.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/providers/tts_provider.dart';
import 'package:Kelivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Kelivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/business_test_harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'each reply block opens its own citation and unverified ones are flagged',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('studypi-chat-cite-');
      late AppDatabase db;
      late StudyProjectProvider study;
      late String docId;
      await tester.runAsync(() async {
        db = AppDatabase.open(file: File('${tempDir.path}/study.db'));
        await ChatDatabaseRepository(db).ensureReady();
        StudyProjectProvider make() => StudyProjectProvider(
          entities: ExtensionEntityStore(db),
          projectDir: (id) async =>
              Directory('${tempDir.path}/study/$id')
                ..createSync(recursive: true),
        );
        final setup = make();
        await setup.loaded;
        final project = await setup.createProject(title: 'Load');
        final md = File('${tempDir.path}/load.md')
          ..writeAsStringSync(
            'Intrinsic load depends on element interactivity.\n'
            'Germane load supports schema construction.',
          );
        docId = (await setup.importFiles(project.id, [md.path])).single.id;
        await setup.store.bindConversation(project.id, 'conv-study');
        study = make();
        await study.loaded;
        await study.loadResolver(project.id);
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          await db.close();
          tempDir.deleteSync(recursive: true);
        });
      });

      final harness = await createBusinessTestHarness(
        initial: {
          'display_chat_message_background_style_v1': 'solid',
          'display_assistant_bubble_split_paragraphs_v1': true,
        },
      );
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      final message = ChatMessage(
        role: 'assistant',
        content:
            'Interactivity matters.'
            '[[cite doc="$docId" quote="depends on element interactivity"]]'
            '\n\n'
            'Schemas grow.'
            '[[cite doc="$docId" quote="supports schema construction"]]'
            '[[cite doc="$docId" quote="this sentence is not in the source"]]',
        conversationId: 'conv-study',
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider(
              create: (_) =>
                  TtsProvider(preferences: createBusinessTestPreferences()),
            ),
            ChangeNotifierProvider<ToolApprovalService>.value(
              value: ToolApprovalService(),
            ),
            ChangeNotifierProvider<AskUserInteractionService>.value(
              value: AskUserInteractionService(),
            ),
            ChangeNotifierProvider<StudyProjectProvider>.value(value: study),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ChatMessageWidget(message: message, showModelIcon: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('[[cite'), findsNothing);
      // Blocks number independently: "1" in each paragraph, "2" in the second.
      expect(find.text('1'), findsNWidgets(2));
      expect(find.text('2'), findsOneWidget);
      final cs = Theme.of(tester.element(find.text('2'))).colorScheme;
      expect(tester.widget<Text>(find.text('2')).style?.color, cs.error);
      expect(tester.widget<Text>(find.text('1').last).style?.color, isNull);

      await tester.tap(find.text('1').last);
      await tester.pumpAndSettle();
      expect(find.text('supports schema construction'), findsOneWidget);
      expect(find.text('depends on element interactivity'), findsNothing);
    },
  );
}
