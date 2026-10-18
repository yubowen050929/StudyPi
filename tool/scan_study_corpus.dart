import 'dart:io';

import 'package:Kelivo/core/services/study/study_corpus.dart';

/// Print the study materials found under a local corpus directory.
///
/// The files stay where they are. This does not copy textbook text into
/// the repository.
///
/// Usage:
///   dart run tool/scan_study_corpus.dart /path/to/corpus
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/scan_study_corpus.dart <corpus-directory>',
    );
    exitCode = 64;
    return;
  }
  final corpus = scanStudyCorpus(args.single);
  stdout.writeln(corpus.rootPath);
  if (corpus.subjects.isEmpty) {
    stdout.writeln('No subject directories with 教材 or 讲解.');
  }
  for (final subject in corpus.subjects) {
    stdout.writeln('${subject.name} (${subject.materials.length})');
    for (final material in subject.materials) {
      final pdf = material.pdfPath ?? 'no pdf';
      final markdown = material.markdownPath ?? 'no markdown';
      stdout.writeln('${material.id}\t${material.title}');
      stdout.writeln('  pdf: $pdf');
      stdout.writeln('  markdown: $markdown');
    }
  }
  final bundle = corpus.bundle;
  if (bundle != null) {
    stdout.writeln(
      'bundle: ${bundle.documents} documents, '
      '${bundle.questions} questions, ${bundle.chunks} chunks',
    );
  }
}
