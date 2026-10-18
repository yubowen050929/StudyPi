import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../core/database/extension_entity_store.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/study/study_citation_resolver.dart';
import '../../../core/services/study/study_corpus.dart';
import '../../../core/services/study/study_mineru_indexer.dart';
import '../../../core/services/study/study_project_store.dart';
import '../../../core/services/study/study_prompts.dart';
import '../../../utils/app_directories.dart';

/// App-level owner of study projects: the store, each project's files under
/// `<appData>/study/<id>`, cached documents/notes, and citation resolvers.
///
/// Imported files are copied into the project directory. Picked files can
/// live in temporary locations (Android's picker cache), and a source must not
/// change underneath its recorded hash.
class StudyProjectProvider extends ChangeNotifier {
  StudyProjectProvider({
    required ExtensionEntityStore entities,
    Future<Directory> Function(String projectId)? projectDir,
  }) : store = StudyProjectStore(entities),
       _projectDir = projectDir ?? AppDirectories.studyProjectDir {
    loaded = _loadProjects();
  }

  final StudyProjectStore store;
  final Future<Directory> Function(String projectId) _projectDir;
  late final Future<void> loaded;

  List<StudyProject> _projects = const [];
  final Map<String, List<StudySourceDocument>> _documents = {};
  final Map<String, List<StudyNote>> _notes = {};
  final Map<String, StudyCitationResolver> _resolvers = {};
  final Map<String, Future<StudyCitationResolver>> _resolverLoads = {};
  final Map<String, int> _resolverGenerations = {};
  final Map<String, DateTime> _resolverFailures = {};
  static const Duration _resolverRetryDelay = Duration(seconds: 30);
  final Set<String> _indexingDocuments = {};
  bool _disposed = false;

  /// Most recently updated first.
  List<StudyProject> get projects => _projects;

  StudyProject? projectById(String id) {
    for (final project in _projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  StudyProject? projectForConversation(String conversationId) {
    if (conversationId.isEmpty) return null;
    for (final project in _projects) {
      if (project.conversationIds.contains(conversationId)) return project;
    }
    return null;
  }

  /// Null until [ensureProjectLoaded] has read the project's documents.
  List<StudySourceDocument>? documentsOf(String projectId) =>
      _documents[projectId];

  List<StudyNote>? notesOf(String projectId) => _notes[projectId];

  bool isIndexing(String documentId) => _indexingDocuments.contains(documentId);

  /// The resolver if already loaded; never starts a load.
  StudyCitationResolver? cachedResolver(String projectId) =>
      _resolvers[projectId];

  /// Cached resolver for [projectId]; null while it is (re)loading. A load is
  /// started on demand and listeners are notified when it is ready.
  StudyCitationResolver? resolverFor(String projectId) {
    final cached = _resolvers[projectId];
    if (cached != null) return cached;
    final failedAt = _resolverFailures[projectId];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _resolverRetryDelay) {
      return null;
    }
    unawaited(loadResolver(projectId).catchError((_) => _unavailable));
    return null;
  }

  Future<StudyCitationResolver> loadResolver(String projectId) {
    final cached = _resolvers[projectId];
    if (cached != null) return Future.value(cached);
    final pending = _resolverLoads[projectId];
    if (pending != null) return pending;
    final generation = _resolverGenerations[projectId] ?? 0;
    final future = () async {
      final dir = await _projectDir(projectId);
      final resolver = await store.citationResolver(
        projectId,
        workspaceDir: dir.path,
      );
      // A mutation during the load makes this result stale; retry once fresh.
      if ((_resolverGenerations[projectId] ?? 0) != generation) {
        _resolverLoads.remove(projectId);
        return loadResolver(projectId);
      }
      _resolvers[projectId] = resolver;
      _resolverLoads.remove(projectId);
      _resolverFailures.remove(projectId);
      _notify();
      return resolver;
    }();
    _resolverLoads[projectId] = future;
    future.catchError((Object e) {
      debugPrint('Failed to load study citations for $projectId: $e');
      _resolverLoads.remove(projectId);
      _resolverFailures[projectId] = DateTime.now();
      return _unavailable;
    });
    return future;
  }

  static final StudyCitationResolver _unavailable = StudyCitationResolver(
    documents: const [],
  );

  Future<String> projectDirectory(String projectId) async =>
      (await _projectDir(projectId)).path;

  Future<void> _loadProjects() async {
    try {
      _setProjects(await store.listProjects());
    } catch (e) {
      debugPrint('Failed to load study projects: $e');
      _setProjects(const []);
    }
  }

  void _setProjects(List<StudyProject> projects) {
    _projects = [...projects]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _notify();
  }

  void _replaceProject(StudyProject project) {
    _setProjects([
      for (final item in _projects)
        if (item.id != project.id) item,
      project,
    ]);
  }

  Future<void> ensureProjectLoaded(String projectId) async {
    await loaded;
    try {
      final docs = await store.listDocuments(projectId);
      final notes = await store.listNotes(projectId);
      _documents[projectId] = docs;
      _notes[projectId] = [...notes]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (e) {
      // Show an empty project rather than a spinner that never ends.
      debugPrint('Failed to load study project $projectId: $e');
      _documents[projectId] ??= const [];
      _notes[projectId] ??= const [];
    } finally {
      _notify();
    }
  }

  Future<void> _reloadDocuments(String projectId) async {
    _invalidateResolver(projectId);
    try {
      _documents[projectId] = await store.listDocuments(projectId);
    } finally {
      _notify();
    }
  }

  void _invalidateResolver(String projectId) {
    _resolvers.remove(projectId);
    _resolverFailures.remove(projectId);
    _resolverGenerations[projectId] =
        (_resolverGenerations[projectId] ?? 0) + 1;
  }

  Future<StudyProject> createProject({
    required String title,
    String goal = '',
    StudyInteractionMode mode = StudyInteractionMode.explain,
  }) async {
    await loaded;
    final project = await store.createProject(
      title: title,
      goal: goal,
      mode: mode,
    );
    await _projectDir(project.id);
    _documents[project.id] = const [];
    _notes[project.id] = const [];
    _replaceProject(project);
    return project;
  }

  Future<StudyProject> updateProject(
    String projectId, {
    String? title,
    String? goal,
    StudyInteractionMode? mode,
  }) async {
    var project = await store.updateProject(
      projectId,
      title: title,
      goal: goal,
    );
    if (mode != null && mode != project.mode) {
      project = await store.updateProjectMode(projectId, mode);
    }
    _replaceProject(project);
    return project;
  }

  /// Deletes the project, its records and its files. Bound conversations stay
  /// as ordinary chats.
  Future<void> deleteProject(String projectId) async {
    await store.deleteProject(projectId);
    _documents.remove(projectId);
    _notes.remove(projectId);
    _invalidateResolver(projectId);
    _setProjects([
      for (final item in _projects)
        if (item.id != projectId) item,
    ]);
    await _deleteQuietly(Directory(await projectDirectory(projectId)));
  }

  /// Copies each file into the project and imports it. A file whose bytes are
  /// already in the project resolves to the existing document.
  Future<List<StudySourceDocument>> importFiles(
    String projectId,
    List<String> paths,
  ) async {
    final sources = Directory(
      p.join(await projectDirectory(projectId), 'sources'),
    );
    await sources.create(recursive: true);
    final imported = <StudySourceDocument>[];
    try {
      for (final path in paths) {
        final copy = await _copyInto(File(path), sources);
        final StudySourceDocument doc;
        try {
          doc = await store.importFile(
            projectId: projectId,
            filePath: copy.path,
            corpusPageRange: _bookPagesFromName(path),
          );
        } catch (_) {
          await _deleteQuietly(copy);
          rethrow;
        }
        if (doc.originalPath != p.normalize(p.absolute(copy.path)) &&
            doc.parsedMarkdownPath != p.normalize(p.absolute(copy.path))) {
          await copy.delete();
        }
        imported.add(doc);
      }
    } finally {
      await _reloadDocuments(projectId);
    }
    return imported;
  }

  /// Attaches a MinerU (or other) Markdown parse to a PDF document. A sibling
  /// `*_content_list.json` maps sections to PDF pages when supplied.
  Future<StudySourceDocument> attachParsedMarkdown(
    String projectId,
    String documentId, {
    required String markdownPath,
    String? contentListPath,
  }) async {
    final doc = await store.getDocument(projectId, documentId);
    final pdfPath = doc?.originalPath;
    if (doc == null || doc.format != StudySourceFormat.pdf || pdfPath == null) {
      throw StateError('Document $documentId has no PDF to attach a parse to');
    }
    final dir = Directory(
      p.join(
        await projectDirectory(projectId),
        'sources',
        '${documentId}_parsed_${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    await dir.create(recursive: true);
    final md = await _copyInto(File(markdownPath), dir);
    if (contentListPath != null) {
      await File(contentListPath).copy(
        p.join(
          dir.path,
          '${p.basenameWithoutExtension(md.path)}_content_list.json',
        ),
      );
    }
    final previousParse = doc.parsedMarkdownPath;
    try {
      final updated = await store.importFile(
        projectId: projectId,
        filePath: pdfPath,
        title: doc.title,
        parsedMarkdownPath: md.path,
        corpusPageRange: doc.corpusPageRange,
      );
      if (previousParse != null &&
          previousParse != updated.parsedMarkdownPath) {
        await _deleteOwnedParent(projectId, previousParse);
      }
      return updated;
    } finally {
      await _reloadDocuments(projectId);
    }
  }

  Future<StudySourceDocument> confirmSourceLink(
    String projectId,
    String documentId,
    String pdfPath,
  ) async {
    try {
      return await store.confirmSourceLink(
        projectId: projectId,
        documentId: documentId,
        pdfPath: pdfPath,
      );
    } finally {
      await _reloadDocuments(projectId);
    }
  }

  /// Removes the record first; leftover files are cleaned up best-effort so a
  /// locked file never leaves a deleted document visible.
  Future<void> deleteDocument(String projectId, String documentId) async {
    final doc = await store.getDocument(projectId, documentId);
    try {
      await store.deleteDocument(projectId, documentId);
    } finally {
      await _reloadDocuments(projectId);
    }
    final root = await projectDirectory(projectId);
    final sources = p.join(root, 'sources');
    if (doc != null) {
      for (final path in [doc.originalPath, doc.parsedMarkdownPath]) {
        if (path != null && p.isWithin(sources, path)) {
          await _deleteQuietly(File(path));
        }
      }
      final parse = doc.parsedMarkdownPath;
      if (parse != null) await _deleteOwnedParent(projectId, parse);
    }
    await _deleteQuietly(
      Directory(p.join(root, '.studypi', 'index', documentId)),
    );
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (e) {
      debugPrint('Could not delete ${entity.path}: $e');
    }
  }

  /// Builds (or reuses) the document's workspace index. Without [fastModel]
  /// the index is deterministic: headings, bold terms and opening sentences.
  Future<StudyDocumentIndex> buildIndex(
    String projectId,
    String documentId, {
    StudyFastModelCompletion? fastModel,
    String? fastModelId,
  }) async {
    _indexingDocuments.add(documentId);
    _notify();
    try {
      return await store.indexDocumentToWorkspace(
        projectId: projectId,
        documentId: documentId,
        workspaceDir: await projectDirectory(projectId),
        fastModel: fastModel,
        fastModelId: fastModelId,
      );
    } finally {
      _indexingDocuments.remove(documentId);
      _invalidateResolver(projectId);
      _notify();
    }
  }

  Future<({StudyDocumentIndex index, List<String> lines})?> currentIndex(
    String projectId,
    String documentId,
  ) async {
    return store.currentIndex(
      projectId: projectId,
      documentId: documentId,
      workspaceDir: await projectDirectory(projectId),
    );
  }

  /// Creates a conversation bound to [projectId] and returns its id. The
  /// caller opens it (see `NotificationService.openConversation`).
  Future<String> startDiscussion(
    String projectId,
    ChatService chat, {
    String? assistantId,
  }) async {
    final project = projectById(projectId);
    if (project == null) throw StateError('Unknown study project $projectId');
    final conversation = await chat.createConversation(
      title: project.title,
      assistantId: assistantId,
    );
    _replaceProject(await store.bindConversation(projectId, conversation.id));
    return conversation.id;
  }

  Future<void> unbindConversation(
    String projectId,
    String conversationId,
  ) async {
    _replaceProject(await store.unbindConversation(projectId, conversationId));
  }

  /// Study mode, citation protocol and materials for a bound conversation;
  /// null for ordinary chats.
  Future<String?> promptContextForConversation(String conversationId) async {
    await loaded;
    final project = projectForConversation(conversationId);
    if (project == null) return null;
    return store.buildProjectContext(
      projectId: project.id,
      workspaceDir: await projectDirectory(project.id),
    );
  }

  Future<StudyNote> saveNote(
    String projectId, {
    required String title,
    required String body,
    List<StudySourceAnchor> anchors = const [],
    String? conversationId,
    String? noteId,
  }) async {
    final note = await store.saveNote(
      projectId: projectId,
      title: title,
      body: body,
      anchors: anchors,
      conversationId: conversationId,
      noteId: noteId,
      workspaceDir: await projectDirectory(projectId),
    );
    _notes[projectId] = [
      note,
      for (final item in _notes[projectId] ?? const <StudyNote>[])
        if (item.id != note.id) item,
    ];
    _notify();
    return note;
  }

  Future<void> deleteNote(String projectId, String noteId) async {
    await store.deleteNote(projectId, noteId);
    _notes[projectId] = [
      for (final item in _notes[projectId] ?? const <StudyNote>[])
        if (item.id != noteId) item,
    ];
    _notify();
  }

  /// Textbook pages named in the file (`教材_207-359.pdf`). Only an
  /// unambiguous single range is used; a merged `1-91-92-206` stays unset.
  static StudyPageRange? _bookPagesFromName(String path) {
    final ranges = studyPageRangesInName(p.basenameWithoutExtension(path));
    return ranges.length == 1 ? ranges.single : null;
  }

  Future<File> _copyInto(File source, Directory dir) async {
    final name = p.basename(source.path);
    var target = File(p.join(dir.path, name));
    var n = 1;
    while (await target.exists()) {
      target = File(
        p.join(
          dir.path,
          '${p.basenameWithoutExtension(name)} ($n)${p.extension(name)}',
        ),
      );
      n++;
    }
    return source.copy(target.path);
  }

  /// Removes a `*_parsed_*` directory this provider created for a parse.
  Future<void> _deleteOwnedParent(String projectId, String path) async {
    final sources = p.join(await projectDirectory(projectId), 'sources');
    final parent = p.dirname(path);
    if (p.isWithin(sources, parent) &&
        p.basename(parent).contains('_parsed_')) {
      await _deleteQuietly(Directory(parent));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// The provider, or null where the app tree does not install one (tests,
  /// secondary windows).
  static StudyProjectProvider? maybeOf(BuildContext context) {
    try {
      return Provider.of<StudyProjectProvider>(context, listen: false);
    } catch (_) {
      // Not installed above this context (or a detached test context).
      return null;
    }
  }
}
