import 'dart:convert';
import 'dart:io';

import 'package:Kelivo/core/services/study/study_corpus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('studypi-corpus-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('pairs page slices, shares a combined PDF, and keeps whole books', () {
    final subject = Directory('${root.path}/教育心理学')..createSync();
    _writePdf(subject, '教材/PDF/当代教育心理学_1-91-92-206.pdf', 30);
    _writePdf(subject, '教材/PDF/当代教育心理学_207-359.pdf', 10);
    _writePdf(subject, '教材/PDF/当代教育心理学全书.pdf', 80);
    _writeMarkdown(subject, '教材/AI专用/当代教育心理学_1-91', 'one');
    _writeMarkdown(subject, '教材/AI专用/当代教育心理学_92-206', 'two');
    _writeMarkdown(subject, '教材/AI专用/当代教育心理学_207-359', 'three');
    _writePdf(subject, '讲解/PDF/讲解_1-200.pdf', 12);
    _writePdf(subject, '讲解/PDF/讲解全书.pdf', 40);
    _writeMarkdown(subject, '讲解/AI专用/讲解_1-200', 'guide');
    _writeMarkdown(subject, '讲解/AI专用/讲解_缺原文', 'orphan');

    final corpus = scanStudyCorpus(root.path);

    expect(corpus.subjects, hasLength(1));
    expect(corpus.subjects.single.name, '教育心理学');
    final materials = corpus.subjects.single.materials;
    final byId = {for (final item in materials) item.id: item};

    expect(byId['textbook-1']!.title, '教材 · 1—91页');
    expect(byId['textbook-1']!.pdfPath, endsWith('当代教育心理学_1-91-92-206.pdf'));
    expect(byId['textbook-1']!.pdfBytes, 30);
    expect(byId['textbook-92']!.pdfPath, byId['textbook-1']!.pdfPath);
    expect(
      byId['textbook-92']!.markdownPath,
      endsWith('当代教育心理学_92-206${Platform.pathSeparator}notes.md'),
    );
    expect(byId['textbook-207']!.pdfPath, endsWith('当代教育心理学_207-359.pdf'));
    expect(byId['textbook-whole']!.scope, StudyMaterialScope.whole);
    expect(byId['textbook-whole']!.pdfPath, endsWith('当代教育心理学全书.pdf'));
    expect(byId['guide-1']!.title, '习题讲解 · 1—200页');
    expect(byId['guide-1']!.pdfPath, endsWith('讲解_1-200.pdf'));
    expect(byId['guide-whole']!.title, '讲解全书');
    expect(byId['guide-unranged']!.pdfPath, isNull);
    expect(byId['guide-unranged']!.markdownPath, endsWith('notes.md'));
    expect(corpus.bundle, isNull);
  });

  test(
    'reads bundle counts and skips backups, credentials, and the app tree',
    () {
      final subject = Directory('${root.path}/教育心理学')..createSync();
      _writePdf(subject, '教材/PDF/教材_1-2.pdf', 4);
      Directory('${root.path}/infra/credentials').createSync(recursive: true);
      File('${root.path}/infra/credentials/secret.txt').writeAsStringSync('no');
      Directory('${root.path}/backups').createSync();
      final bundle = File('${root.path}/study-app/output/import-bundle.json');
      bundle.parent.createSync(recursive: true);
      bundle.writeAsStringSync(
        jsonEncode({
          'docs': [
            {'id': 'a'},
            {'id': 'b'},
          ],
          'questions': [
            {'id': 'q'},
          ],
          'chunks': [
            {'id': 'c'},
            {'id': 'd'},
            {'id': 'e'},
          ],
        }),
      );

      final corpus = scanStudyCorpus(root.path);

      expect(corpus.subjects, hasLength(1));
      expect(corpus.subjects.single.materials.single.id, 'textbook-1');
      expect(corpus.bundle!.documents, 2);
      expect(corpus.bundle!.questions, 1);
      expect(corpus.bundle!.chunks, 3);
    },
  );

  test('rejects a missing path', () {
    expect(() => scanStudyCorpus('${root.path}/missing'), throwsArgumentError);
  });
}

void _writePdf(Directory subject, String relativePath, int bytes) {
  final file = File('${subject.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 1));
}

void _writeMarkdown(Directory subject, String bucket, String body) {
  final file = File('${subject.path}/$bucket/notes.md');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(body);
}
