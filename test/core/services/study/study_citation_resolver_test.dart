import 'dart:io';

import 'package:Kelivo/core/services/study/study_citation_resolver.dart';
import 'package:Kelivo/core/services/study/study_corpus.dart';
import 'package:Kelivo/core/services/study/study_mineru_indexer.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:flutter_test/flutter_test.dart';

StudySourceDocument _doc({
  String id = 'doc-a',
  StudySourceStatus status = StudySourceStatus.ready,
  String? sha = 'sha-a',
  int? pages = 10,
  StudyPageRange? corpus = const StudyPageRange(92, 101),
  String? text,
}) {
  return StudySourceDocument(
    id: id,
    projectId: 'p',
    title: 'Book',
    fileName: 'book.pdf',
    format: StudySourceFormat.pdf,
    status: status,
    contentSha256: sha,
    byteLength: 1,
    originalPath: '/tmp/book.pdf',
    parsedMarkdownPath: '/tmp/book.md',
    candidatePdfPaths: const [],
    physicalPageCount: pages,
    corpusPageRange: corpus,
    extractedText: text,
    importedAt: DateTime.utc(2026),
  );
}

StudyIndexedSection _section(
  String id,
  int start,
  int end, {
  StudyPageRange? pages,
}) {
  return StudyIndexedSection(
    sectionId: id,
    headingPath: [id],
    startLine: start,
    endLine: end,
    charCount: 0,
    physicalPageRange: pages,
    corpusPageRange: null,
    formulas: const [],
    concepts: const [],
    questions: const [],
    summary: '',
  );
}

StudyDocumentIndex _index(List<StudyIndexedSection> sections) {
  return StudyDocumentIndex(
    documentId: 'doc-a',
    title: 'Book',
    markdownPath: '/tmp/book.md',
    markdownSha256: 'md',
    pdfPath: '/tmp/book.pdf',
    pdfSha256: 'sha-a',
    corpusPageRange: const StudyPageRange(92, 101),
    indexMode: StudyIndexMode.deterministicFallback,
    modelId: null,
    indexedAt: DateTime.utc(2026),
    sections: sections,
  );
}

const _lines = [
  '# Intrinsic load', // 1
  'Intrinsic load depends on element interactivity.', // 2
  'Shared sentence about schemas.', // 3
  '# Germane load', // 4
  'Germane load supports **schema** construction.', // 5
  'Shared sentence about schemas.', // 6
];

void main() {
  group('parse', () {
    test('reads attributes, escapes and offsets', () {
      const text =
          'Claim. [[cite doc="doc-a" sec="sec-2" page="3" book_page="94" '
          r'quote="He said \"germane\""]] Next.';
      final citations = StudyCitationSyntax.parse(text);
      expect(citations, hasLength(1));
      final c = citations.single;
      expect(c.documentId, 'doc-a');
      expect(c.sectionId, 'sec-2');
      expect(c.physicalPage, 3);
      expect(c.corpusPage, 94);
      expect(c.quote, 'He said "germane"');
      expect(c.malformed, isFalse);
      expect(text.substring(c.start, c.end), startsWith('[[cite '));
      expect(text.substring(c.start, c.end), endsWith(']]'));
      expect(StudyCitationSyntax.parse(c.format()).single.quote, c.quote);
    });

    test('ignores markers inside code fences and inline code', () {
      const text =
          '```\n[[cite doc="in-fence"]]\n```\n'
          'Use `[[cite doc="inline"]]` like this. '
          '[[cite doc="real" quote="abcdef"]]\n'
          '~~~~md\n[[cite doc="tilde"]]\n~~~\nstill fenced [[cite doc="x"]]\n~~~~\n';
      final ids = StudyCitationSyntax.parse(
        text,
      ).map((c) => c.documentId).toList();
      expect(ids, ['real']);
    });

    test('flags malformed markers without swallowing the rest', () {
      const text =
          '[[cite doc="a" page="twelve"]] [[cite quote="no doc"]] '
          '[[cite doc="b" broken]] [[citex doc="c"]] [[cite doc="d" quote="ok ok"]]';
      final citations = StudyCitationSyntax.parse(text);
      expect(citations.map((c) => c.malformed), [true, true, true, false]);
      expect(citations.last.documentId, 'd');
    });

    test('unterminated marker is not a citation', () {
      expect(StudyCitationSyntax.parse('[[cite doc="a" quote="x'), isEmpty);
    });
  });

  group('resolve', () {
    StudyCitationResolver resolver({
      List<StudySourceDocument>? docs,
      Map<String, StudyDocumentIndex>? indexes,
    }) {
      return StudyCitationResolver(
        documents: docs ?? [_doc(text: _lines.join('\n'))],
        indexes:
            indexes ??
            {
              'doc-a': _index([
                _section('sec-1', 1, 3, pages: const StudyPageRange(1, 2)),
                _section('sec-2', 4, 6, pages: const StudyPageRange(3, 4)),
              ]),
            },
        readIndexedLines: (_) => _lines,
      );
    }

    StudyResolvedCitation one(StudyCitationResolver r, String marker) =>
        r.resolveAll(marker).single;

    test('verifies section, pages and quote together', () {
      final result = one(
        resolver(),
        '[[cite doc="doc-a" sec="sec-2" page="3" book_page="94" '
        'quote="Germane load supports schema construction."]]',
      );
      expect(result.issues, isEmpty);
      expect(result.isGroundedEvidence, isTrue);
      expect(result.quoteScope, StudyQuoteScope.section);
      expect(result.toAnchor().contentSha256, 'sha-a');
    });

    test('textbook page used as PDF page is rejected', () {
      final result = one(
        resolver(),
        '[[cite doc="doc-a" page="94" quote="element interactivity"]]',
      );
      expect(
        result.issues,
        contains(StudyCitationIssue.physicalPageOutOfRange),
      );
      expect(result.isGroundedEvidence, isFalse);
    });

    test('quote from another section of the same book is caught', () {
      final result = one(
        resolver(),
        '[[cite doc="doc-a" sec="sec-1" quote="supports schema construction"]]',
      );
      expect(result.issues, [StudyCitationIssue.quoteNotFound]);
    });

    test('page that contradicts the located section is caught', () {
      final result = one(
        resolver(),
        '[[cite doc="doc-a" page="1" quote="supports schema construction"]]',
      );
      expect(result.section?.sectionId, 'sec-2');
      expect(result.issues, [StudyCitationIssue.physicalPageOutsideSection]);
    });

    test('repeated sentence is located by its page', () {
      final r = resolver();
      final onFirst = one(
        r,
        '[[cite doc="doc-a" page="2" quote="Shared sentence about schemas."]]',
      );
      expect(onFirst.section?.sectionId, 'sec-1');
      expect(onFirst.isGroundedEvidence, isTrue);
      final noPage = one(
        r,
        '[[cite doc="doc-a" quote="Shared sentence about schemas."]]',
      );
      expect(noPage.section, isNull);
      expect(noPage.quoteScope, StudyQuoteScope.document);
      expect(noPage.isGroundedEvidence, isTrue);
    });

    test('locator-only citations are verified but not evidence', () {
      final result = one(
        resolver(),
        '[[cite doc="doc-a" sec="sec-1" page="2"]]',
      );
      expect(result.verified, isTrue);
      expect(result.isGroundedEvidence, isFalse);
      expect(
        one(resolver(), '[[cite doc="doc-a"]]').issues,
        contains(StudyCitationIssue.missingLocator),
      );
    });

    test('unknown, unready and changed sources are not verified', () {
      final r = resolver(
        docs: [
          _doc(text: _lines.join('\n')),
          _doc(id: 'pending', status: StudySourceStatus.pendingSourceLink),
        ],
      );
      expect(one(r, '[[cite doc="nope" quote="abcdef"]]').issues, [
        StudyCitationIssue.unknownDocument,
      ]);
      expect(one(r, '[[cite doc="pending" quote="abcdef"]]').issues, [
        StudyCitationIssue.documentNotReady,
      ]);
      final stale = r.resolve(
        const StudyCitation(
          documentId: 'doc-a',
          contentSha256: 'old',
          quote: 'element interactivity',
        ),
      );
      expect(stale.issues, [StudyCitationIssue.sourceVersionMismatch]);
    });

    test('sections cannot be checked without a current index', () {
      final r = resolver(indexes: const {});
      expect(
        one(
          r,
          '[[cite doc="doc-a" sec="sec-2" quote="schema construction"]]',
        ).issues,
        [StudyCitationIssue.sectionUnavailable],
      );
      final changed = StudyCitationResolver(
        documents: [_doc(text: _lines.join('\n'))],
        indexes: {
          'doc-a': _index([_section('sec-1', 1, 3)]),
        },
        readIndexedLines: (_) => null,
      );
      expect(
        changed
            .resolveAll(
              '[[cite doc="doc-a" sec="sec-1" quote="element interactivity"]]',
            )
            .single
            .issues,
        [StudyCitationIssue.sectionUnavailable],
      );
    });

    test('very short quotes and corpus pages outside the slice fail', () {
      expect(one(resolver(), '[[cite doc="doc-a" quote="load"]]').issues, [
        StudyCitationIssue.quoteTooShort,
      ]);
      expect(
        one(
          resolver(),
          '[[cite doc="doc-a" book_page="3" quote="element interactivity"]]',
        ).issues,
        [StudyCitationIssue.corpusPageOutOfRange],
      );
    });

    test('keeps word boundaries in Latin text but not in Chinese', () {
      final r = StudyCitationResolver(
        documents: [_doc(text: 'He met the rapist in court.\n工作记忆的容量\n是有限的。')],
      );
      expect(
        r
            .resolveAll('[[cite doc="doc-a" quote="met therapist"]]')
            .single
            .issues,
        [StudyCitationIssue.quoteNotFound],
      );
      expect(
        r
            .resolveAll('[[cite doc="doc-a" quote="met the  rapist"]]')
            .single
            .isGroundedEvidence,
        isTrue,
      );
      expect(
        r
            .resolveAll('[[cite doc="doc-a" quote="工作记忆的容量是有限的"]]')
            .single
            .isGroundedEvidence,
        isTrue,
      );
    });

    test('tolerates wrapping, emphasis and curly quotes', () {
      final r = StudyCitationResolver(
        documents: [
          _doc(text: 'The “testing effect” is\nrobust across **many** tasks.'),
        ],
      );
      final result = r
          .resolveAll(
            '[[cite doc="doc-a" quote="The \\"testing effect\\" is robust across many tasks."]]',
          )
          .single;
      expect(result.isGroundedEvidence, isTrue);
    });
  });

  test('reads real index files and rejects edited Markdown', () async {
    final dir = Directory.systemTemp.createTempSync('studypi-cite-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final md = File('${dir.path}/book.md')
      ..writeAsStringSync(_lines.join('\n'));
    final index = await StudyMineruIndexer.indexToWorkspace(
      documentId: 'doc-a',
      title: 'Book',
      markdownPath: md.path,
      workspaceDir: dir.path,
    );
    final docs = [_doc(text: _lines.join('\n'))];
    const marker =
        '[[cite doc="doc-a" sec="sec-2" quote="supports schema construction"]]';
    expect(
      StudyCitationResolver(
        documents: docs,
        indexes: {'doc-a': index},
      ).resolveAll(marker).single.isGroundedEvidence,
      isTrue,
    );
    md.writeAsStringSync('rewritten');
    expect(
      StudyCitationResolver(
        documents: docs,
        indexes: {'doc-a': index},
      ).resolveAll(marker).single.issues,
      [StudyCitationIssue.sectionUnavailable],
    );
  });
}
