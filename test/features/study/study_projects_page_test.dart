import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/extension_entity_store.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/study/pages/study_projects_mobile_layout.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

import '../../support/business_test_harness.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('studypi-projects-ui-test-');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('creates a study project through mobile UI and lists it', (
    tester,
  ) async {
    late final AppDatabase db;
    late final StudyProjectProvider studyProvider;

    await tester.runAsync(() async {
      db = AppDatabase.open(file: File(p.join(tempDir.path, 'study.db')));
      await ChatDatabaseRepository(db).ensureReady();
      studyProvider = StudyProjectProvider(
        entities: ExtensionEntityStore(db),
        projectDir: (projectId) async {
          final dir = Directory(p.join(tempDir.path, 'projects', projectId));
          await dir.create(recursive: true);
          return dir;
        },
      );
      await studyProvider.loaded;
    });
    addTearDown(() async {
      studyProvider.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>(
            create: (_) => SettingsProvider(createBusinessTestPreferences()),
          ),
          ChangeNotifierProvider<StudyProjectProvider>.value(
            value: studyProvider,
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StudyProjectsMobileLayout(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('学习项目'), findsOneWidget);
    expect(find.text('材料、讨论、笔记都在项目里，引用可回到原文'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('study-projects-empty-create')),
    );
    await tester.pumpAndSettle();

    final titleField = find.descendant(
      of: find.byKey(const ValueKey<String>('study-project-title-field')),
      matching: find.byType(TextField),
    );
    final goalField = find.descendant(
      of: find.byKey(const ValueKey<String>('study-project-goal-field')),
      matching: find.byType(TextField),
    );

    await tester.enterText(titleField, '认知负荷精读');
    await tester.enterText(goalField, '梳理内在与外在负荷的区别');
    await tester.pump();

    final saveButton = find
        .descendant(
          of: find.byKey(const ValueKey<String>('study-project-save-button')),
          matching: find.byType(GestureDetector),
        )
        .last;
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);

    for (var i = 0; i < 40 && studyProvider.projects.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(studyProvider.projects, hasLength(1));
    expect(find.text('认知负荷精读'), findsOneWidget);
    expect(find.text('梳理内在与外在负荷的区别'), findsOneWidget);
  });
}
