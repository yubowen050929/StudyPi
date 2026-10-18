import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:uuid/uuid.dart';

import '../../../utils/unicode_sanitizer.dart';
import '../../database/extension_entity_store.dart';
import 'study_citation_resolver.dart';
import 'study_corpus.dart';
import 'study_mineru_indexer.dart';
import 'study_prompts.dart';

enum StudySourceFormat { text, markdown, pdf }

enum StudySourceStatus { ready, scannedNeedsOcr, unreadable, pendingSourceLink }

enum StudyEvidenceStatus { grounded, insufficientEvidence }

class StudyProject {
  const StudyProject({
    required this.id,
    required this.title,
    required this.goal,
    required this.mode,
    required this.conversationIds,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String goal;
  final StudyInteractionMode mode;
  final List<String> conversationIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  StudyProject copyWith({
    String? title,
    String? goal,
    StudyInteractionMode? mode,
    List<String>? conversationIds,
    DateTime? updatedAt,
  }) {
    return StudyProject(
      id: id,
      title: title ?? this.title,
      goal: goal ?? this.goal,
      mode: mode ?? this.mode,
      conversationIds: List<String>.unmodifiable(
        conversationIds ?? this.conversationIds,
      ),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'goal': goal,
    'mode': mode.name,
    'conversationIds': conversationIds,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static StudyProject? tryFromJson(Map<String, dynamic> json) {
    final id = _optionalString(json['id'])?.trim() ?? '';
    final title = _optionalString(json['title'])?.trim() ?? '';
    final createdAt = _tryParseUtc(json['createdAt']);
    final updatedAt = _tryParseUtc(json['updatedAt']);
    if (id.isEmpty || title.isEmpty || createdAt == null || updatedAt == null) {
      return null;
    }
    final rawConversations = json['conversationIds'];
    if (rawConversations != null && rawConversations is! List) {
      return null;
    }
    final rawMode = _optionalString(json['mode']) ?? '';
    final mode = StudyInteractionMode.values.firstWhere(
      (item) => item.name == rawMode,
      orElse: () => StudyInteractionMode.explain,
    );
    return StudyProject(
      id: id,
      title: title,
      goal: _optionalString(json['goal']) ?? '',
      mode: mode,
      conversationIds: List<String>.unmodifiable([
        if (rawConversations is List)
          for (final item in rawConversations)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ]),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  factory StudyProject.fromJson(Map<String, dynamic> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw const FormatException('Invalid StudyProject JSON');
    }
    return parsed;
  }
}

class StudySourceDocument {
  const StudySourceDocument({
    required this.id,
    required this.projectId,
    required this.title,
    required this.fileName,
    required this.format,
    required this.status,
    required this.contentSha256,
    required this.byteLength,
    required this.originalPath,
    required this.parsedMarkdownPath,
    required this.candidatePdfPaths,
    required this.physicalPageCount,
    required this.corpusPageRange,
    required this.extractedText,
    required this.importedAt,
  });

  final String id;
  final String projectId;
  final String title;
  final String fileName;
  final StudySourceFormat format;
  final StudySourceStatus status;
  final String? contentSha256;
  final int? byteLength;
  final String? originalPath;
  final String? parsedMarkdownPath;
  final List<String> candidatePdfPaths;

  /// Actual 1-based page count inside the PDF file (`1..physicalPageCount`).
  /// Never conflated with [corpusPageRange], which is textbook pagination.
  final int? physicalPageCount;
  final StudyPageRange? corpusPageRange;
  final String? extractedText;
  final DateTime importedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'title': title,
    'fileName': fileName,
    'format': format.name,
    'status': status.name,
    'contentSha256': contentSha256,
    'byteLength': byteLength,
    'originalPath': originalPath,
    'parsedMarkdownPath': parsedMarkdownPath,
    'candidatePdfPaths': candidatePdfPaths,
    'physicalPageCount': physicalPageCount,
    if (corpusPageRange != null)
      'corpusPageRange': {
        'start': corpusPageRange!.start,
        'end': corpusPageRange!.end,
      },
    'extractedText': extractedText,
    'importedAt': importedAt.toUtc().toIso8601String(),
  };

  static StudySourceDocument? tryFromJson(Map<String, dynamic> json) {
    final id = _optionalString(json['id'])?.trim() ?? '';
    final projectId = _optionalString(json['projectId'])?.trim() ?? '';
    final fileName = _optionalString(json['fileName'])?.trim() ?? '';
    final importedAt = _tryParseUtc(json['importedAt']);
    if (id.isEmpty ||
        projectId.isEmpty ||
        fileName.isEmpty ||
        importedAt == null) {
      return null;
    }
    final rawCandidates = json['candidatePdfPaths'];
    if (rawCandidates != null && rawCandidates is! List) {
      return null;
    }
    StudyPageRange? corpusPageRange;
    final rangeMap = json['corpusPageRange'];
    if (rangeMap != null) {
      if (rangeMap is! Map) return null;
      final start = _optionalInt(rangeMap['start']);
      final end = _optionalInt(rangeMap['end']);
      if (start == null || end == null || start <= 0 || start > end) {
        return null;
      }
      corpusPageRange = StudyPageRange(start, end);
    }
    return StudySourceDocument(
      id: id,
      projectId: projectId,
      title: _optionalString(json['title']) ?? fileName,
      fileName: fileName,
      format: StudySourceFormat.values.firstWhere(
        (item) => item.name == json['format'],
        orElse: () => StudySourceFormat.text,
      ),
      status: StudySourceStatus.values.firstWhere(
        (item) => item.name == json['status'],
        orElse: () => StudySourceStatus.unreadable,
      ),
      contentSha256: _optionalString(json['contentSha256']),
      byteLength: _optionalInt(json['byteLength']),
      originalPath: _optionalString(json['originalPath']),
      parsedMarkdownPath: _optionalString(json['parsedMarkdownPath']),
      candidatePdfPaths: List<String>.unmodifiable([
        if (rawCandidates is List)
          for (final item in rawCandidates)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ]),
      physicalPageCount: _optionalInt(json['physicalPageCount']),
      corpusPageRange: corpusPageRange,
      extractedText: _optionalString(json['extractedText']),
      importedAt: importedAt,
    );
  }

  factory StudySourceDocument.fromJson(Map<String, dynamic> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw const FormatException('Invalid StudySourceDocument JSON');
    }
    return parsed;
  }
}

class StudySourceAnchor {
  const StudySourceAnchor({
    required this.documentId,
    this.contentSha256,
    this.sectionId,
    this.physicalPage,
    this.corpusPage,
    this.quote,
  });

  final String documentId;
  final String? contentSha256;

  /// Section of the document's workspace index, e.g. `sec-3`.
  final String? sectionId;
  final int? physicalPage;
  final int? corpusPage;
  final String? quote;

  StudySourceAnchor copyWith({String? contentSha256}) {
    return StudySourceAnchor(
      documentId: documentId,
      contentSha256: contentSha256 ?? this.contentSha256,
      sectionId: sectionId,
      physicalPage: physicalPage,
      corpusPage: corpusPage,
      quote: quote,
    );
  }

  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'contentSha256': contentSha256,
    'sectionId': sectionId,
    'physicalPage': physicalPage,
    'corpusPage': corpusPage,
    'quote': quote,
  };

  static StudySourceAnchor? tryFromJson(Map<String, dynamic> json) {
    final documentId = _optionalString(json['documentId'])?.trim() ?? '';
    if (documentId.isEmpty) return null;
    return StudySourceAnchor(
      documentId: documentId,
      contentSha256: _optionalString(json['contentSha256']),
      sectionId: _optionalString(json['sectionId']),
      physicalPage: _optionalInt(json['physicalPage']),
      corpusPage: _optionalInt(json['corpusPage']),
      quote: _optionalString(json['quote']),
    );
  }

  factory StudySourceAnchor.fromJson(Map<String, dynamic> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw const FormatException('Invalid StudySourceAnchor JSON');
    }
    return parsed;
  }
}

class StudyNote {
  const StudyNote({
    required this.id,
    required this.projectId,
    required this.title,
    required this.body,
    required this.anchors,
    required this.evidenceStatus,
    required this.conversationId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String title;
  final String body;
  final List<StudySourceAnchor> anchors;
  final StudyEvidenceStatus evidenceStatus;
  final String? conversationId;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'title': title,
    'body': body,
    'anchors': [for (final anchor in anchors) anchor.toJson()],
    'evidenceStatus': evidenceStatus.name,
    'conversationId': conversationId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static StudyNote? tryFromJson(Map<String, dynamic> json) {
    final id = _optionalString(json['id'])?.trim() ?? '';
    final projectId = _optionalString(json['projectId'])?.trim() ?? '';
    final createdAt = _tryParseUtc(json['createdAt']);
    final updatedAt = _tryParseUtc(json['updatedAt']);
    if (id.isEmpty ||
        projectId.isEmpty ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    final rawAnchors = json['anchors'];
    if (rawAnchors != null && rawAnchors is! List) {
      return null;
    }
    final anchors = <StudySourceAnchor>[];
    if (rawAnchors is List) {
      for (final item in rawAnchors) {
        if (item is! Map) return null;
        final anchor = StudySourceAnchor.tryFromJson(
          item.cast<String, dynamic>(),
        );
        if (anchor == null) return null;
        anchors.add(anchor);
      }
    }
    return StudyNote(
      id: id,
      projectId: projectId,
      title: _optionalString(json['title']) ?? '',
      body: _optionalString(json['body']) ?? '',
      anchors: List<StudySourceAnchor>.unmodifiable(anchors),
      evidenceStatus: StudyEvidenceStatus.values.firstWhere(
        (item) => item.name == json['evidenceStatus'],
        orElse: () => StudyEvidenceStatus.insufficientEvidence,
      ),
      conversationId: _optionalString(json['conversationId']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  factory StudyNote.fromJson(Map<String, dynamic> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw const FormatException('Invalid StudyNote JSON');
    }
    return parsed;
  }
}

class StudyProjectStore {
  StudyProjectStore(this._entities, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  static const String kindStudyProject = 'studyProject';
  static const String kindStudyDocument = 'studyDocument';
  static const String kindStudyNote = 'studyNote';

  final ExtensionEntityStore _entities;
  final Uuid _uuid;

  Future<StudyProject> createProject({
    required String title,
    String goal = '',
    StudyInteractionMode mode = StudyInteractionMode.explain,
    List<String> conversationIds = const [],
  }) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError.value(
        title,
        'title',
        'Project title cannot be empty',
      );
    }
    final now = DateTime.now().toUtc();
    final project = StudyProject(
      id: _uuid.v4(),
      title: normalizedTitle,
      goal: goal.trim(),
      mode: mode,
      conversationIds: List<String>.unmodifiable(
        conversationIds
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet(),
      ),
      createdAt: now,
      updatedAt: now,
    );
    await _entities.upsert(kindStudyProject, project.id, project.toJson());
    return project;
  }

  Future<StudyProject?> getProject(String projectId) async {
    final row = await _entities.get(kindStudyProject, projectId);
    if (row == null) return null;
    final project = StudyProject.tryFromJson(row.payload);
    return project != null && project.id == projectId ? project : null;
  }

  Future<List<StudyProject>> listProjects() async {
    final rows = await _entities.listByKind(kindStudyProject);
    final projects = <StudyProject>[];
    for (final row in rows) {
      final project = StudyProject.tryFromJson(row.payload);
      if (project != null) projects.add(project);
    }
    return projects;
  }

  Future<StudyProject> updateProjectMode(
    String projectId,
    StudyInteractionMode mode,
  ) async {
    final project = await _requireProject(projectId);
    final updated = project.copyWith(
      mode: mode,
      updatedAt: DateTime.now().toUtc(),
    );
    await _entities.upsert(kindStudyProject, updated.id, updated.toJson());
    return updated;
  }

  Future<StudyProject> bindConversation(
    String projectId,
    String conversationId,
  ) async {
    final trimmed = conversationId.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(conversationId, 'conversationId');
    }
    final project = await _requireProject(projectId);
    final nextIds = <String>{...project.conversationIds, trimmed}.toList();
    final updated = project.copyWith(
      conversationIds: nextIds,
      updatedAt: DateTime.now().toUtc(),
    );
    await _entities.upsert(kindStudyProject, updated.id, updated.toJson());
    return updated;
  }

  Future<StudyProject> unbindConversation(
    String projectId,
    String conversationId,
  ) async {
    final project = await _requireProject(projectId);
    final updated = project.copyWith(
      conversationIds: [
        for (final id in project.conversationIds)
          if (id != conversationId) id,
      ],
      updatedAt: DateTime.now().toUtc(),
    );
    await _entities.upsert(kindStudyProject, updated.id, updated.toJson());
    return updated;
  }

  Future<StudyProject> updateProject(
    String projectId, {
    String? title,
    String? goal,
  }) async {
    final project = await _requireProject(projectId);
    final nextTitle = title?.trim();
    if (nextTitle != null && nextTitle.isEmpty) {
      throw ArgumentError.value(
        title,
        'title',
        'Project title cannot be empty',
      );
    }
    final updated = project.copyWith(
      title: nextTitle,
      goal: goal?.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    await _entities.upsert(kindStudyProject, updated.id, updated.toJson());
    return updated;
  }

  /// Removes the project with its documents and notes. Files on disk belong to
  /// the caller (see `StudyProjectProvider`).
  Future<void> deleteProject(String projectId) async {
    for (final row in await _entities.listByOwner(
      kindStudyDocument,
      projectId,
    )) {
      await _entities.delete(kindStudyDocument, row.id);
    }
    for (final row in await _entities.listByOwner(kindStudyNote, projectId)) {
      await _entities.delete(kindStudyNote, row.id);
    }
    await _entities.delete(kindStudyProject, projectId);
  }

  Future<void> deleteDocument(String projectId, String documentId) async {
    if (await getDocument(projectId, documentId) == null) return;
    await _entities.delete(kindStudyDocument, documentId);
  }

  Future<void> deleteNote(String projectId, String noteId) async {
    final row = await _entities.get(kindStudyNote, noteId);
    if (row == null || row.ownerId != projectId) return;
    await _entities.delete(kindStudyNote, noteId);
  }

  /// Imports a source file into [projectId].
  ///
  /// - Same filename with different bytes receives a distinct document record
  ///   because identity is keyed by [StudySourceDocument.contentSha256].
  /// - When [candidatePdfPaths] has unconfirmed candidates and [filePath] is a
  ///   parsed Markdown companion, the document is stored as
  ///   [StudySourceStatus.pendingSourceLink] until [confirmSourceLink] is called.
  Future<StudySourceDocument> importFile({
    required String projectId,
    required String filePath,
    String? title,
    String? parsedMarkdownPath,
    List<String> candidatePdfPaths = const [],
    StudyPageRange? corpusPageRange,
  }) async {
    await _requireProject(projectId);
    final normalizedPath = p.normalize(p.absolute(filePath));
    final fileName = p.basename(normalizedPath);
    final effectiveTitle = (title == null || title.trim().isEmpty)
        ? p.basenameWithoutExtension(fileName)
        : title.trim();
    final candidates = candidatePdfPaths
        .map((item) => p.normalize(p.absolute(item)))
        .toSet()
        .toList(growable: false);
    final extension = p.extension(fileName).toLowerCase();
    final isMarkdown = extension == '.md' || extension == '.markdown';
    final isPdf = extension == '.pdf';
    final format = isPdf
        ? StudySourceFormat.pdf
        : isMarkdown
        ? StudySourceFormat.markdown
        : StudySourceFormat.text;

    if (isMarkdown && candidates.isNotEmpty) {
      final markdownRead = await Isolate.run(
        () => _readUtf8TextFile(normalizedPath),
      );
      if (markdownRead != null) {
        final candidateSet = candidates.toSet();
        for (final doc in await listDocuments(projectId)) {
          if (doc.status == StudySourceStatus.pendingSourceLink &&
              doc.contentSha256 == markdownRead.sha256Hex &&
              doc.candidatePdfPaths.toSet().containsAll(candidateSet) &&
              candidateSet.containsAll(doc.candidatePdfPaths)) {
            return doc;
          }
        }
      }
      final doc = StudySourceDocument(
        id: _uuid.v4(),
        projectId: projectId,
        title: effectiveTitle,
        fileName: fileName,
        format: StudySourceFormat.pdf,
        status: markdownRead == null
            ? StudySourceStatus.unreadable
            : StudySourceStatus.pendingSourceLink,
        contentSha256: markdownRead?.sha256Hex,
        byteLength: markdownRead?.byteLength,
        originalPath: null,
        parsedMarkdownPath: normalizedPath,
        candidatePdfPaths: candidates,
        physicalPageCount: null,
        corpusPageRange: corpusPageRange,
        extractedText: markdownRead?.text,
        importedAt: DateTime.now().toUtc(),
      );
      await _entities.upsert(
        kindStudyDocument,
        doc.id,
        doc.toJson(),
        ownerId: projectId,
      );
      return doc;
    }

    final inspected = await Isolate.run(
      () => isPdf
          ? _inspectPdfFile(
              normalizedPath,
              parsedMarkdownPath: parsedMarkdownPath,
            )
          : _inspectTextFile(normalizedPath),
    );

    if (inspected.contentSha256 != null) {
      final existing = await listDocuments(projectId);
      for (final doc in existing) {
        if (doc.contentSha256 == inspected.contentSha256 &&
            doc.status != StudySourceStatus.pendingSourceLink) {
          final merged = _mergeDuplicateDocument(
            existing: doc,
            inspected: inspected,
            corpusPageRange: corpusPageRange,
          );
          if (merged != null) {
            await _entities.upsert(
              kindStudyDocument,
              merged.id,
              merged.toJson(),
              ownerId: projectId,
            );
            return merged;
          }
          return doc;
        }
      }
    }

    final document = StudySourceDocument(
      id: _uuid.v4(),
      projectId: projectId,
      title: effectiveTitle,
      fileName: fileName,
      format: format,
      status: inspected.status,
      contentSha256: inspected.contentSha256,
      byteLength: inspected.byteLength,
      originalPath: normalizedPath,
      parsedMarkdownPath: inspected.parsedMarkdownPath,
      candidatePdfPaths: const [],
      physicalPageCount: inspected.physicalPageCount,
      corpusPageRange: corpusPageRange,
      extractedText: inspected.extractedText,
      importedAt: DateTime.now().toUtc(),
    );
    await _entities.upsert(
      kindStudyDocument,
      document.id,
      document.toJson(),
      ownerId: projectId,
    );
    return document;
  }

  /// Confirms which candidate PDF belongs to a [StudySourceStatus.pendingSourceLink]
  /// document, computing the PDF's SHA-256 and physical page count.
  Future<StudySourceDocument> confirmSourceLink({
    required String projectId,
    required String documentId,
    required String pdfPath,
  }) async {
    await _requireProject(projectId);
    final doc = await getDocument(projectId, documentId);
    if (doc == null) {
      throw StateError('Document $documentId not found in project $projectId');
    }
    if (doc.status != StudySourceStatus.pendingSourceLink) {
      throw StateError('Document $documentId is not waiting for a source link');
    }
    final normalizedPdf = p.normalize(p.absolute(pdfPath));
    if (!doc.candidatePdfPaths.contains(normalizedPdf)) {
      throw ArgumentError.value(
        pdfPath,
        'pdfPath',
        'Selected PDF is not in candidatePdfPaths',
      );
    }
    final parsedMarkdownPath = doc.parsedMarkdownPath;
    final inspected = await Isolate.run(
      () => _inspectPdfFile(
        normalizedPdf,
        parsedMarkdownPath: parsedMarkdownPath,
      ),
    );
    if (inspected.status == StudySourceStatus.unreadable) {
      throw FormatException(
        'Selected PDF is unreadable: $pdfPath',
        normalizedPdf,
      );
    }
    if (inspected.contentSha256 != null) {
      for (final other in await listDocuments(projectId)) {
        if (other.id != doc.id &&
            other.contentSha256 == inspected.contentSha256 &&
            other.status != StudySourceStatus.pendingSourceLink) {
          final merged =
              _mergeDuplicateDocument(
                existing: other,
                inspected: inspected,
                corpusPageRange: doc.corpusPageRange,
              ) ??
              other;
          await _entities.upsert(
            kindStudyDocument,
            merged.id,
            merged.toJson(),
            ownerId: projectId,
          );
          await _entities.delete(kindStudyDocument, doc.id);
          return merged;
        }
      }
    }
    final updated = StudySourceDocument(
      id: doc.id,
      projectId: doc.projectId,
      title: doc.title,
      fileName: p.basename(normalizedPdf),
      format: StudySourceFormat.pdf,
      status: inspected.status,
      contentSha256: inspected.contentSha256,
      byteLength: inspected.byteLength,
      originalPath: normalizedPdf,
      parsedMarkdownPath:
          inspected.parsedMarkdownPath ?? doc.parsedMarkdownPath,
      candidatePdfPaths: const [],
      physicalPageCount: inspected.physicalPageCount,
      corpusPageRange: doc.corpusPageRange,
      extractedText: inspected.extractedText ?? doc.extractedText,
      importedAt: doc.importedAt,
    );
    await _entities.upsert(
      kindStudyDocument,
      updated.id,
      updated.toJson(),
      ownerId: projectId,
    );
    return updated;
  }

  Future<StudySourceDocument?> getDocument(
    String projectId,
    String documentId,
  ) async {
    final row = await _entities.get(kindStudyDocument, documentId);
    if (row == null || row.ownerId != projectId) return null;
    final doc = StudySourceDocument.tryFromJson(row.payload);
    return doc != null && doc.projectId == projectId ? doc : null;
  }

  Future<List<StudySourceDocument>> listDocuments(String projectId) async {
    final rows = await _entities.listByOwner(kindStudyDocument, projectId);
    final docs = <StudySourceDocument>[];
    for (final row in rows) {
      final doc = StudySourceDocument.tryFromJson(row.payload);
      if (doc != null && doc.projectId == projectId) {
        docs.add(doc);
      }
    }
    return docs;
  }

  /// Saves a note in [projectId].
  ///
  /// A note is [StudyEvidenceStatus.grounded] only when every anchor resolves
  /// against a ready document of [projectId] and carries a quote found in that
  /// source (see [StudyResolvedCitation.isGroundedEvidence]). With
  /// [workspaceDir], section ids and section page spans are checked too.
  /// Unverified anchors are kept as written for later review, never fabricated.
  Future<StudyNote> saveNote({
    required String projectId,
    required String title,
    required String body,
    List<StudySourceAnchor> anchors = const [],
    String? conversationId,
    String? noteId,
    String? workspaceDir,
  }) async {
    await _requireProject(projectId);
    final existing = noteId == null
        ? null
        : await _entities.get(kindStudyNote, noteId);
    if (existing != null && existing.ownerId != projectId) {
      throw StateError('Note $noteId belongs to another project');
    }
    final resolver = await citationResolver(
      projectId,
      workspaceDir: workspaceDir,
    );
    final verifiedAnchors = <StudySourceAnchor>[];
    var allVerified = anchors.isNotEmpty;
    for (final anchor in anchors) {
      final resolved = resolver.resolve(anchor.toCitation());
      if (!resolved.isGroundedEvidence) allVerified = false;
      verifiedAnchors.add(resolved.toAnchor());
    }
    final now = DateTime.now().toUtc();
    final existingNote = existing == null
        ? null
        : StudyNote.tryFromJson(existing.payload);
    final createdAt = existingNote?.createdAt ?? now;
    final note = StudyNote(
      id: noteId ?? _uuid.v4(),
      projectId: projectId,
      title: title.trim(),
      body: body.trim(),
      anchors: List<StudySourceAnchor>.unmodifiable(verifiedAnchors),
      evidenceStatus: allVerified
          ? StudyEvidenceStatus.grounded
          : StudyEvidenceStatus.insufficientEvidence,
      conversationId: conversationId,
      createdAt: createdAt,
      updatedAt: now,
    );
    await _entities.upsert(
      kindStudyNote,
      note.id,
      note.toJson(),
      ownerId: projectId,
    );
    return note;
  }

  Future<List<StudyNote>> listNotes(String projectId) async {
    final rows = await _entities.listByOwner(kindStudyNote, projectId);
    final notes = <StudyNote>[];
    for (final row in rows) {
      final note = StudyNote.tryFromJson(row.payload);
      if (note != null && note.projectId == projectId) {
        notes.add(note);
      }
    }
    return notes;
  }

  /// Indexes a project document's MinerU Markdown (or text/markdown source)
  /// into `<workspaceDir>/.studypi/index/<documentId>/`.
  Future<StudyDocumentIndex> indexDocumentToWorkspace({
    required String projectId,
    required String documentId,
    required String workspaceDir,
    String? contentListJsonPath,
    StudyFastModelCompletion? fastModel,
    String? fastModelId,
    int maxSectionChars = StudyMineruIndexer.defaultMaxSectionChars,
  }) async {
    await _requireProject(projectId);
    final doc = await getDocument(projectId, documentId);
    if (doc == null) {
      throw StateError('Document $documentId not found in project $projectId');
    }
    final markdownPath = _indexedMarkdownPath(doc);
    if (markdownPath == null) {
      throw StateError(
        'Document $documentId does not have a Markdown/text parse to index',
      );
    }
    return StudyMineruIndexer.indexToWorkspace(
      documentId: doc.id,
      title: doc.title,
      markdownPath: markdownPath,
      workspaceDir: workspaceDir,
      pdfPath: doc.format == StudySourceFormat.pdf ? doc.originalPath : null,
      contentListJsonPath: contentListJsonPath,
      corpusPageRange: doc.corpusPageRange,
      fastModel: fastModel,
      fastModelId: fastModelId,
      maxSectionChars: maxSectionChars,
    );
  }

  /// Current workspace index of [documentId] with its hash-checked lines, or
  /// null when it is missing or no longer matches the document.
  Future<({StudyDocumentIndex index, List<String> lines})?> currentIndex({
    required String projectId,
    required String documentId,
    required String workspaceDir,
  }) async {
    final doc = await getDocument(projectId, documentId);
    if (doc == null) return null;
    return (await _loadCurrentIndexes(workspaceDir, [doc]))[documentId];
  }

  /// Resolver over [projectId]'s documents and their current workspace indexes.
  Future<StudyCitationResolver> citationResolver(
    String projectId, {
    String? workspaceDir,
  }) async {
    await _requireProject(projectId);
    final docs = await listDocuments(projectId);
    final loaded = await _loadCurrentIndexes(workspaceDir, docs);
    return StudyCitationResolver(
      documents: docs,
      indexes: {for (final e in loaded.entries) e.key: e.value.index},
      // Lines were read and hash-checked on the background isolate, so
      // resolving never touches the file system on the caller's thread.
      readIndexedLines: (index) => loaded[index.documentId]?.lines,
    );
  }

  /// Unindexed sources longer than this are not inlined into the system
  /// prompt; a whole textbook would exhaust the context of most models.
  static const int maxInlineSourceChars = 12000;

  /// Full system prompt for [projectId]: the stable core, [customPrompt], then
  /// [buildProjectContext]. Chat requests assemble the same layers in the
  /// message builder.
  Future<String> buildProjectSystemPrompt({
    required String projectId,
    String customPrompt = '',
    String? workspaceDir,
  }) async {
    final context = await buildProjectContext(
      projectId: projectId,
      workspaceDir: workspaceDir,
    );
    return '${StudyPrompts.compose(customPrompt)}\n\n$context';
  }

  /// The project's study mode, citation protocol and materials, isolated from
  /// every other project and with explicit source status.
  ///
  /// When [workspaceDir] holds a current [StudyDocumentIndex] for a source, its
  /// compact section map is emitted instead of the document body.
  Future<String> buildProjectContext({
    required String projectId,
    String? workspaceDir,
  }) async {
    final project = await _requireProject(projectId);
    final docs = await listDocuments(projectId);
    final buf = StringBuffer()
      ..writeln('<study_mode mode="${project.mode.name}">')
      ..writeln(StudyPrompts.modeInstruction(project.mode))
      ..writeln('</study_mode>')
      ..write(
        '<study_project_context project_id="${_escapeXmlAttr(project.id)}">\n',
      )
      ..writeln('project_title: ${_escapeXmlText(project.title)}');
    if (project.goal.isNotEmpty) {
      buf.writeln('project_goal: ${_escapeXmlText(project.goal)}');
    }
    if (docs.any((doc) => doc.status == StudySourceStatus.ready)) {
      buf.writeln(StudyPrompts.citationProtocol);
    }
    final loaded = await _loadCurrentIndexes(
      workspaceDir,
      docs,
      withLines: false,
    );
    for (final doc in docs) {
      final cachedIndex = loaded[doc.id]?.index;
      final text = doc.status == StudySourceStatus.ready
          ? doc.extractedText?.trim() ?? ''
          : '';
      final inlineText =
          cachedIndex == null &&
          text.isNotEmpty &&
          text.length <= maxInlineSourceChars;
      buf.write(
        '<study_source id="${_escapeXmlAttr(doc.id)}" '
        'title="${_escapeXmlAttr(doc.title)}" '
        'file="${_escapeXmlAttr(doc.fileName)}" '
        'status="${_escapeXmlAttr(doc.status.name)}"',
      );
      if (doc.contentSha256 != null) {
        buf.write(' sha256="${_escapeXmlAttr(doc.contentSha256!)}"');
      }
      if (doc.physicalPageCount != null) {
        buf.write(' physical_pages="${doc.physicalPageCount}"');
      }
      if (doc.corpusPageRange != null) {
        buf.write(
          ' corpus_pages="${_escapeXmlAttr(doc.corpusPageRange!.label)}"',
        );
      }
      if (cachedIndex != null) {
        buf.write(
          ' index_mode="${_escapeXmlAttr(cachedIndex.indexMode.name)}"',
        );
      } else if (text.isNotEmpty && !inlineText) {
        buf.write(' content="not_inlined" chars="${text.length}"');
      }
      buf.writeln('>');
      if (cachedIndex != null) {
        buf.writeln(_escapeXmlText(cachedIndex.toWorkspaceMarkdown().trim()));
      } else if (inlineText) {
        buf.writeln(_escapeXmlText(text));
      } else if (text.isNotEmpty) {
        buf.writeln('正文过长，未放入上下文，也尚未建立章节索引。不要凭标题推测内容；需要时请用户先为该材料建立索引。');
      }
      buf.writeln('</study_source>');
    }
    buf.write('</study_project_context>');
    return buf.toString();
  }

  /// Workspace indexes that still describe each document's current source:
  /// same document, Markdown path and hash, PDF hash and textbook page range.
  /// Hashing runs on a background isolate.
  static Future<Map<String, ({StudyDocumentIndex index, List<String> lines})>>
  _loadCurrentIndexes(
    String? workspaceDir,
    List<StudySourceDocument> docs, {
    bool withLines = true,
  }) async {
    if (workspaceDir == null) return const {};
    final root = p.normalize(p.absolute(workspaceDir));
    final probes = [
      for (final doc in docs)
        if (doc.status == StudySourceStatus.ready &&
            doc.contentSha256 != null &&
            _indexedMarkdownPath(doc) != null)
          (
            id: doc.id,
            isPdf: doc.format == StudySourceFormat.pdf,
            contentSha256: doc.contentSha256!,
            markdownPath: _indexedMarkdownPath(doc)!,
            corpusPageRange: doc.corpusPageRange,
          ),
    ];
    if (probes.isEmpty) return const {};
    return Isolate.run(() {
      final result =
          <String, ({StudyDocumentIndex index, List<String> lines})>{};
      for (final probe in probes) {
        final current = _readIndexIfCurrent(root, probe);
        if (current != null) {
          // Prompts only need the section map; skip copying whole books back.
          result[probe.id] = withLines
              ? current
              : (index: current.index, lines: const <String>[]);
        }
      }
      return result;
    });
  }

  static String? _indexedMarkdownPath(StudySourceDocument doc) {
    final path =
        doc.parsedMarkdownPath ??
        (doc.format != StudySourceFormat.pdf ? doc.originalPath : null);
    if (path == null || path.trim().isEmpty) return null;
    return p.normalize(p.absolute(path));
  }

  static ({StudyDocumentIndex index, List<String> lines})? _readIndexIfCurrent(
    String workspaceRoot,
    ({
      String id,
      bool isPdf,
      String contentSha256,
      String markdownPath,
      StudyPageRange? corpusPageRange,
    })
    probe,
  ) {
    try {
      final indexFile = File(
        p.join(workspaceRoot, '.studypi', 'index', probe.id, 'index.json'),
      );
      if (!indexFile.existsSync()) return null;
      final decoded = jsonDecode(indexFile.readAsStringSync());
      if (decoded is! Map) return null;
      final index = StudyDocumentIndex.tryFromJson(
        decoded.cast<String, dynamic>(),
      );
      if (index == null ||
          index.documentId != probe.id ||
          index.markdownPath != probe.markdownPath ||
          index.corpusPageRange != probe.corpusPageRange) {
        return null;
      }
      final sourceSha = probe.isPdf ? index.pdfSha256 : index.markdownSha256;
      if (sourceSha != probe.contentSha256) return null;
      final lines = StudyMineruIndexer.tryReadIndexedLines(index);
      return lines == null ? null : (index: index, lines: lines);
    } catch (_) {
      return null;
    }
  }

  Future<StudyProject> _requireProject(String projectId) async {
    final project = await getProject(projectId);
    if (project == null) {
      throw StateError('StudyProject not found: $projectId');
    }
    return project;
  }

  static StudySourceDocument? _mergeDuplicateDocument({
    required StudySourceDocument existing,
    required _InspectedSource inspected,
    required StudyPageRange? corpusPageRange,
  }) {
    final nextStatus =
        existing.status == StudySourceStatus.ready ||
            inspected.status == StudySourceStatus.ready
        ? StudySourceStatus.ready
        : existing.status;
    final nextMarkdown =
        inspected.parsedMarkdownPath ?? existing.parsedMarkdownPath;
    final nextText =
        (inspected.extractedText != null &&
            inspected.extractedText!.trim().isNotEmpty)
        ? inspected.extractedText
        : existing.extractedText;
    final nextPages = inspected.physicalPageCount ?? existing.physicalPageCount;
    final nextRange = corpusPageRange ?? existing.corpusPageRange;
    if (nextStatus == existing.status &&
        nextMarkdown == existing.parsedMarkdownPath &&
        nextText == existing.extractedText &&
        nextPages == existing.physicalPageCount &&
        nextRange == existing.corpusPageRange) {
      return null;
    }
    return StudySourceDocument(
      id: existing.id,
      projectId: existing.projectId,
      title: existing.title,
      fileName: existing.fileName,
      format: existing.format,
      status: nextStatus,
      contentSha256: existing.contentSha256,
      byteLength: existing.byteLength ?? inspected.byteLength,
      originalPath: existing.originalPath,
      parsedMarkdownPath: nextMarkdown,
      candidatePdfPaths: const [],
      physicalPageCount: nextPages,
      corpusPageRange: nextRange,
      extractedText: nextText,
      importedAt: existing.importedAt,
    );
  }

  static String _escapeXmlText(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escapeXmlAttr(String text) =>
      _escapeXmlText(text).replaceAll('"', '&quot;');

  static _InspectedSource _inspectTextFile(String path) {
    final read = _readUtf8TextFile(path);
    if (read == null || read.text.isEmpty) {
      return _InspectedSource(
        status: StudySourceStatus.unreadable,
        contentSha256: read?.sha256Hex,
        byteLength: read?.byteLength,
      );
    }
    return _InspectedSource(
      status: StudySourceStatus.ready,
      contentSha256: read.sha256Hex,
      byteLength: read.byteLength,
      extractedText: read.text,
    );
  }

  static _InspectedSource _inspectPdfFile(
    String path, {
    String? parsedMarkdownPath,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      return const _InspectedSource(status: StudySourceStatus.unreadable);
    }
    late final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } catch (_) {
      return const _InspectedSource(status: StudySourceStatus.unreadable);
    }
    if (bytes.isEmpty) {
      return const _InspectedSource(status: StudySourceStatus.unreadable);
    }
    final sha256Hex = sha256.convert(bytes).toString();
    final normalizedMarkdown =
        parsedMarkdownPath == null || parsedMarkdownPath.trim().isEmpty
        ? null
        : p.normalize(p.absolute(parsedMarkdownPath));
    final markdownRead = normalizedMarkdown == null
        ? null
        : _readUtf8TextFile(normalizedMarkdown);

    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      final pageCount = document.pages.count;
      if (pageCount <= 0) {
        return _InspectedSource(
          status: StudySourceStatus.unreadable,
          contentSha256: sha256Hex,
          byteLength: bytes.length,
        );
      }
      final pdfText = UnicodeSanitizer.sanitize(
        PdfTextExtractor(document).extractText(),
      ).trim();
      final effectiveText =
          (markdownRead != null && markdownRead.text.isNotEmpty)
          ? markdownRead.text
          : pdfText;
      if (effectiveText.isEmpty) {
        return _InspectedSource(
          status: StudySourceStatus.scannedNeedsOcr,
          contentSha256: sha256Hex,
          byteLength: bytes.length,
          physicalPageCount: pageCount,
        );
      }
      return _InspectedSource(
        status: StudySourceStatus.ready,
        contentSha256: sha256Hex,
        byteLength: bytes.length,
        parsedMarkdownPath: markdownRead == null ? null : normalizedMarkdown,
        physicalPageCount: pageCount,
        extractedText: effectiveText,
      );
    } catch (_) {
      return _InspectedSource(
        status: StudySourceStatus.unreadable,
        contentSha256: sha256Hex,
        byteLength: bytes.length,
      );
    } finally {
      document?.dispose();
    }
  }

  static ({String text, String sha256Hex, int byteLength})? _readUtf8TextFile(
    String path,
  ) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.contains(0)) return null;
      final sha256Hex = sha256.convert(bytes).toString();
      final decoded = UnicodeSanitizer.sanitize(utf8.decode(bytes)).trim();
      return (text: decoded, sha256Hex: sha256Hex, byteLength: bytes.length);
    } catch (_) {
      return null;
    }
  }
}

String? _optionalString(Object? value) => value is String ? value : null;

int? _optionalInt(Object? value) => value is num ? value.toInt() : null;

DateTime? _tryParseUtc(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

class _InspectedSource {
  const _InspectedSource({
    required this.status,
    this.contentSha256,
    this.byteLength,
    this.parsedMarkdownPath,
    this.physicalPageCount,
    this.extractedText,
  });

  final StudySourceStatus status;
  final String? contentSha256;
  final int? byteLength;
  final String? parsedMarkdownPath;
  final int? physicalPageCount;
  final String? extractedText;
}
