import 'dart:io';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/extension_entity_store.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/study/study_citation_resolver.dart';
import 'package:Kelivo/core/services/study/study_corpus.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/core/services/study/study_prompts.dart';
import 'package:Kelivo/core/services/tts/tts_text_selection.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/features/study/utils/study_citation_markup.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('StudyCitationMarkup', () {
    test('numbers distinct claims and reuses numbers for repeats', () {
      const a = '[[cite doc="d" sec="sec-1" quote="alpha beta"]]';
      const b = '[[cite doc="d" sec="sec-2" quote="gamma delta"]]';
      final markup = StudyCitationMarkup.rewrite('One$a two$b three$a.')!;
      expect(
        markup.markdown,
        'One[citation](studycite-1) two[citation](studycite-2) '
        'three[citation](studycite-1).',
      );
      expect(markup.labelFor('studycite-2'), '2');
      expect(markup.citationFor('studycite-1')?.sectionId, 'sec-1');
      expect(StudyCitationMarkup.isStudyId('studycite-1'), isTrue);
      expect(StudyCitationMarkup.isStudyId('1'), isFalse);
    });

    test('leaves plain text alone and hides a marker still streaming', () {
      expect(StudyCitationMarkup.rewrite('No markers here.'), isNull);
      expect(StudyCitationMarkup.rewrite('```\n[[cite doc="x"]]\n```'), isNull);
      final partial = StudyCitationMarkup.rewrite(
        'Claim [[cite doc="d" quote="abc',
        streaming: true,
      )!;
      expect(partial.markdown, 'Claim ');
      expect(
        StudyCitationMarkup.rewrite('Claim [[cite doc="d" quote="abc'),
        isNull,
      );
    });

    test('speech skips markers', () {
      expect(
        TtsTextSelection.apply(
          '工作记忆有限[[cite doc="d" quote="工作记忆容量有限"]]。',
          mode: TtsTextSelectionMode.fullText,
        ),
        '工作记忆有限。',
      );
    });
  });

  group('StudyProjectProvider', () {
    late Directory tempDir;
    late AppDatabase db;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('studypi-provider-');
      db = AppDatabase.open(file: File('${tempDir.path}/study.db'));
      await ChatDatabaseRepository(db).ensureReady();
    });

    tearDown(() async {
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    StudyProjectProvider provider() => StudyProjectProvider(
      entities: ExtensionEntityStore(db),
      projectDir: (id) async =>
          Directory('${tempDir.path}/app/study/$id')
            ..createSync(recursive: true),
    );

    test(
      'copies imports into the project, deduplicates, indexes and resolves',
      () async {
        final study = provider();
        await study.loaded;
        final project = await study.createProject(
          title: 'Memory',
          mode: StudyInteractionMode.guidedPractice,
        );
        final picked = File('${tempDir.path}/picked/notes.md')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '# Working memory\nWorking memory capacity is limited.',
          );
        final sliced = File('${tempDir.path}/picked/教材_207-359.md')
          ..writeAsStringSync('# 第九章\n知识的学习。');
        final named = await study.importFiles(project.id, [sliced.path]);
        expect(named.single.corpusPageRange, const StudyPageRange(207, 359));
        await study.deleteDocument(project.id, named.single.id);
        final docs = await study.importFiles(project.id, [picked.path]);
        final doc = docs.single;
        final root = await study.projectDirectory(project.id);
        expect(p.isWithin(p.join(root, 'sources'), doc.originalPath!), isTrue);
        // The picked file may vanish (picker caches); the copy remains.
        picked.deleteSync();

        final again = File('${tempDir.path}/picked2/notes.md')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '# Working memory\nWorking memory capacity is limited.',
          );
        final duplicate = await study.importFiles(project.id, [again.path]);
        expect(duplicate.single.id, doc.id);
        expect(Directory('$root/sources').listSync(), hasLength(1));
        expect(study.documentsOf(project.id), hasLength(1));

        expect((await study.loadResolver(project.id)).indexOf(doc.id), isNull);
        await study.buildIndex(project.id, doc.id);
        expect(study.cachedResolver(project.id), isNull);
        final resolver = await study.loadResolver(project.id);
        expect(resolver.indexOf(doc.id), isNotNull);
        final resolved = resolver
            .resolveAll(
              '[[cite doc="${doc.id}" sec="sec-1" '
              'quote="capacity is limited"]]',
            )
            .single;
        expect(resolved.isGroundedEvidence, isTrue);

        final note = await study.saveNote(
          project.id,
          title: 'Capacity',
          body: 'Limited.',
          anchors: [resolved.toAnchor()],
        );
        expect(note.evidenceStatus, StudyEvidenceStatus.grounded);
        expect(study.notesOf(project.id)!.first.id, note.id);

        await study.deleteDocument(project.id, doc.id);
        expect(study.documentsOf(project.id), isEmpty);
        expect(Directory('$root/sources').listSync(), isEmpty);
        expect(
          Directory('$root/.studypi/index/${doc.id}').existsSync(),
          isFalse,
        );

        await study.deleteProject(project.id);
        expect(study.projects, isEmpty);
        expect(Directory(root).existsSync(), isFalse);
      },
    );

    testWidgets('bound conversations receive the project context', (
      tester,
    ) async {
      late StudyProjectProvider study;
      late String projectId;
      await tester.runAsync(() async {
        final setup = provider();
        await setup.loaded;
        final project = await setup.createProject(
          title: 'Load theory',
          goal: 'Explain germane load',
        );
        projectId = project.id;
        final md = File('${tempDir.path}/load.md')
          ..writeAsStringSync('Germane load supports schema construction.');
        await setup.importFiles(project.id, [md.path]);
        await setup.store.bindConversation(project.id, 'conv-study');
        study = provider();
        await study.loaded;
      });
      expect(study.projectForConversation('conv-study')?.id, projectId);
      expect(study.projectForConversation('conv-plain'), isNull);

      late BuildContext captured;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: study,
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      final builder = MessageBuilderService(
        chatService: ChatService(),
        contextProvider: captured,
      );
      List<Map<String, dynamic>> messages() => [
        {'role': 'system', 'content': 'core'},
        {'role': 'user', 'content': 'hi'},
      ];
      final bound = messages();
      final plain = messages();
      await tester.runAsync(() async {
        await builder.injectStudyProjectContext(
          bound,
          conversation: Conversation(id: 'conv-study', title: 't'),
        );
        await builder.injectStudyProjectContext(
          plain,
          conversation: Conversation(id: 'conv-plain', title: 't'),
        );
      });
      final system = bound.first['content'] as String;
      expect(system, startsWith('core\n\n<study_mode mode="explain">'));
      expect(system, contains('<study_citation_protocol'));
      expect(system, contains('Germane load supports schema construction.'));
      expect(system, contains('project_goal: Explain germane load'));
      expect(plain.first['content'], 'core');
      expect(StudyCitationSyntax.stripMarkers('a[[cite doc="x"]]b'), 'ab');
    });
  });
}
