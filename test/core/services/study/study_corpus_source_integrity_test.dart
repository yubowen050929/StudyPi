import 'dart:io';

import 'package:Kelivo/core/services/study/study_corpus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory subject;

  setUp(() {
    root = Directory.systemTemp.createTempSync('studypi-source-integrity-');
    subject = Directory('${root.path}/同一科目')..createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  List<StudyMaterial> scan() =>
      scanStudyCorpus(root.path).subjects.single.materials;

  test(
    'pairs a parse with its own book, not another book with the same pages',
    () {
      final otherPdf = _pdf(subject, 'BookA_1-20.pdf');
      final ownPdf = _pdf(subject, 'BookB_1-20.pdf');
      final markdown = _markdown(subject, 'BookB_1-20');

      final materials = scan();
      final parsed = materials.singleWhere((item) => item.markdownPath != null);
      expect(parsed.markdownPath, markdown.path);
      expect(parsed.pdfPath, ownPdf.path);
      expect(
        materials
            .singleWhere((item) => item.pdfPath == otherPdf.path)
            .markdownPath,
        isNull,
      );
    },
  );

  test(
    'keeps an unmatched parse separate even when only one PDF has its pages',
    () {
      final pdf = _pdf(subject, 'BookA_1-20.pdf');
      final markdown = _markdown(subject, 'BookB_1-20');

      final materials = scan();
      expect(materials, hasLength(2));
      expect(
        materials
            .singleWhere((item) => item.markdownPath == markdown.path)
            .pdfPath,
        isNull,
      );
      expect(
        materials.singleWhere((item) => item.pdfPath == pdf.path).markdownPath,
        isNull,
      );
    },
  );

  test('does not resolve ambiguous source names by filename order', () {
    _pdf(subject, 'BookA_1-20.pdf');
    _pdf(subject, 'BookA-1-20.pdf');
    final markdown = _markdown(subject, 'BookA_1-20');

    final materials = scan();
    expect(materials, hasLength(3));
    expect(
      materials
          .singleWhere((item) => item.markdownPath == markdown.path)
          .pdfPath,
      isNull,
    );
  });

  test('preserves separators inside book names when identifying a source', () {
    _pdf(subject, 'BookA_1-20.pdf');
    final ownPdf = _pdf(subject, 'Book-A_1-20.pdf');
    _markdown(subject, 'Book-A_1-20');

    final parsed = scan().singleWhere((item) => item.markdownPath != null);
    expect(parsed.pdfPath, ownPdf.path);
  });

  test('accepts page-dash and trailing-separator variations', () {
    final pdf = _pdf(subject, 'Book Name_1—20.pdf');
    _markdown(subject, 'Book Name-1-20');

    expect(scan().single.pdfPath, pdf.path);
  });

  test(
    'prefers a unique dedicated slice over a combined PDF of the same book',
    () {
      _pdf(subject, 'Book_1-10-11-20.pdf');
      final dedicated = _pdf(subject, 'Book_1-10.pdf');
      _markdown(subject, 'Book_1-10');

      final parsed = scan().singleWhere((item) => item.markdownPath != null);
      expect(parsed.pdfPath, dedicated.path);
      expect(
        scan().any((item) => item.pageRange == const StudyPageRange(11, 20)),
        isTrue,
      );
    },
  );

  test('retains the unparsed range of a combined PDF', () {
    final pdf = _pdf(subject, 'Book_1-10-11-20.pdf');
    final markdown = _markdown(subject, 'Book_1-10');

    final materials = scan();
    expect(materials, hasLength(2));
    final first = materials.singleWhere((item) => item.pageRange?.start == 1);
    final remaining = materials.singleWhere(
      (item) => item.pageRange?.start == 11,
    );
    expect(first.markdownPath, markdown.path);
    expect(first.pdfPath, pdf.path);
    expect(remaining.pageRange, const StudyPageRange(11, 20));
    expect(remaining.pdfPath, pdf.path);
    expect(remaining.markdownPath, isNull);
  });

  test('indexes every range covered by one combined parse', () {
    final pdf = _pdf(subject, 'Book_1-10-11-20.pdf');
    final markdown = _markdown(subject, 'Book_1-10-11-20');

    final materials = scan();
    expect(materials.map((item) => item.pageRange), [
      const StudyPageRange(1, 10),
      const StudyPageRange(11, 20),
    ]);
    expect(materials.every((item) => item.pdfPath == pdf.path), isTrue);
    expect(
      materials.every((item) => item.markdownPath == markdown.path),
      isTrue,
    );
    expect(materials.map((item) => item.id).toSet(), hasLength(2));
  });

  test('indexes each PDF range even without any parse', () {
    final pdf = _pdf(subject, 'Book_1-10-11-20.pdf');

    final materials = scan();
    expect(materials.map((item) => item.pageRange), [
      const StudyPageRange(1, 10),
      const StudyPageRange(11, 20),
    ]);
    expect(materials.every((item) => item.pdfPath == pdf.path), isTrue);
  });

  test('a trailing separator does not erase the subject name', () {
    _pdf(subject, 'Book_1-20.pdf');

    final corpus = scanStudyCorpus('${subject.path}${Platform.pathSeparator}');
    expect(corpus.subjects.single.name, '同一科目');
  });

  test('does not pair page-only filenames that lack a book title', () {
    for (final (pdfName, bucketName) in [
      ('1-20.pdf', '1-20'),
      ('_-1-20.pdf', '—_1-20'),
    ]) {
      if (subject.existsSync()) subject.deleteSync(recursive: true);
      subject.createSync();
      final pdf = _pdf(subject, pdfName);
      final markdown = _markdown(subject, bucketName);

      final materials = scan();
      expect(materials, hasLength(2));
      expect(
        materials
            .singleWhere((item) => item.markdownPath == markdown.path)
            .pdfPath,
        isNull,
      );
      expect(
        materials.singleWhere((item) => item.pdfPath == pdf.path).markdownPath,
        isNull,
      );
    }
  });

  test('ignores reversed or zero page spans when parsing ranges', () {
    final reversedPdf = _pdf(subject, 'Book_20-1.pdf');
    final zeroPdf = _pdf(subject, 'Book_0-10.pdf');
    final markdown = _markdown(subject, 'Book_20-1');

    final materials = scan();
    expect(
      materials.singleWhere((item) => item.pdfPath == reversedPdf.path).scope,
      StudyMaterialScope.whole,
    );
    expect(
      materials.singleWhere((item) => item.pdfPath == zeroPdf.path).scope,
      StudyMaterialScope.whole,
    );
    expect(
      materials
          .singleWhere((item) => item.markdownPath == markdown.path)
          .pageRange,
      isNull,
    );
  });
}

File _pdf(Directory subject, String name) {
  final file = File('${subject.path}/教材/PDF/$name');
  file.parent.createSync(recursive: true);
  return file..writeAsBytesSync([1, 2, 3]);
}

File _markdown(Directory subject, String bucket) {
  final file = File('${subject.path}/教材/AI专用/$bucket/notes.md');
  file.parent.createSync(recursive: true);
  return file..writeAsStringSync('Parsed text');
}
