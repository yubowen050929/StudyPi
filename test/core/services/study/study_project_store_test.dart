import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/database/extension_entity_store.dart';
import 'package:Kelivo/core/services/study/study_citation_resolver.dart';
import 'package:Kelivo/core/services/study/study_corpus.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/core/services/study/study_prompts.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('studypi-project-store-');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File writeTextPdf(String relativePath, List<String> pages) {
    final doc = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
    for (final pageText in pages) {
      final page = doc.pages.add();
      if (pageText.isNotEmpty) {
        page.graphics.drawString(
          pageText,
          font,
          bounds: const Rect.fromLTWH(0, 0, 400, 200),
        );
      }
    }
    final bytes = doc.saveSync();
    doc.dispose();
    final file = File('${tempDir.path}/$relativePath');
    file.parent.createSync(recursive: true);
    return file..writeAsBytesSync(bytes);
  }

  test(
    'distinguishes same-name files by content hash and flags scanned or unreadable sources',
    () async {
      final dbFile = File('${tempDir.path}/study.db');
      final db = AppDatabase.open(file: dbFile);
      addTearDown(db.close);
      final repo = ChatDatabaseRepository(db);
      await repo.ensureReady();
      final store = StudyProjectStore(ExtensionEntityStore(db));

      final project = await store.createProject(
        title: 'Working Memory Study',
        goal: 'Compare Baddeley and Cowan models',
      );

      final firstCopy = File('${tempDir.path}/a/chapter.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('Baddeley phonological loop model');
      final duplicateCopy = File('${tempDir.path}/b/chapter.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('Baddeley phonological loop model');
      final differentCopySameName = File('${tempDir.path}/c/chapter.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('Cowan embedded-processes model');

      final doc1 = await store.importFile(
        projectId: project.id,
        filePath: firstCopy.path,
      );
      final docDuplicate = await store.importFile(
        projectId: project.id,
        filePath: duplicateCopy.path,
      );
      final doc2 = await store.importFile(
        projectId: project.id,
        filePath: differentCopySameName.path,
      );

      expect(docDuplicate.id, doc1.id);
      expect(doc2.id, isNot(doc1.id));
      expect(doc2.contentSha256, isNot(doc1.contentSha256));
      expect(doc1.status, StudySourceStatus.ready);
      expect(doc2.status, StudySourceStatus.ready);

      final scannedPdf = writeTextPdf('scanned.pdf', ['', '']);
      final scannedDoc = await store.importFile(
        projectId: project.id,
        filePath: scannedPdf.path,
      );
      expect(scannedDoc.status, StudySourceStatus.scannedNeedsOcr);
      expect(scannedDoc.physicalPageCount, 2);

      final corruptedPdf = File('${tempDir.path}/corrupted.pdf')
        ..writeAsStringSync('not a valid pdf');
      final corruptedDoc = await store.importFile(
        projectId: project.id,
        filePath: corruptedPdf.path,
      );
      expect(corruptedDoc.status, StudySourceStatus.unreadable);
    },
  );

  test(
    'holds ambiguous source links until confirmed and separates physical PDF pages from corpus page labels',
    () async {
      final db = AppDatabase.open(file: File('${tempDir.path}/links.db'));
      addTearDown(db.close);
      final repo = ChatDatabaseRepository(db);
      await repo.ensureReady();
      final store = StudyProjectStore(ExtensionEntityStore(db));

      final project = await store.createProject(title: 'Cognitive Load');
      final candidateA = writeTextPdf('BookA_92-206.pdf', [
        'Irrelevant book page 1',
      ]);
      final candidateB = writeTextPdf('BookB_92-206.pdf', [
        'Intrinsic load definition on slice page 1',
        'Germane load example on slice page 2',
      ]);
      final markdown = File('${tempDir.path}/notes_92-206.md')
        ..writeAsStringSync(
          'Intrinsic load definition on slice page 1\n'
          'Germane load example on slice page 2',
        );

      final pending = await store.importFile(
        projectId: project.id,
        filePath: markdown.path,
        title: '教材 · 92—206页',
        candidatePdfPaths: [candidateA.path, candidateB.path],
        corpusPageRange: const StudyPageRange(92, 206),
      );
      expect(pending.status, StudySourceStatus.pendingSourceLink);
      expect(pending.originalPath, isNull);
      expect(pending.physicalPageCount, isNull);

      final unverifiedBeforeConfirm = await store.saveNote(
        projectId: project.id,
        title: 'Draft note before confirming source',
        body: 'Germane load summary',
        anchors: [
          StudySourceAnchor(
            documentId: pending.id,
            corpusPage: 120,
            quote: 'Germane load example on slice page 2',
          ),
        ],
      );
      expect(
        unverifiedBeforeConfirm.evidenceStatus,
        StudyEvidenceStatus.insufficientEvidence,
      );

      await expectLater(
        store.confirmSourceLink(
          projectId: project.id,
          documentId: pending.id,
          pdfPath: '${tempDir.path}/other.pdf',
        ),
        throwsArgumentError,
      );

      final confirmed = await store.confirmSourceLink(
        projectId: project.id,
        documentId: pending.id,
        pdfPath: candidateB.path,
      );
      expect(confirmed.status, StudySourceStatus.ready);
      expect(confirmed.physicalPageCount, 2);
      expect(confirmed.corpusPageRange, const StudyPageRange(92, 206));

      // Corpus page 150 must not be accepted as physicalPage (which is 1..2).
      final confusedPageNote = await store.saveNote(
        projectId: project.id,
        title: 'Confused page number',
        body: 'Tries to pass textbook page 150 as physical PDF page',
        anchors: [
          StudySourceAnchor(
            documentId: confirmed.id,
            physicalPage: 150,
            quote: 'Germane load example on slice page 2',
          ),
        ],
      );
      expect(
        confusedPageNote.evidenceStatus,
        StudyEvidenceStatus.insufficientEvidence,
      );

      final groundedNote = await store.saveNote(
        projectId: project.id,
        title: 'Verified note',
        body: 'Germane load is anchored to slice page 2 (textbook page 150).',
        anchors: [
          StudySourceAnchor(
            documentId: confirmed.id,
            physicalPage: 2,
            corpusPage: 150,
            quote: 'Germane load example on slice page 2',
          ),
        ],
      );
      expect(groundedNote.evidenceStatus, StudyEvidenceStatus.grounded);
      expect(
        groundedNote.anchors.single.contentSha256,
        confirmed.contentSha256,
      );
    },
  );

  test(
    'isolates materials across projects, inspects prompt layers, survives reopen, and merges in backup',
    () async {
      final dbFile = File('${tempDir.path}/primary.db');
      final db = AppDatabase.open(file: dbFile);
      final repo = ChatDatabaseRepository(db);
      await repo.ensureReady();
      final store = StudyProjectStore(ExtensionEntityStore(db));

      final projectA = await store.createProject(
        title: 'Project A',
        goal: 'Understand retrieval practice',
        mode: StudyInteractionMode.guidedPractice,
        conversationIds: const ['conv-a'],
      );
      final projectB = await store.createProject(
        title: 'Project B',
        goal: 'Separate topic',
        mode: StudyInteractionMode.explain,
      );

      final fileA = File('${tempDir.path}/retrieval.md')
        ..writeAsStringSync('Testing effect strengthens memory traces.');
      final fileB = File('${tempDir.path}/unrelated.md')
        ..writeAsStringSync('Secret material from project B.');

      final docA = await store.importFile(
        projectId: projectA.id,
        filePath: fileA.path,
      );
      final docB = await store.importFile(
        projectId: projectB.id,
        filePath: fileB.path,
      );

      // Cross-project anchor reference must never be accepted as grounded.
      final crossProjectNote = await store.saveNote(
        projectId: projectA.id,
        title: 'Cross-project attempt',
        body: 'Should not verify against project B document',
        anchors: [
          StudySourceAnchor(
            documentId: docB.id,
            quote: 'Secret material from project B.',
          ),
        ],
      );
      expect(
        crossProjectNote.evidenceStatus,
        StudyEvidenceStatus.insufficientEvidence,
      );

      final validNote = await store.saveNote(
        projectId: projectA.id,
        title: 'Retrieval practice finding',
        body: 'Active retrieval outperforms passive rereading.',
        anchors: [
          StudySourceAnchor(
            documentId: docA.id,
            quote: 'Testing effect strengthens memory traces.',
          ),
        ],
        conversationId: 'conv-a',
      );
      expect(validNote.evidenceStatus, StudyEvidenceStatus.grounded);

      final promptA = await store.buildProjectSystemPrompt(
        projectId: projectA.id,
        customPrompt: 'Prefer concrete experimental examples.',
      );
      expect(promptA, contains('<studypi_soul version="studypi-soul-v1">'));
      expect(promptA, contains('<study_mode mode="guidedPractice">'));
      expect(promptA, contains('Testing effect strengthens memory traces.'));
      expect(promptA, isNot(contains('Secret material from project B.')));

      final inspection = StudyPrompts.inspect(
        'Prefer concrete experimental examples.',
        mode: projectA.mode,
      );
      expect(inspection.fixedCore, StudyPrompts.soul);
      expect(inspection.mode, StudyInteractionMode.guidedPractice);
      expect(inspection.modeInstruction, StudyPrompts.guidedStudy);
      expect(
        inspection.customInstructions,
        'Prefer concrete experimental examples.',
      );

      await db.close();

      // Reopen the same SQLite file to verify offline/restart persistence.
      final reopenedDb = AppDatabase.open(file: dbFile);
      addTearDown(reopenedDb.close);
      final reopenedStore = StudyProjectStore(ExtensionEntityStore(reopenedDb));
      final restoredNotes = await reopenedStore.listNotes(projectA.id);
      expect(restoredNotes, hasLength(2));
      expect(
        restoredNotes
            .singleWhere((item) => item.id == validNote.id)
            .evidenceStatus,
        StudyEvidenceStatus.grounded,
      );

      // Merge into a fresh target database via ChatDatabaseRepository backup merge.
      final targetDb = AppDatabase.open(
        file: File('${tempDir.path}/target.db'),
      );
      addTearDown(targetDb.close);
      final targetRepo = ChatDatabaseRepository(targetDb);
      await targetRepo.ensureReady();
      await targetRepo.mergeBackupSnapshot(dbFile);

      final mergedStore = StudyProjectStore(ExtensionEntityStore(targetDb));
      final mergedProject = await mergedStore.getProject(projectA.id);
      expect(mergedProject?.title, 'Project A');
      expect(mergedProject?.mode, StudyInteractionMode.guidedPractice);
      final mergedDocs = await mergedStore.listDocuments(projectA.id);
      expect(mergedDocs.single.contentSha256, docA.contentSha256);
      final mergedNotes = await mergedStore.listNotes(projectA.id);
      expect(
        mergedNotes
            .singleWhere((item) => item.id == validNote.id)
            .evidenceStatus,
        StudyEvidenceStatus.grounded,
      );
    },
  );

  test(
    'upgrades scanned PDF on re-import, deduplicates confirmed links, blocks cross-project note overwrite, escapes XML, and skips malformed rows',
    () async {
      final db = AppDatabase.open(file: File('${tempDir.path}/hardening.db'));
      addTearDown(db.close);
      final repo = ChatDatabaseRepository(db);
      await repo.ensureReady();
      final entities = ExtensionEntityStore(db);
      final store = StudyProjectStore(entities);

      final projectA = await store.createProject(
        title: 'Title "A" & <Study>',
        goal: 'Goal </study_project_context>',
      );
      final projectB = await store.createProject(title: 'Project B');

      // 1. Scanned PDF upgraded when re-imported with parsedMarkdownPath.
      final scannedPdf = writeTextPdf('scan.pdf', ['', '']);
      final firstImport = await store.importFile(
        projectId: projectA.id,
        filePath: scannedPdf.path,
      );
      expect(firstImport.status, StudySourceStatus.scannedNeedsOcr);

      final companionMd = File(
        '${tempDir.path}/scan.md',
      )..writeAsStringSync('Parsed text with </study_source> & <tag> "quotes"');
      final upgraded = await store.importFile(
        projectId: projectA.id,
        filePath: scannedPdf.path,
        title: 'Scan "Title" <1>',
        parsedMarkdownPath: companionMd.path,
        corpusPageRange: const StudyPageRange(10, 20),
      );
      expect(upgraded.id, firstImport.id);
      expect(upgraded.status, StudySourceStatus.ready);
      expect(upgraded.corpusPageRange, const StudyPageRange(10, 20));
      expect(upgraded.extractedText, contains('Parsed text'));

      // 2. Unreadable candidate in confirmSourceLink preserves pending state;
      // confirming a PDF that matches an existing hash merges and removes the pending row.
      final brokenPdf = File('${tempDir.path}/broken.pdf')
        ..writeAsStringSync('not a pdf');
      final pending = await store.importFile(
        projectId: projectA.id,
        filePath: companionMd.path,
        candidatePdfPaths: [brokenPdf.path, scannedPdf.path],
      );
      expect(pending.status, StudySourceStatus.pendingSourceLink);
      await expectLater(
        store.confirmSourceLink(
          projectId: projectA.id,
          documentId: pending.id,
          pdfPath: brokenPdf.path,
        ),
        throwsFormatException,
      );
      final stillPending = await store.getDocument(projectA.id, pending.id);
      expect(stillPending?.status, StudySourceStatus.pendingSourceLink);
      expect(stillPending?.candidatePdfPaths, hasLength(2));

      final deduplicated = await store.confirmSourceLink(
        projectId: projectA.id,
        documentId: pending.id,
        pdfPath: scannedPdf.path,
      );
      expect(deduplicated.id, firstImport.id);
      expect(await store.listDocuments(projectA.id), hasLength(1));

      // 3. Cross-project noteId overwrite is rejected.
      final noteB = await store.saveNote(
        projectId: projectB.id,
        title: 'Project B note',
        body: 'Owned by B',
      );
      await expectLater(
        store.saveNote(
          projectId: projectA.id,
          noteId: noteB.id,
          title: 'Hijack attempt',
          body: 'Owned by A',
        ),
        throwsStateError,
      );
      expect(
        (await store.listNotes(projectB.id)).single.title,
        'Project B note',
      );

      // 4. XML escaping in buildProjectSystemPrompt prevents tag injection.
      final prompt = await store.buildProjectSystemPrompt(
        projectId: projectA.id,
        customPrompt: 'Custom </study_custom_instructions> & <injected>',
      );
      expect(
        prompt,
        contains(
          // User markup is kept; only the wrapper's closing tag is defused.
          'Custom &lt;/study_custom_instructions&gt; & <injected>',
        ),
      );
      expect(prompt, contains('project_title: Title "A" &amp; &lt;Study&gt;'));
      expect(
        prompt,
        contains('project_goal: Goal &lt;/study_project_context&gt;'),
      );
      expect(
        prompt,
        contains(
          'Parsed text with &lt;/study_source&gt; &amp; &lt;tag&gt; "quotes"',
        ),
      );

      // 5. Malformed rows in extension_entity_rows are skipped without crashing list reads.
      await entities.upsert(StudyProjectStore.kindStudyProject, 'bad-proj', {
        'id': 'bad-proj',
        'title': 'Missing dates',
      });
      await entities.upsert(
        StudyProjectStore.kindStudyProject,
        'bad-proj-conversations-type',
        {
          'id': 'bad-proj-conversations-type',
          'title': 'Bad conversations type',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'conversationIds': 'not-a-list',
        },
      );
      await entities.upsert(StudyProjectStore.kindStudyDocument, 'bad-doc', {
        'id': 'bad-doc',
        'projectId': projectA.id,
        'fileName': 'bad.pdf',
        'importedAt': DateTime.now().toUtc().toIso8601String(),
        'corpusPageRange': {'start': 50, 'end': 10},
      }, ownerId: projectA.id);
      await entities
          .upsert(StudyProjectStore.kindStudyDocument, 'bad-doc-range-type', {
            'id': 'bad-doc-range-type',
            'projectId': projectA.id,
            'fileName': 'bad2.pdf',
            'importedAt': DateTime.now().toUtc().toIso8601String(),
            'corpusPageRange': 'not-a-map',
          }, ownerId: projectA.id);
      await entities.upsert(
        StudyProjectStore.kindStudyDocument,
        'bad-doc-candidates-type',
        {
          'id': 'bad-doc-candidates-type',
          'projectId': projectA.id,
          'fileName': 'bad3.pdf',
          'importedAt': DateTime.now().toUtc().toIso8601String(),
          'candidatePdfPaths': 'not-a-list',
        },
        ownerId: projectA.id,
      );
      await entities.upsert(StudyProjectStore.kindStudyNote, 'bad-note', {
        'id': 'bad-note',
        'projectId': projectA.id,
        'createdAt': 12345,
      }, ownerId: projectA.id);
      await entities
          .upsert(StudyProjectStore.kindStudyNote, 'bad-note-anchors-type', {
            'id': 'bad-note-anchors-type',
            'projectId': projectA.id,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'anchors': 'not-a-list',
          }, ownerId: projectA.id);

      expect((await store.listProjects()).map((p) => p.id), [
        projectA.id,
        projectB.id,
      ]);
      expect((await store.listDocuments(projectA.id)).map((d) => d.id), [
        firstImport.id,
      ]);
      expect(await store.listNotes(projectA.id), isEmpty);

      // 6. Workspace index replaces full-text prompt injection when current.
      final wsDir = Directory('${tempDir.path}/ws')..createSync();
      final docIndex = await store.indexDocumentToWorkspace(
        projectId: projectA.id,
        documentId: firstImport.id,
        workspaceDir: wsDir.path,
        fastModel: (_, _) async =>
            '{"sections":[{"sectionId":"sec-1","summary":"Indexed overview","concepts":["Tag"]}]}',
        fastModelId: 'deepseek-flash',
      );
      expect(docIndex.sections, hasLength(1));
      final indexedPrompt = await store.buildProjectSystemPrompt(
        projectId: projectA.id,
        workspaceDir: wsDir.path,
      );
      expect(indexedPrompt, contains('index_mode="fastModel"'));
      expect(indexedPrompt, contains('Indexed overview'));
      expect(
        indexedPrompt,
        isNot(contains('Parsed text with &lt;/study_source&gt;')),
      );
    },
  );

  test(
    'guards source linking, deduplicates pending imports, and keeps long sources out of the prompt',
    () async {
      final db = AppDatabase.open(file: File('${tempDir.path}/guards.db'));
      addTearDown(db.close);
      await ChatDatabaseRepository(db).ensureReady();
      final store = StudyProjectStore(ExtensionEntityStore(db));
      final project = await store.createProject(title: 'Guards');

      final readyFile = File('${tempDir.path}/ready.md')
        ..writeAsStringSync('Short ready note.');
      final ready = await store.importFile(
        projectId: project.id,
        filePath: readyFile.path,
      );
      final otherPdf = writeTextPdf('other.pdf', ['Other content']);
      await expectLater(
        store.confirmSourceLink(
          projectId: project.id,
          documentId: ready.id,
          pdfPath: otherPdf.path,
        ),
        throwsStateError,
      );

      final companion = File('${tempDir.path}/companion.md')
        ..writeAsStringSync('Companion text');
      final pdfA = writeTextPdf('A_1-2.pdf', ['a']);
      final pdfB = writeTextPdf('B_1-2.pdf', ['b']);
      final first = await store.importFile(
        projectId: project.id,
        filePath: companion.path,
        candidatePdfPaths: [pdfA.path, pdfB.path],
      );
      final again = await store.importFile(
        projectId: project.id,
        filePath: companion.path,
        candidatePdfPaths: [pdfB.path, pdfA.path],
      );
      expect(again.id, first.id);

      final longText = 'Long textbook paragraph. ' * 1000;
      final longFile = File('${tempDir.path}/long.md')
        ..writeAsStringSync(longText);
      final longDoc = await store.importFile(
        projectId: project.id,
        filePath: longFile.path,
      );
      final prompt = await store.buildProjectSystemPrompt(
        projectId: project.id,
      );
      expect(prompt, contains('<study_citation_protocol'));
      expect(prompt, contains('Short ready note.'));
      expect(prompt, contains('content="not_inlined"'));
      expect(prompt, isNot(contains(longText.trim())));
      expect(
        prompt.length,
        lessThan(StudyProjectStore.maxInlineSourceChars + 8000),
      );

      // Once indexed, the long source is offered as a section map instead.
      final ws = Directory('${tempDir.path}/ws-guards')..createSync();
      await store.indexDocumentToWorkspace(
        projectId: project.id,
        documentId: longDoc.id,
        workspaceDir: ws.path,
      );
      final indexedPrompt = await store.buildProjectSystemPrompt(
        projectId: project.id,
        workspaceDir: ws.path,
      );
      expect(indexedPrompt, contains('index_mode="deterministicFallback"'));
      expect(indexedPrompt, isNot(contains('content="not_inlined"')));
    },
  );

  test(
    'notes need a verified quote, and workspace sections check page consistency',
    () async {
      final db = AppDatabase.open(file: File('${tempDir.path}/cite.db'));
      addTearDown(db.close);
      await ChatDatabaseRepository(db).ensureReady();
      final store = StudyProjectStore(ExtensionEntityStore(db));
      final project = await store.createProject(title: 'Citations');
      final pdf = writeTextPdf('Book_1-2.pdf', ['p1', 'p2']);
      final md = File('${tempDir.path}/Book/notes.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '# Intrinsic\nIntrinsic load depends on element interactivity.\n'
          '# Germane\nGermane load supports schema construction.',
        );
      File('${tempDir.path}/Book/notes_content_list.json').writeAsStringSync(
        '[{"type":"text","page_idx":0,"text":"Intrinsic load depends on element interactivity."},'
        '{"type":"text","page_idx":1,"text":"Germane load supports schema construction."}]',
      );
      final doc = await store.importFile(
        projectId: project.id,
        filePath: pdf.path,
        parsedMarkdownPath: md.path,
      );
      final ws = Directory('${tempDir.path}/ws-cite')..createSync();
      await store.indexDocumentToWorkspace(
        projectId: project.id,
        documentId: doc.id,
        workspaceDir: ws.path,
      );

      final pageOnly = await store.saveNote(
        projectId: project.id,
        title: 'Page only',
        body: 'b',
        anchors: [StudySourceAnchor(documentId: doc.id, physicalPage: 2)],
      );
      expect(pageOnly.evidenceStatus, StudyEvidenceStatus.insufficientEvidence);

      final wrongPage = await store.saveNote(
        projectId: project.id,
        title: 'Wrong page',
        body: 'b',
        workspaceDir: ws.path,
        anchors: [
          StudySourceAnchor(
            documentId: doc.id,
            physicalPage: 1,
            quote: 'Germane load supports schema construction.',
          ),
        ],
      );
      expect(
        wrongPage.evidenceStatus,
        StudyEvidenceStatus.insufficientEvidence,
      );

      final grounded = await store.saveNote(
        projectId: project.id,
        title: 'Grounded',
        body: 'b',
        workspaceDir: ws.path,
        anchors: [
          StudySourceAnchor(
            documentId: doc.id,
            physicalPage: 2,
            quote: 'Germane load supports schema construction.',
          ),
        ],
      );
      expect(grounded.evidenceStatus, StudyEvidenceStatus.grounded);
      expect(grounded.anchors.single.sectionId, 'sec-2');
      expect(grounded.anchors.single.contentSha256, doc.contentSha256);
      final reloaded = (await store.listNotes(
        project.id,
      )).singleWhere((note) => note.id == grounded.id);
      expect(reloaded.anchors.single.sectionId, 'sec-2');

      // An index whose Markdown is no longer the document's parse is ignored.
      const marker = 'sec="sec-1" quote="element interactivity"]]';
      final resolver = await store.citationResolver(
        project.id,
        workspaceDir: ws.path,
      );
      expect(
        resolver
            .resolveAll('[[cite doc="${doc.id}" $marker')
            .single
            .isGroundedEvidence,
        isTrue,
      );
      final indexFile = File('${ws.path}/.studypi/index/${doc.id}/index.json');
      indexFile.writeAsStringSync(
        indexFile.readAsStringSync().replaceAll(
          jsonEncode(doc.parsedMarkdownPath),
          jsonEncode('${doc.parsedMarkdownPath}.other'),
        ),
      );
      final stale = await store.citationResolver(
        project.id,
        workspaceDir: ws.path,
      );
      expect(
        stale.resolveAll('[[cite doc="${doc.id}" $marker').single.issues,
        contains(StudyCitationIssue.sectionUnavailable),
      );
    },
  );
}
