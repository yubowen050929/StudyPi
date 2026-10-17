import 'dart:convert';
import 'dart:io';

/// A page span parsed from a file or directory name, such as `92-206`.
class StudyPageRange {
  const StudyPageRange(this.start, this.end);

  final int start;
  final int end;

  /// Label used in material titles. The dash is an em dash, matching the
  /// existing study library's document names.
  String get label => '$start—$end';

  @override
  bool operator ==(Object other) =>
      other is StudyPageRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

enum StudyMaterialKind { textbook, guide }

enum StudyMaterialScope { slice, whole }

/// One readable source. Paths point at the user's files and are not copied.
class StudyMaterial {
  const StudyMaterial({
    required this.id,
    required this.kind,
    required this.scope,
    required this.title,
    required this.pageRange,
    required this.pdfPath,
    required this.markdownPath,
    required this.pdfBytes,
  });

  final String id;
  final StudyMaterialKind kind;
  final StudyMaterialScope scope;
  final String title;
  final StudyPageRange? pageRange;
  final String? pdfPath;
  final String? markdownPath;
  final int? pdfBytes;
}

/// Counts from an existing `import-bundle.json`. Body text stays in that file.
class StudyBundleCounts {
  const StudyBundleCounts({
    required this.documents,
    required this.questions,
    required this.chunks,
  });

  final int documents;
  final int questions;
  final int chunks;
}

class StudySubject {
  const StudySubject({
    required this.name,
    required this.path,
    required this.materials,
  });

  final String name;
  final String path;
  final List<StudyMaterial> materials;
}

class StudyCorpus {
  const StudyCorpus({
    required this.rootPath,
    required this.subjects,
    required this.bundle,
  });

  final String rootPath;
  final List<StudySubject> subjects;
  final StudyBundleCounts? bundle;
}

final _rangePattern = RegExp(r'(\d+)\s*[-–—]\s*(\d+)');
const _ignoredDirectories = {
  '.git',
  '.scratch',
  'backups',
  'infra',
  'node_modules',
  'output',
  'study-app',
};

/// Index textbook and lecture files under [rootPath].
///
/// [rootPath] may be one subject directory, or a parent that contains subject
/// directories. A subject has `教材` and/or `讲解`, each with `PDF` files and
/// optional `AI专用` Markdown parses. Whole-book PDFs are kept separate from
/// page-range slices. Two slices may share one PDF when the filename contains
/// both ranges.
StudyCorpus scanStudyCorpus(String rootPath) {
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    throw ArgumentError('Study corpus path does not exist: $rootPath');
  }
  final subjects = _subjectDirectories(root).map(_scanSubject).toList();
  return StudyCorpus(
    rootPath: root.absolute.path,
    subjects: subjects,
    bundle: _readBundleCounts(_findBundle(root)),
  );
}

List<Directory> _subjectDirectories(Directory root) {
  if (_isSubject(root)) return [root];
  final found = <Directory>[];
  for (final entity in root.listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final name = _baseName(entity.path);
    if (name.startsWith('.') || _ignoredDirectories.contains(name)) continue;
    if (_isSubject(entity)) found.add(entity);
  }
  found.sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
  return found;
}

bool _isSubject(Directory directory) {
  return Directory(
        '${directory.path}${Platform.pathSeparator}教材',
      ).existsSync() ||
      Directory('${directory.path}${Platform.pathSeparator}讲解').existsSync();
}

StudySubject _scanSubject(Directory directory) {
  final materials = <StudyMaterial>[
    ..._scanCollection(
      directory: Directory('${directory.path}${Platform.pathSeparator}教材'),
      kind: StudyMaterialKind.textbook,
      sliceTitle: (range) => '教材 · ${range.label}页',
    ),
    ..._scanCollection(
      directory: Directory('${directory.path}${Platform.pathSeparator}讲解'),
      kind: StudyMaterialKind.guide,
      sliceTitle: (range) => '习题讲解 · ${range.label}页',
    ),
  ];
  return StudySubject(
    name: _baseName(directory.path),
    path: directory.absolute.path,
    materials: materials,
  );
}

List<StudyMaterial> _scanCollection({
  required Directory directory,
  required StudyMaterialKind kind,
  required String Function(StudyPageRange range) sliceTitle,
}) {
  if (!directory.existsSync()) return const [];
  final pdfs = _pdfs(directory);
  final markdowns = _markdownBuckets(directory);
  final usedPdfs = <String>{};
  final materials = <StudyMaterial>[];

  final slices = markdowns.where((item) => item.range != null).toList()
    ..sort((a, b) => a.range!.start.compareTo(b.range!.start));
  for (final markdown in slices) {
    final pdf = _matchPdf(markdown.range!, pdfs);
    if (pdf != null) usedPdfs.add(pdf.path);
    materials.add(
      _material(
        kind: kind,
        scope: StudyMaterialScope.slice,
        title: sliceTitle(markdown.range!),
        range: markdown.range,
        pdf: pdf,
        markdownPath: markdown.path,
      ),
    );
  }

  final slicePdfs =
      pdfs
          .where((pdf) => pdf.ranges.isNotEmpty && !usedPdfs.contains(pdf.path))
          .toList()
        ..sort((a, b) => a.ranges.first.start.compareTo(b.ranges.first.start));
  for (final pdf in slicePdfs) {
    final range = pdf.ranges.length == 1 ? pdf.ranges.single : null;
    materials.add(
      _material(
        kind: kind,
        scope: StudyMaterialScope.slice,
        title: range == null ? _stem(pdf.path) : sliceTitle(range),
        range: range,
        pdf: pdf,
        markdownPath: null,
      ),
    );
  }

  for (final pdf in pdfs.where((pdf) => pdf.ranges.isEmpty)) {
    materials.add(
      _material(
        kind: kind,
        scope: StudyMaterialScope.whole,
        title: _stem(pdf.path),
        range: null,
        pdf: pdf,
        markdownPath: null,
      ),
    );
  }

  for (final markdown in markdowns.where((item) => item.range == null)) {
    materials.add(
      _material(
        kind: kind,
        scope: StudyMaterialScope.slice,
        title: _stem(markdown.path),
        range: null,
        pdf: null,
        markdownPath: markdown.path,
      ),
    );
  }

  _assignIds(kind, materials);
  return materials;
}

class _PdfFile {
  const _PdfFile(this.path, this.ranges, this.bytes);

  final String path;
  final List<StudyPageRange> ranges;
  final int bytes;
}

class _MarkdownFile {
  const _MarkdownFile(this.path, this.range);

  final String path;
  final StudyPageRange? range;
}

List<_PdfFile> _pdfs(Directory collection) {
  final pdfDir = Directory('${collection.path}${Platform.pathSeparator}PDF');
  if (!pdfDir.existsSync()) return const [];
  final files = <_PdfFile>[];
  for (final entity in pdfDir.listSync(followLinks: false)) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.pdf')) {
      continue;
    }
    files.add(
      _PdfFile(
        entity.absolute.path,
        _pageRanges(_baseName(entity.path)),
        entity.lengthSync(),
      ),
    );
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

List<_MarkdownFile> _markdownBuckets(Directory collection) {
  final parsed = Directory('${collection.path}${Platform.pathSeparator}AI专用');
  if (!parsed.existsSync()) return const [];
  final files = <_MarkdownFile>[];
  for (final entity in parsed.listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final markdown = _primaryMarkdown(entity);
    if (markdown == null) continue;
    final ranges = _pageRanges(_baseName(entity.path));
    files.add(
      _MarkdownFile(
        markdown.absolute.path,
        ranges.isEmpty ? null : ranges.first,
      ),
    );
  }
  return files;
}

File? _primaryMarkdown(Directory bucket) {
  final markdowns = bucket
      .listSync(followLinks: false)
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.md'))
      .toList();
  if (markdowns.isEmpty) return null;
  markdowns.sort((a, b) {
    final bySize = b.lengthSync().compareTo(a.lengthSync());
    if (bySize != 0) return bySize;
    return a.path.compareTo(b.path);
  });
  return markdowns.first;
}

_PdfFile? _matchPdf(StudyPageRange range, List<_PdfFile> pdfs) {
  final matches = pdfs.where((pdf) => pdf.ranges.contains(range)).toList();
  if (matches.isEmpty) return null;
  matches.sort((a, b) {
    final bySpecificity = a.ranges.length.compareTo(b.ranges.length);
    if (bySpecificity != 0) return bySpecificity;
    return a.path.compareTo(b.path);
  });
  return matches.first;
}

StudyMaterial _material({
  required StudyMaterialKind kind,
  required StudyMaterialScope scope,
  required String title,
  required StudyPageRange? range,
  required _PdfFile? pdf,
  required String? markdownPath,
}) {
  return StudyMaterial(
    id: '',
    kind: kind,
    scope: scope,
    title: title,
    pageRange: range,
    pdfPath: pdf?.path,
    markdownPath: markdownPath,
    pdfBytes: pdf?.bytes,
  );
}

void _assignIds(StudyMaterialKind kind, List<StudyMaterial> materials) {
  final used = <String>{};
  final prefix = kind == StudyMaterialKind.textbook ? 'textbook' : 'guide';
  for (var index = 0; index < materials.length; index++) {
    final material = materials[index];
    final range = material.pageRange;
    final base = material.scope == StudyMaterialScope.whole
        ? '$prefix-whole'
        : range == null
        ? '$prefix-unranged'
        : '$prefix-${range.start}';
    var id = base;
    var suffix = 2;
    while (!used.add(id)) {
      id = '$base-$suffix';
      suffix++;
    }
    materials[index] = StudyMaterial(
      id: id,
      kind: material.kind,
      scope: material.scope,
      title: material.title,
      pageRange: material.pageRange,
      pdfPath: material.pdfPath,
      markdownPath: material.markdownPath,
      pdfBytes: material.pdfBytes,
    );
  }
}

List<StudyPageRange> _pageRanges(String name) {
  return [
    for (final match in _rangePattern.allMatches(name))
      StudyPageRange(int.parse(match.group(1)!), int.parse(match.group(2)!)),
  ];
}

File? _findBundle(Directory root) {
  final candidates = [
    File(
      '${root.path}${Platform.pathSeparator}study-app${Platform.pathSeparator}output${Platform.pathSeparator}import-bundle.json',
    ),
    File(
      '${root.parent.path}${Platform.pathSeparator}study-app${Platform.pathSeparator}output${Platform.pathSeparator}import-bundle.json',
    ),
  ];
  for (final candidate in candidates) {
    if (candidate.existsSync()) return candidate;
  }
  return null;
}

StudyBundleCounts? _readBundleCounts(File? file) {
  if (file == null) return null;
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) return null;
  int lengthOf(String key) {
    final value = decoded[key];
    return value is List ? value.length : 0;
  }

  return StudyBundleCounts(
    documents: lengthOf('docs'),
    questions: lengthOf('questions'),
    chunks: lengthOf('chunks'),
  );
}

String _baseName(String path) {
  final separator = path.lastIndexOf(Platform.pathSeparator);
  return separator == -1 ? path : path.substring(separator + 1);
}

String _stem(String path) {
  final name = _baseName(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}
