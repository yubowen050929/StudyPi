import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../utils/unicode_sanitizer.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import '../api/retry_policy.dart';
import '../api/tool_call_cancellation.dart';
import 'study_corpus.dart';

enum StudyIndexMode { fastModel, deterministicFallback }

typedef StudyFastModelCompletion =
    Future<String> Function(String systemPrompt, String userPrompt);

class StudyIndexedSection {
  const StudyIndexedSection({
    required this.sectionId,
    required this.headingPath,
    required this.startLine,
    required this.endLine,
    required this.charCount,
    required this.physicalPageRange,
    required this.corpusPageRange,
    required this.formulas,
    required this.concepts,
    required this.questions,
    required this.summary,
  });

  final String sectionId;
  final List<String> headingPath;
  final int startLine;
  final int endLine;
  final int charCount;
  final StudyPageRange? physicalPageRange;
  final StudyPageRange? corpusPageRange;
  final List<String> formulas;
  final List<String> concepts;
  final List<String> questions;
  final String summary;

  String get title => headingPath.isEmpty ? sectionId : headingPath.join(' > ');

  StudyIndexedSection copyWith({
    List<String>? concepts,
    List<String>? questions,
    String? summary,
  }) {
    return StudyIndexedSection(
      sectionId: sectionId,
      headingPath: headingPath,
      startLine: startLine,
      endLine: endLine,
      charCount: charCount,
      physicalPageRange: physicalPageRange,
      corpusPageRange: corpusPageRange,
      formulas: formulas,
      concepts: List<String>.unmodifiable(concepts ?? this.concepts),
      questions: List<String>.unmodifiable(questions ?? this.questions),
      summary: summary ?? this.summary,
    );
  }

  Map<String, dynamic> toJson() => {
    'sectionId': sectionId,
    'headingPath': headingPath,
    'startLine': startLine,
    'endLine': endLine,
    'charCount': charCount,
    if (physicalPageRange != null)
      'physicalPageRange': {
        'start': physicalPageRange!.start,
        'end': physicalPageRange!.end,
      },
    if (corpusPageRange != null)
      'corpusPageRange': {
        'start': corpusPageRange!.start,
        'end': corpusPageRange!.end,
      },
    'formulas': formulas,
    'concepts': concepts,
    'questions': questions,
    'summary': summary,
  };

  static StudyIndexedSection? tryFromJson(Map<String, dynamic> json) {
    final sectionId = _asNonEmptyString(json['sectionId']);
    final startLine = _asInt(json['startLine']);
    final endLine = _asInt(json['endLine']);
    final charCount = _asInt(json['charCount']);
    final summary = json['summary'];
    if (sectionId == null ||
        startLine == null ||
        endLine == null ||
        charCount == null ||
        startLine < 1 ||
        endLine < startLine ||
        charCount < 0 ||
        summary is! String) {
      return null;
    }
    final headingPath = _asStringList(json['headingPath']);
    final formulas = _asStringList(json['formulas']);
    final concepts = _asStringList(json['concepts']);
    final questions = _asStringList(json['questions']);
    if (headingPath == null ||
        formulas == null ||
        concepts == null ||
        questions == null) {
      return null;
    }
    final physicalResult = _parseOptionalRange(json['physicalPageRange']);
    final corpusResult = _parseOptionalRange(json['corpusPageRange']);
    if (!physicalResult.valid || !corpusResult.valid) {
      return null;
    }
    return StudyIndexedSection(
      sectionId: sectionId,
      headingPath: headingPath,
      startLine: startLine,
      endLine: endLine,
      charCount: charCount,
      physicalPageRange: physicalResult.range,
      corpusPageRange: corpusResult.range,
      formulas: formulas,
      concepts: concepts,
      questions: questions,
      summary: summary,
    );
  }
}

class StudyDocumentIndex {
  const StudyDocumentIndex({
    required this.documentId,
    required this.title,
    required this.markdownPath,
    required this.markdownSha256,
    required this.pdfPath,
    required this.pdfSha256,
    this.contentListSha256,
    required this.corpusPageRange,
    this.maxSectionChars = StudyMineruIndexer.defaultMaxSectionChars,
    required this.indexMode,
    required this.modelId,
    required this.indexedAt,
    required this.sections,
  });

  final String documentId;
  final String title;
  final String markdownPath;
  final String markdownSha256;
  final String? pdfPath;
  final String? pdfSha256;
  final String? contentListSha256;
  final StudyPageRange? corpusPageRange;
  final int maxSectionChars;
  final StudyIndexMode indexMode;
  final String? modelId;
  final DateTime indexedAt;
  final List<StudyIndexedSection> sections;

  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'title': title,
    'markdownPath': markdownPath,
    'markdownSha256': markdownSha256,
    'pdfPath': pdfPath,
    'pdfSha256': pdfSha256,
    'contentListSha256': contentListSha256,
    if (corpusPageRange != null)
      'corpusPageRange': {
        'start': corpusPageRange!.start,
        'end': corpusPageRange!.end,
      },
    'maxSectionChars': maxSectionChars,
    'indexMode': indexMode.name,
    'modelId': modelId,
    'indexedAt': indexedAt.toUtc().toIso8601String(),
    'sections': [for (final section in sections) section.toJson()],
  };

  static StudyDocumentIndex? tryFromJson(Map<String, dynamic> json) {
    final documentId = _asNonEmptyString(json['documentId']);
    final title = _asNonEmptyString(json['title']);
    final markdownPath = _asNonEmptyString(json['markdownPath']);
    final markdownSha256 = _asNonEmptyString(json['markdownSha256']);
    final indexedAtRaw = _asNonEmptyString(json['indexedAt']);
    final indexedAt = indexedAtRaw == null
        ? null
        : DateTime.tryParse(indexedAtRaw)?.toUtc();
    if (documentId == null ||
        title == null ||
        markdownPath == null ||
        markdownSha256 == null ||
        indexedAt == null) {
      return null;
    }
    final pdfPath = json['pdfPath'];
    final pdfSha256 = json['pdfSha256'];
    final contentListSha256 = json['contentListSha256'];
    final modelId = json['modelId'];
    final rawMaxChars = json['maxSectionChars'];
    if ((pdfPath != null && pdfPath is! String) ||
        (pdfSha256 != null && pdfSha256 is! String) ||
        (contentListSha256 != null && contentListSha256 is! String) ||
        (modelId != null && modelId is! String) ||
        (rawMaxChars != null && (rawMaxChars is! num || rawMaxChars < 200))) {
      return null;
    }
    final corpusResult = _parseOptionalRange(json['corpusPageRange']);
    if (!corpusResult.valid) return null;
    final rawMode = _asNonEmptyString(json['indexMode']);
    final indexMode = StudyIndexMode.values.firstWhere(
      (item) => item.name == rawMode,
      orElse: () => StudyIndexMode.deterministicFallback,
    );
    final rawSections = json['sections'];
    if (rawSections is! List) return null;
    final sections = <StudyIndexedSection>[];
    for (final item in rawSections) {
      if (item is! Map) return null;
      final parsed = StudyIndexedSection.tryFromJson(
        item.cast<String, dynamic>(),
      );
      if (parsed == null) return null;
      sections.add(parsed);
    }
    return StudyDocumentIndex(
      documentId: documentId,
      title: title,
      markdownPath: markdownPath,
      markdownSha256: markdownSha256,
      pdfPath: pdfPath as String?,
      pdfSha256: pdfSha256 as String?,
      contentListSha256: contentListSha256 as String?,
      corpusPageRange: corpusResult.range,
      maxSectionChars:
          (rawMaxChars as num?)?.toInt() ??
          StudyMineruIndexer.defaultMaxSectionChars,
      indexMode: indexMode,
      modelId: modelId as String?,
      indexedAt: indexedAt,
      sections: List<StudyIndexedSection>.unmodifiable(sections),
    );
  }

  /// Renders a compact Markdown map for agents in the Linux workspace.
  String toWorkspaceMarkdown() {
    final buf = StringBuffer()
      ..writeln('# Study Source Index: $title')
      ..writeln('- document_id: `$documentId`')
      ..writeln('- markdown_path: `$markdownPath`')
      ..writeln('- markdown_sha256: `$markdownSha256`');
    if (pdfPath != null) {
      buf.writeln('- pdf_path: `$pdfPath`');
    }
    if (corpusPageRange != null) {
      buf.writeln('- corpus_pages: `${corpusPageRange!.label}`');
    }
    buf
      ..writeln('- index_mode: `${indexMode.name}`')
      ..writeln();
    for (final section in sections) {
      buf.writeln('## [${section.sectionId}] ${section.title}');
      buf.writeln(
        '- lines: `${section.startLine}-${section.endLine}` '
        '(${section.charCount} chars)',
      );
      if (section.physicalPageRange != null) {
        buf.writeln('- physical_pages: `${section.physicalPageRange!.label}`');
      }
      if (section.corpusPageRange != null) {
        buf.writeln('- corpus_pages: `${section.corpusPageRange!.label}`');
      }
      if (section.concepts.isNotEmpty) {
        buf.writeln('- concepts: ${section.concepts.join(', ')}');
      }
      if (section.formulas.isNotEmpty) {
        buf.writeln('- formulas: ${section.formulas.join(' ; ')}');
      }
      if (section.questions.isNotEmpty) {
        buf.writeln('- questions: ${section.questions.join(' | ')}');
      }
      buf
        ..writeln('- summary: ${section.summary}')
        ..writeln();
    }
    return buf.toString();
  }
}

class StudyMineruIndexer {
  const StudyMineruIndexer._();

  static const int defaultMaxSectionChars = 3600;

  static const String fastModelSystemPrompt =
      '''You are an ahead-of-time academic corpus indexer for StudyPi.
Given sections from a MinerU Markdown parse, return ONLY a JSON object:
{"sections":[{"sectionId":"sec-1","summary":"1-2 sentence precise summary","concepts":["term1","term2"],"questions":["question this section answers"]}]}
Preserve exact sectionId values, do not invent facts outside the provided text, and keep summaries concise in the same language as the source.''';

  /// Builds a cheap-model completion callback using [ChatApiService.generateMessage].
  static StudyFastModelCompletion chatApiFastModel({
    required ProviderConfig config,
    required String modelId,
    String? requestId,
  }) {
    return (systemPrompt, userPrompt) async {
      final result = await ChatApiService.generateMessage(
        config: config,
        modelId: modelId,
        requestId: requestId,
        textOnly: true,
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      );
      return result.text;
    };
  }

  /// Upper bound of section text sent to the fast model in one request.
  /// Large books are enriched in batches so neither the request nor the JSON
  /// reply outgrows a cheap model's context and output limits.
  static const int fastModelBatchChars = 16000;
  static const int fastModelBatchMaxSections = 16;
  static const Duration defaultFastModelTimeout = Duration(seconds: 90);

  /// Indexes a MinerU Markdown parse (and optional sibling `*_content_list.json`)
  /// and writes `index.json` + `INDEX.md` into `<workspaceDir>/.studypi/index/<documentId>/`.
  ///
  /// File reading, hashing and slicing run on a background isolate. Each
  /// fast-model batch that fails, times out or returns unusable JSON keeps its
  /// deterministic fallback; the index reports [StudyIndexMode.fastModel] only
  /// when every batch was enriched, so a later call retries the rest.
  static Future<StudyDocumentIndex> indexToWorkspace({
    required String documentId,
    required String title,
    required String markdownPath,
    required String workspaceDir,
    String? pdfPath,
    String? contentListJsonPath,
    StudyPageRange? corpusPageRange,
    StudyFastModelCompletion? fastModel,
    String? fastModelId,
    int maxSectionChars = defaultMaxSectionChars,
    Duration fastModelTimeout = defaultFastModelTimeout,
  }) async {
    ToolCallCancellation.current?.throwIfCancelled();
    final safeDocId = _requireSafeDocumentId(documentId);
    final wantsFastModel = fastModel != null;
    final prepared = await Isolate.run(
      () => _prepareIndex(
        safeDocId: safeDocId,
        title: title,
        markdownPath: markdownPath,
        workspaceDir: workspaceDir,
        pdfPath: pdfPath,
        contentListJsonPath: contentListJsonPath,
        corpusPageRange: corpusPageRange,
        wantsFastModel: wantsFastModel,
        fastModelId: fastModelId,
        maxSectionChars: maxSectionChars,
      ),
    );
    final outDir = Directory(prepared.outDir);
    final indexJsonFile = File(p.join(outDir.path, 'index.json'));
    final indexMdFile = File(p.join(outDir.path, 'INDEX.md'));
    final cached = prepared.cached;
    if (cached != null) {
      if (!indexMdFile.existsSync()) {
        await _writeAtomically(indexMdFile, cached.toWorkspaceMarkdown());
      }
      return cached;
    }

    ToolCallCancellation.current?.throwIfCancelled();
    final rawSections = prepared.sections;
    var sections = [for (final item in rawSections) item.section];
    var indexMode = StudyIndexMode.deterministicFallback;

    if (fastModel != null && rawSections.isNotEmpty) {
      final enrichedById = <String, StudyIndexedSection>{};
      var allBatchesEnriched = true;
      for (final batch in _fastModelBatches(rawSections)) {
        ToolCallCancellation.current?.throwIfCancelled();
        List<StudyIndexedSection>? enriched;
        try {
          final response = await fastModel(
            fastModelSystemPrompt,
            _buildFastModelUserPrompt(title: prepared.title, sections: batch),
          ).timeout(fastModelTimeout);
          ToolCallCancellation.current?.throwIfCancelled();
          enriched = _applyFastModelResponse([
            for (final item in batch) item.section,
          ], response);
        } catch (e) {
          if (isUserCancelError(e)) rethrow;
          ToolCallCancellation.current?.throwIfCancelled();
        }
        if (enriched == null) {
          allBatchesEnriched = false;
          continue;
        }
        for (final section in enriched) {
          enrichedById[section.sectionId] = section;
        }
      }
      sections = [
        for (final section in sections)
          enrichedById[section.sectionId] ?? section,
      ];
      if (allBatchesEnriched) indexMode = StudyIndexMode.fastModel;
    }

    ToolCallCancellation.current?.throwIfCancelled();
    final index = StudyDocumentIndex(
      documentId: safeDocId,
      title: prepared.title,
      markdownPath: prepared.markdownPath,
      markdownSha256: prepared.markdownSha256,
      pdfPath: prepared.pdfPath,
      pdfSha256: prepared.pdfSha256,
      contentListSha256: prepared.contentListSha256,
      corpusPageRange: corpusPageRange,
      maxSectionChars: prepared.maxSectionChars,
      indexMode: indexMode,
      modelId: indexMode == StudyIndexMode.fastModel ? fastModelId : null,
      indexedAt: DateTime.now().toUtc(),
      sections: List<StudyIndexedSection>.unmodifiable(sections),
    );

    await outDir.create(recursive: true);
    // INDEX.md first: index.json is the commit point readers trust.
    await _writeAtomically(indexMdFile, index.toWorkspaceMarkdown());
    await _writeAtomically(
      indexJsonFile,
      const JsonEncoder.withIndent('  ').convert(index.toJson()),
    );
    return index;
  }

  /// Unique temp name per write so concurrent indexing of the same document
  /// cannot interleave partial files; rename replaces the target in one step.
  static Future<void> _writeAtomically(File target, String contents) async {
    final temp = File(
      '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(contents, flush: true);
      await temp.rename(target.path);
    } catch (_) {
      if (temp.existsSync()) await temp.delete();
      rethrow;
    }
  }

  static List<List<({StudyIndexedSection section, String body})>>
  _fastModelBatches(List<({StudyIndexedSection section, String body})> all) {
    final batches = <List<({StudyIndexedSection section, String body})>>[];
    var current = <({StudyIndexedSection section, String body})>[];
    var chars = 0;
    for (final item in all) {
      final size = _promptBodyFor(item.body).length;
      if (current.isNotEmpty &&
          (chars + size > fastModelBatchChars ||
              current.length >= fastModelBatchMaxSections)) {
        batches.add(current);
        current = [];
        chars = 0;
      }
      current.add(item);
      chars += size;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  static String _promptBodyFor(String body) =>
      body.length <= 1600 ? body : body.substring(0, 1600);

  static ({
    String outDir,
    String title,
    String markdownPath,
    String markdownSha256,
    String? pdfPath,
    String? pdfSha256,
    String? contentListSha256,
    int maxSectionChars,
    StudyDocumentIndex? cached,
    List<({StudyIndexedSection section, String body})> sections,
  })
  _prepareIndex({
    required String safeDocId,
    required String title,
    required String markdownPath,
    required String workspaceDir,
    required String? pdfPath,
    required String? contentListJsonPath,
    required StudyPageRange? corpusPageRange,
    required bool wantsFastModel,
    required String? fastModelId,
    required int maxSectionChars,
  }) {
    final normalizedMarkdown = p.normalize(p.absolute(markdownPath));
    final markdownFile = File(normalizedMarkdown);
    if (!markdownFile.existsSync()) {
      throw ArgumentError.value(
        markdownPath,
        'markdownPath',
        'MinerU Markdown file does not exist',
      );
    }
    final markdownBytes = markdownFile.readAsBytesSync();
    if (markdownBytes.contains(0)) {
      throw const FormatException('MinerU Markdown file contains binary NUL');
    }
    final markdownSha256 = sha256.convert(markdownBytes).toString();
    final normalizedPdf = pdfPath == null || pdfPath.trim().isEmpty
        ? null
        : p.normalize(p.absolute(pdfPath));
    final pdfFile = normalizedPdf == null ? null : File(normalizedPdf);
    final pdfSha256 = pdfFile != null && pdfFile.existsSync()
        ? sha256OfFileSync(pdfFile)
        : null;
    final contentListFile = _resolveContentListFile(
      markdownFile: markdownFile,
      explicitPath: contentListJsonPath,
    );
    final contentListSha256 =
        contentListFile != null && contentListFile.existsSync()
        ? sha256OfFileSync(contentListFile)
        : null;
    final effectiveTitle = title.trim().isEmpty
        ? p.basenameWithoutExtension(normalizedMarkdown)
        : title.trim();
    final effectiveMaxChars = maxSectionChars < 200 ? 200 : maxSectionChars;
    final outDir = p.join(
      p.normalize(p.absolute(workspaceDir)),
      '.studypi',
      'index',
      safeDocId,
    );

    StudyDocumentIndex? cached;
    final indexJsonFile = File(p.join(outDir, 'index.json'));
    if (indexJsonFile.existsSync()) {
      try {
        final decoded = jsonDecode(indexJsonFile.readAsStringSync());
        if (decoded is Map) {
          final candidate = StudyDocumentIndex.tryFromJson(
            decoded.cast<String, dynamic>(),
          );
          if (candidate != null &&
              candidate.title == effectiveTitle &&
              candidate.markdownPath == normalizedMarkdown &&
              candidate.markdownSha256 == markdownSha256 &&
              candidate.pdfPath == normalizedPdf &&
              candidate.pdfSha256 == pdfSha256 &&
              candidate.contentListSha256 == contentListSha256 &&
              candidate.corpusPageRange == corpusPageRange &&
              candidate.maxSectionChars == effectiveMaxChars &&
              (!wantsFastModel ||
                  (candidate.indexMode == StudyIndexMode.fastModel &&
                      (fastModelId == null ||
                          candidate.modelId == fastModelId)))) {
            cached = candidate;
          }
        }
      } catch (_) {}
    }

    return (
      outDir: outDir,
      title: effectiveTitle,
      markdownPath: normalizedMarkdown,
      markdownSha256: markdownSha256,
      pdfPath: normalizedPdf,
      pdfSha256: pdfSha256,
      contentListSha256: contentListSha256,
      maxSectionChars: effectiveMaxChars,
      cached: cached,
      sections: cached != null
          ? const <({StudyIndexedSection section, String body})>[]
          : _sliceMarkdownSections(
              _splitNormalizedLines(markdownBytes).join('\n'),
              maxSectionChars: effectiveMaxChars,
              corpusPageRange: corpusPageRange,
              pageBlocks: _readContentListBlocks(contentListFile),
            ),
    );
  }

  /// SHA-256 without holding a large file in memory at once.
  static String sha256OfFileSync(File file) {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);
    final handle = file.openSync();
    try {
      final buffer = Uint8List(1 << 20);
      while (true) {
        final read = handle.readIntoSync(buffer);
        if (read <= 0) break;
        input.add(Uint8List.sublistView(buffer, 0, read));
      }
    } finally {
      handle.closeSync();
    }
    input.close();
    return output.value!.toString();
  }

  static List<String> _splitNormalizedLines(List<int> bytes) =>
      UnicodeSanitizer.sanitize(
        utf8.decode(bytes),
      ).replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

  /// Current lines of the indexed Markdown, or null when the file is missing,
  /// unreadable, or no longer matches [StudyDocumentIndex.markdownSha256].
  static List<String>? tryReadIndexedLines(StudyDocumentIndex index) {
    try {
      final bytes = File(index.markdownPath).readAsBytesSync();
      if (sha256.convert(bytes).toString() != index.markdownSha256) {
        return null;
      }
      return _splitNormalizedLines(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Reads the exact Markdown slice for [sectionId], verifying [StudyDocumentIndex.markdownSha256].
  static String readSectionText(StudyDocumentIndex index, String sectionId) {
    final section = index.sections
        .where((item) => item.sectionId == sectionId)
        .firstOrNull;
    if (section == null) {
      throw ArgumentError.value(
        sectionId,
        'sectionId',
        'Section not found in StudyDocumentIndex',
      );
    }
    final file = File(index.markdownPath);
    if (!file.existsSync()) {
      throw StateError(
        'Indexed Markdown file is missing: ${index.markdownPath}',
      );
    }
    final bytes = file.readAsBytesSync();
    final currentSha = sha256.convert(bytes).toString();
    if (currentSha != index.markdownSha256) {
      throw StateError(
        'Indexed Markdown file changed since indexing: ${index.markdownPath}',
      );
    }
    final lines = _splitNormalizedLines(bytes);
    if (section.startLine < 1 || section.endLine > lines.length) {
      throw RangeError(
        'Section lines ${section.startLine}-${section.endLine} out of bounds (1..${lines.length})',
      );
    }
    return lines.sublist(section.startLine - 1, section.endLine).join('\n');
  }

  static final RegExp _safeDocumentIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );
  static final RegExp _windowsReservedDevicePattern = RegExp(
    r'^(CON|PRN|AUX|NUL|CONIN|CONOUT|COM[1-9]|LPT[1-9])(\..*)?$',
    caseSensitive: false,
  );

  static String _requireSafeDocumentId(String documentId) {
    final trimmed = documentId.trim();
    if (!_safeDocumentIdPattern.hasMatch(trimmed) ||
        trimmed.contains('..') ||
        trimmed.endsWith('.') ||
        _windowsReservedDevicePattern.hasMatch(trimmed)) {
      throw ArgumentError.value(
        documentId,
        'documentId',
        'Invalid documentId for workspace path',
      );
    }
    return trimmed;
  }

  static File? _resolveContentListFile({
    required File markdownFile,
    String? explicitPath,
  }) {
    if (explicitPath != null && explicitPath.trim().isNotEmpty) {
      final file = File(p.normalize(p.absolute(explicitPath)));
      return file.existsSync() ? file : null;
    }
    final dir = markdownFile.parent;
    if (!dir.existsSync()) return null;
    final candidates =
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (file) => file.path.toLowerCase().endsWith('content_list.json'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return candidates.firstOrNull;
  }

  static List<_ContentListBlock> _readContentListBlocks(File? file) {
    if (file == null || !file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final blocks = <_ContentListBlock>[];
      void add(int? pageIdx, String rawText) {
        if (pageIdx == null || pageIdx < 0) return;
        final probe = _normalizeProbe(rawText);
        // Page numbers, figure labels and other tiny blocks match anywhere.
        if (probe.length < _minProbeChars) return;
        blocks.add(_ContentListBlock(page: pageIdx + 1, probe: probe));
      }

      if (decoded is List) {
        // `*_content_list.json`: one flat entry per block.
        for (final item in decoded) {
          if (item is! Map) continue;
          add(
            _asInt(item['page_idx']),
            (item['text'] ?? item['latex'] ?? item['table_body'] ?? '')
                .toString(),
          );
        }
      } else if (decoded is Map && decoded['pdf_info'] is List) {
        // MinerU middle JSON: pages with nested para_blocks → lines → spans.
        for (final page in decoded['pdf_info'] as List) {
          if (page is! Map) continue;
          final pageIdx = _asInt(page['page_idx']);
          final paraBlocks = page['para_blocks'];
          if (paraBlocks is! List) continue;
          for (final block in paraBlocks) {
            add(pageIdx, _middleBlockText(block));
          }
        }
      }
      return blocks;
    } catch (_) {
      return const [];
    }
  }

  /// Text of a middle-JSON block, including nested blocks (tables, figures
  /// with captions).
  static String _middleBlockText(Object? block) {
    if (block is! Map) return '';
    final buf = StringBuffer();
    final lines = block['lines'];
    if (lines is List) {
      for (final line in lines) {
        final spans = line is Map ? line['spans'] : null;
        if (spans is! List) continue;
        for (final span in spans) {
          if (span is Map && span['content'] is String) {
            buf.write(span['content']);
          }
        }
      }
    }
    final nested = block['blocks'];
    if (nested is List) {
      for (final child in nested) {
        buf.write(_middleBlockText(child));
      }
    }
    return buf.toString();
  }

  static List<({StudyIndexedSection section, String body})>
  _sliceMarkdownSections(
    String normalizedText, {
    required int maxSectionChars,
    required StudyPageRange? corpusPageRange,
    required List<_ContentListBlock> pageBlocks,
  }) {
    final effectiveMaxChars = maxSectionChars < 200 ? 200 : maxSectionChars;
    final lines = normalizedText.split('\n');
    final rawBlocks =
        <({List<String> headingPath, int startLine, int endLine})>[];
    final headingStack = <({int level, String title})>[];

    var fenceChar = '';
    var fenceLen = 0;
    var blockStart = 1;
    var currentPath = <String>[];
    var inDisplayMath = false;

    final headingPattern = RegExp(r'^(#{1,6})\s+(.+?)\s*$');

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lineNo = i + 1;
      final fenceUpdate = _updateFenceState(
        line: line,
        fenceChar: fenceChar,
        fenceLen: fenceLen,
      );
      if (fenceUpdate.isFenceLine) {
        fenceChar = fenceUpdate.fenceChar;
        fenceLen = fenceUpdate.fenceLen;
        continue;
      }
      if (fenceLen > 0) continue;
      final wasInDisplayMath = inDisplayMath;
      inDisplayMath = _nextDisplayMathState(line, inDisplayMath);
      if (wasInDisplayMath || inDisplayMath) continue;

      final headingMatch = headingPattern.firstMatch(line);
      if (headingMatch == null) continue;

      if (lineNo > blockStart) {
        final sliceText = lines.sublist(blockStart - 1, lineNo - 1).join('\n');
        if (sliceText.trim().isNotEmpty) {
          rawBlocks.add((
            headingPath: List<String>.unmodifiable(currentPath),
            startLine: blockStart,
            endLine: lineNo - 1,
          ));
        }
      }

      final level = headingMatch.group(1)!.length;
      final headingTitle = headingMatch.group(2)!.trim();
      while (headingStack.isNotEmpty && headingStack.last.level >= level) {
        headingStack.removeLast();
      }
      headingStack.add((level: level, title: headingTitle));
      currentPath = [for (final h in headingStack) h.title];
      blockStart = lineNo;
    }

    if (blockStart <= lines.length) {
      final tailText = lines.sublist(blockStart - 1).join('\n');
      if (tailText.trim().isNotEmpty) {
        rawBlocks.add((
          headingPath: List<String>.unmodifiable(currentPath),
          startLine: blockStart,
          endLine: lines.length,
        ));
      }
    }

    final splitBlocks =
        <({List<String> headingPath, int startLine, int endLine})>[];
    for (final block in rawBlocks) {
      splitBlocks.addAll(
        _splitOversizedBlock(
          lines: lines,
          headingPath: block.headingPath,
          startLine: block.startLine,
          endLine: block.endLine,
          maxChars: effectiveMaxChars,
        ),
      );
    }

    var blockCursor = 0;
    final results = <({StudyIndexedSection section, String body})>[];
    for (var i = 0; i < splitBlocks.length; i++) {
      final item = splitBlocks[i];
      final sectionId = 'sec-${i + 1}';
      final body = lines.sublist(item.startLine - 1, item.endLine).join('\n');
      final formulas = _extractFormulas(body);
      final nextBody = i + 1 < splitBlocks.length
          ? lines
                .sublist(
                  splitBlocks[i + 1].startLine - 1,
                  splitBlocks[i + 1].endLine,
                )
                .join('\n')
          : null;
      final pageMatch = _matchPhysicalPages(
        body: body,
        nextSectionBody: nextBody,
        pageBlocks: pageBlocks,
        startCursor: blockCursor,
      );
      blockCursor = pageMatch.nextCursor;
      final concepts = _extractDeterministicConcepts(item.headingPath, body);
      final summary = _extractDeterministicSummary(item.headingPath, body);

      results.add((
        section: StudyIndexedSection(
          sectionId: sectionId,
          headingPath: item.headingPath,
          startLine: item.startLine,
          endLine: item.endLine,
          charCount: body.length,
          physicalPageRange: pageMatch.range,
          corpusPageRange: corpusPageRange,
          formulas: formulas,
          concepts: concepts,
          questions: const [],
          summary: summary,
        ),
        body: body,
      ));
    }
    return results;
  }

  static ({bool isFenceLine, String fenceChar, int fenceLen})
  _updateFenceState({
    required String line,
    required String fenceChar,
    required int fenceLen,
  }) {
    if (fenceLen == 0) {
      final openMatch = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line);
      if (openMatch == null) {
        return (isFenceLine: false, fenceChar: '', fenceLen: 0);
      }
      final token = openMatch.group(1)!;
      return (isFenceLine: true, fenceChar: token[0], fenceLen: token.length);
    }
    final closeMatch = RegExp(r'^\s*(`{3,}|~{3,})\s*$').firstMatch(line);
    if (closeMatch != null) {
      final token = closeMatch.group(1)!;
      if (token[0] == fenceChar && token.length >= fenceLen) {
        return (isFenceLine: true, fenceChar: '', fenceLen: 0);
      }
    }
    return (isFenceLine: false, fenceChar: fenceChar, fenceLen: fenceLen);
  }

  /// Tracks `\$\$` display math across lines. A blank line also ends it:
  /// MinerU never emits blank lines inside a formula, and one stray `\$\$`
  /// must not hide every later heading in the book.
  static bool _nextDisplayMathState(String line, bool inDisplayMath) {
    if (line.trim().isEmpty) return false;
    final delimiters = RegExp(r'\$\$').allMatches(line).length;
    return delimiters.isOdd ? !inDisplayMath : inDisplayMath;
  }

  static List<({List<String> headingPath, int startLine, int endLine})>
  _splitOversizedBlock({
    required List<String> lines,
    required List<String> headingPath,
    required int startLine,
    required int endLine,
    required int maxChars,
  }) {
    final full = lines.sublist(startLine - 1, endLine).join('\n');
    if (full.length <= maxChars || startLine == endLine) {
      return [
        (headingPath: headingPath, startLine: startLine, endLine: endLine),
      ];
    }
    final chunks = <({List<String> headingPath, int startLine, int endLine})>[];
    var chunkStart = startLine;
    var accChars = 0;
    var fenceChar = '';
    var fenceLen = 0;
    var inDisplayFormula = false;
    int? lastSafeEndLine;

    for (var lineNo = startLine; lineNo <= endLine; lineNo++) {
      final line = lines[lineNo - 1];
      final lineLen = line.length + 1;
      if (lineNo > chunkStart &&
          accChars + lineLen > maxChars &&
          lastSafeEndLine != null &&
          lastSafeEndLine >= chunkStart) {
        chunks.add((
          headingPath: headingPath,
          startLine: chunkStart,
          endLine: lastSafeEndLine,
        ));
        chunkStart = lastSafeEndLine + 1;
        lastSafeEndLine = null;
        accChars = 0;
        for (var j = chunkStart; j < lineNo; j++) {
          accChars += lines[j - 1].length + 1;
        }
      }
      final fenceUpdate = _updateFenceState(
        line: line,
        fenceChar: fenceChar,
        fenceLen: fenceLen,
      );
      fenceChar = fenceUpdate.fenceChar;
      fenceLen = fenceUpdate.fenceLen;
      if (!fenceUpdate.isFenceLine && fenceLen == 0) {
        inDisplayFormula = _nextDisplayMathState(line, inDisplayFormula);
      }
      accChars += lineLen;
      if (fenceLen == 0 && !inDisplayFormula) {
        lastSafeEndLine = lineNo;
      }
    }
    if (chunkStart <= endLine) {
      chunks.add((
        headingPath: headingPath,
        startLine: chunkStart,
        endLine: endLine,
      ));
    }
    return chunks;
  }

  static String _stripFencedCodeBlocks(String markdown) {
    final lines = markdown.split('\n');
    final kept = <String>[];
    var fenceChar = '';
    var fenceLen = 0;
    for (final line in lines) {
      final fenceUpdate = _updateFenceState(
        line: line,
        fenceChar: fenceChar,
        fenceLen: fenceLen,
      );
      fenceChar = fenceUpdate.fenceChar;
      fenceLen = fenceUpdate.fenceLen;
      if (!fenceUpdate.isFenceLine && fenceLen == 0) {
        kept.add(line);
      }
    }
    return kept.join('\n');
  }

  static List<String> _extractFormulas(String markdown) {
    final unfenced = _stripFencedCodeBlocks(markdown);
    final formulas = <String>[];
    final pattern = RegExp(r'\$\$([\s\S]+?)\$\$');
    for (final match in pattern.allMatches(unfenced)) {
      final formula = match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (formula.isNotEmpty && !formulas.contains(formula)) {
        formulas.add(formula);
      }
    }
    return List<String>.unmodifiable(formulas);
  }

  static ({StudyPageRange? range, int nextCursor}) _matchPhysicalPages({
    required String body,
    required String? nextSectionBody,
    required List<_ContentListBlock> pageBlocks,
    required int startCursor,
  }) {
    if (pageBlocks.isEmpty) return (range: null, nextCursor: startCursor);
    final sectionText = _normalizeMatchText(body);
    if (sectionText.isEmpty) return (range: null, nextCursor: startCursor);
    final nextSectionText = nextSectionBody == null
        ? ''
        : _normalizeMatchText(nextSectionBody);

    int? minPage;
    int? maxPage;
    var nextCursor = startCursor;
    var textCursor = 0;
    var unmatchedGap = 0;

    for (var i = startCursor; i < pageBlocks.length; i++) {
      final block = pageBlocks[i];
      final hitIndex = sectionText.indexOf(block.probe, textCursor);
      final matchesCurrent =
          hitIndex >= 0 ||
          (textCursor == 0 &&
              sectionText.length >= _minProbeChars &&
              block.probe.contains(sectionText));
      if (matchesCurrent) {
        minPage = minPage == null || block.page < minPage
            ? block.page
            : minPage;
        maxPage = maxPage == null || block.page > maxPage
            ? block.page
            : maxPage;
        nextCursor = i + 1;
        textCursor = hitIndex >= 0
            ? hitIndex + block.probe.length
            : sectionText.length;
        unmatchedGap = 0;
        continue;
      }
      if (nextSectionText.isNotEmpty &&
          (nextSectionText.contains(block.probe) ||
              (nextSectionText.length >= _minProbeChars &&
                  block.probe.contains(nextSectionText)))) {
        break;
      }
      if (minPage != null) {
        unmatchedGap++;
        if (unmatchedGap > 4) break;
      }
    }
    if (minPage == null || maxPage == null) {
      return (range: null, nextCursor: startCursor);
    }
    return (range: StudyPageRange(minPage, maxPage), nextCursor: nextCursor);
  }

  static List<String> _extractDeterministicConcepts(
    List<String> headingPath,
    String body,
  ) {
    final concepts = <String>[];
    for (final heading in headingPath) {
      final cleaned = heading
          .replaceFirst(RegExp(r'^[\d.\s第章节讲、-]+'), '')
          .trim();
      if (cleaned.isNotEmpty && !concepts.contains(cleaned)) {
        concepts.add(cleaned);
      }
    }
    for (final match in RegExp(r'\*\*([^*]{2,40})\*\*').allMatches(body)) {
      final term = match.group(1)!.trim();
      if (term.isNotEmpty && !concepts.contains(term)) {
        concepts.add(term);
        if (concepts.length >= 6) break;
      }
    }
    return List<String>.unmodifiable(concepts);
  }

  static String _extractDeterministicSummary(
    List<String> headingPath,
    String body,
  ) {
    final contentLines = <String>[];
    for (final rawLine in body.split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('```') ||
          trimmed.startsWith('~~~')) {
        continue;
      }
      contentLines.add(trimmed);
      if (contentLines.join(' ').length >= 160) break;
    }
    final summary = contentLines
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (summary.isEmpty) {
      return headingPath.isEmpty ? '' : headingPath.join(' > ');
    }
    return summary.length <= 180 ? summary : '${summary.substring(0, 180)}...';
  }

  static String _buildFastModelUserPrompt({
    required String title,
    required List<({StudyIndexedSection section, String body})> sections,
  }) {
    final payload = {
      'title': title,
      'sections': [
        for (final item in sections)
          {
            'sectionId': item.section.sectionId,
            'headingPath': item.section.headingPath,
            'formulas': item.section.formulas,
            'text': _promptBodyFor(item.body),
          },
      ],
    };
    return jsonEncode(payload);
  }

  static List<StudyIndexedSection>? _applyFastModelResponse(
    List<StudyIndexedSection> baseSections,
    String rawResponse,
  ) {
    final jsonText = _stripJsonCodeFence(rawResponse);
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    final List? items = switch (decoded) {
      {'sections': final List list} => list,
      final List list => list,
      _ => null,
    };
    if (items == null || items.isEmpty) return null;

    final byId = <String, Map<String, dynamic>>{};
    for (final item in items) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final id = _asNonEmptyString(map['sectionId']);
      if (id != null) byId[id] = map;
    }
    if (byId.isEmpty) return null;

    var matchedAny = false;
    final updated = <StudyIndexedSection>[];
    for (final section in baseSections) {
      final item = byId[section.sectionId];
      if (item == null) {
        updated.add(section);
        continue;
      }
      final summary = _asNonEmptyString(item['summary']);
      final concepts = _asStringList(item['concepts']);
      final questions = _asStringList(item['questions']);
      if (summary == null && concepts == null && questions == null) {
        updated.add(section);
        continue;
      }
      matchedAny = true;
      updated.add(
        section.copyWith(
          summary: summary ?? section.summary,
          concepts: concepts != null && concepts.isNotEmpty
              ? concepts
              : section.concepts,
          questions: questions ?? section.questions,
        ),
      );
    }
    return matchedAny ? updated : null;
  }

  static String _stripJsonCodeFence(String raw) {
    final trimmed = raw.trim();
    final match = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    return match == null ? trimmed : match.group(1)!.trim();
  }

  static String _normalizeMatchText(String text) {
    return text
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
        .replaceAll(RegExp(r'[*_`$]+'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
  }

  static const int _minProbeChars = 6;

  static String _normalizeProbe(String text) {
    final collapsed = _normalizeMatchText(text);
    if (collapsed.isEmpty) return '';
    return collapsed.length <= 48 ? collapsed : collapsed.substring(0, 48);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _ContentListBlock {
  const _ContentListBlock({required this.page, required this.probe});

  final int page;
  final String probe;
}

String? _asNonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _asInt(Object? value) => value is num ? value.toInt() : null;

List<String>? _asStringList(Object? value) {
  if (value == null) return const [];
  if (value is! List) return null;
  final result = <String>[];
  for (final item in value) {
    if (item is! String) return null;
    final trimmed = item.trim();
    if (trimmed.isNotEmpty) result.add(trimmed);
  }
  return List<String>.unmodifiable(result);
}

({bool valid, StudyPageRange? range}) _parseOptionalRange(Object? value) {
  if (value == null) return (valid: true, range: null);
  if (value is! Map) return (valid: false, range: null);
  final start = _asInt(value['start']);
  final end = _asInt(value['end']);
  if (start == null || end == null || start <= 0 || start > end) {
    return (valid: false, range: null);
  }
  return (valid: true, range: StudyPageRange(start, end));
}
