import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/haptics.dart';
import 'package:Kelivo/core/services/notification_service.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/core/services/study/study_prompts.dart';
import 'package:Kelivo/desktop/menu_anchor.dart';
import 'package:Kelivo/features/study/pages/study_source_reader_page.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/features/study/widgets/study_action.dart';
import 'package:Kelivo/features/study/widgets/study_badges.dart';
import 'package:Kelivo/features/study/widgets/study_project_dialogs.dart';
import 'package:Kelivo/features/workspace/widgets/files/workspace_prompts.dart';
import 'package:Kelivo/features/workspace/workspace_layout.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/action_sheet.dart';
import 'package:Kelivo/shared/widgets/ios_settings_rows.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/shared/widgets/option_sheet.dart';
import 'package:Kelivo/shared/widgets/section_card.dart';
import 'package:Kelivo/shared/widgets/segmented_tabs.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

class StudyProjectPage extends StatelessWidget {
  const StudyProjectPage({super.key, required this.projectId});

  final String projectId;

  Future<void> _showProjectMenu(
    BuildContext context,
    StudyProject project, {
    Offset? anchor,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<StudyProjectProvider>();
    await showAdaptiveActionMenu(
      context,
      anchor: anchor ?? DesktopMenuAnchor.positionOrCenter(context),
      items: [
        ActionSheetItem(
          icon: Lucide.Pencil,
          label: l10n.studyProjectEdit,
          onTap: () => unawaited(showEditStudyProjectDialog(context, project)),
        ),
        ActionSheetItem(
          icon: Lucide.Trash2,
          label: l10n.studyProjectDelete,
          destructive: true,
          onTap: () async {
            final confirmed = await confirmDeleteStudyProject(context, project);
            if (!confirmed || !context.mounted) return;
            final deleted = await runStudyAction(
              context,
              () => provider.deleteProject(project.id).then((_) => true),
            );
            if (deleted == true && context.mounted) {
              Navigator.of(context).maybePop();
            }
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final project = context.select<StudyProjectProvider, StudyProject?>(
      (p) => p.projectById(projectId),
    );

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () {
              Haptics.light();
              Navigator.of(context).maybePop();
            },
          ),
        ),
        title: Text(
          project?.title ?? l10n.studyProjectsTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (project != null)
            Builder(
              builder: (buttonCtx) => Tooltip(
                message: l10n.studyProjectMoreActions,
                child: IosIconButton(
                  icon: Lucide.Ellipsis,
                  color: cs.onSurface,
                  size: 22,
                  minSize: 44,
                  semanticLabel: l10n.studyProjectMoreActions,
                  onTap: () {
                    Haptics.light();
                    final box = buttonCtx.findRenderObject() as RenderBox?;
                    final anchor = (box != null && box.hasSize)
                        ? box.localToGlobal(box.size.center(Offset.zero))
                        : DesktopMenuAnchor.positionOrCenter(buttonCtx);
                    unawaited(
                      _showProjectMenu(buttonCtx, project, anchor: anchor),
                    );
                  },
                ),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: StudyProjectPane(projectId: projectId),
    );
  }
}

class StudyProjectPane extends StatefulWidget {
  const StudyProjectPane({
    super.key,
    required this.projectId,
    this.showDesktopHeader = false,
  });

  final String projectId;
  final bool showDesktopHeader;

  @override
  State<StudyProjectPane> createState() => _StudyProjectPaneState();
}

bool _hasChatService(BuildContext context) {
  try {
    Provider.of<ChatService>(context, listen: false);
    return true;
  } catch (_) {
    return false;
  }
}

class _StudyProjectPaneState extends State<StudyProjectPane> {
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      context.read<StudyProjectProvider>().ensureProjectLoaded(
        widget.projectId,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant StudyProjectPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) {
      unawaited(
        context.read<StudyProjectProvider>().ensureProjectLoaded(
          widget.projectId,
        ),
      );
    }
  }

  Future<void> _importMaterials() async {
    if (_importing) return;
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<StudyProjectProvider>();
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'md', 'markdown', 'txt'],
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.studyMaterialsImportFailed(e.toString()),
        type: NotificationType.error,
      );
      return;
    }
    if (picked == null || !mounted) return;
    final paths = [
      for (final file in picked.files)
        if (file.path != null && file.path!.trim().isNotEmpty) file.path!,
    ];
    if (paths.isEmpty) return;

    setState(() => _importing = true);
    try {
      await provider.importFiles(widget.projectId, paths);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.studyMaterialsImportFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _buildDocumentIndex(StudySourceDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<StudyProjectProvider>();
    try {
      await provider.buildIndex(widget.projectId, doc.id);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.studyDocIndexFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _attachParsedMarkdown(StudySourceDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<StudyProjectProvider>();
    try {
      final mdResult = await FilePicker.platform.pickFiles(
        dialogTitle: l10n.studyDocAttachMarkdownTitle,
        type: FileType.custom,
        allowedExtensions: const ['md', 'markdown'],
      );
      final mdPath = mdResult?.files.singleOrNull?.path;
      if (mdPath == null || !mounted) return;

      final jsonResult = await FilePicker.platform.pickFiles(
        dialogTitle: l10n.studyDocAttachContentListTitle,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final jsonPath = jsonResult?.files.singleOrNull?.path;
      if (!mounted) return;

      await provider.attachParsedMarkdown(
        widget.projectId,
        doc.id,
        markdownPath: mdPath,
        contentListPath: jsonPath,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.studyMaterialsImportFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _confirmSourceLink(StudySourceDocument doc) async {
    if (doc.candidatePdfPaths.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<StudyProjectProvider>();
    final selectedPath = await showOptionSheet<String>(
      context,
      title: l10n.studyDocConfirmSourceTitle,
      items: [
        for (final candidate in doc.candidatePdfPaths)
          OptionSheetItem<String>(
            value: candidate,
            icon: Lucide.FileText,
            label: p.basename(candidate),
            subtitle: candidate,
          ),
      ],
    );
    if (selectedPath == null || !mounted) return;
    try {
      await provider.confirmSourceLink(widget.projectId, doc.id, selectedPath);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.studyMaterialsImportFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _deleteDocument(StudySourceDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<StudyProjectProvider>();
    final confirmed = await showWorkspaceConfirm(
      context: context,
      title: l10n.studyDocDeleteTitle,
      message: l10n.studyDocDeleteMessage(doc.title),
      confirmLabel: l10n.studyProjectConfirmDelete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await runStudyAction(
      context,
      () => provider.deleteDocument(widget.projectId, doc.id),
    );
  }

  Future<void> _showDocumentActions(
    StudySourceDocument doc, {
    required bool isIndexed,
    Offset? anchor,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final canBuildIndex =
        doc.status == StudySourceStatus.ready ||
        (doc.parsedMarkdownPath != null &&
            doc.parsedMarkdownPath!.trim().isNotEmpty);

    await showAdaptiveActionMenu(
      context,
      anchor: anchor ?? DesktopMenuAnchor.positionOrCenter(context),
      items: [
        ActionSheetItem(
          icon: Lucide.BookOpen,
          label: l10n.studyDocActionRead,
          onTap: () => unawaited(
            openStudySourceReader(
              context,
              projectId: widget.projectId,
              documentId: doc.id,
            ),
          ),
        ),
        if (canBuildIndex)
          ActionSheetItem(
            icon: Lucide.Sparkles,
            label: isIndexed
                ? l10n.studyDocActionRebuildIndex
                : l10n.studyDocActionBuildIndex,
            onTap: () => unawaited(_buildDocumentIndex(doc)),
          ),
        if (doc.format == StudySourceFormat.pdf)
          ActionSheetItem(
            icon: Lucide.FilePlus,
            label: l10n.studyDocActionAttachParse,
            onTap: () => unawaited(_attachParsedMarkdown(doc)),
          ),
        if (doc.status == StudySourceStatus.pendingSourceLink &&
            doc.candidatePdfPaths.isNotEmpty)
          ActionSheetItem(
            icon: Lucide.Link,
            label: l10n.studyDocActionConfirmSource,
            onTap: () => unawaited(_confirmSourceLink(doc)),
          ),
        ActionSheetItem(
          icon: Lucide.Trash2,
          label: l10n.studyDocActionDelete,
          destructive: true,
          onTap: () => unawaited(_deleteDocument(doc)),
        ),
      ],
    );
  }

  void _openConversation(String conversationId) {
    if (!useDesktopWorkspaceLayout(context)) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
    NotificationService.openConversation(conversationId);
  }

  Future<void> _startDiscussion() async {
    final provider = context.read<StudyProjectProvider>();
    final chat = context.read<ChatService>();
    final assistantId = context.read<AssistantProvider>().currentAssistantId;
    final id = await runStudyAction(
      context,
      () => provider.startDiscussion(
        widget.projectId,
        chat,
        assistantId: assistantId,
      ),
    );
    if (id == null) return;
    if (!mounted) return;
    _openConversation(id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<StudyProjectProvider>();
    final project = provider.projectById(widget.projectId);
    if (project == null) {
      return Center(
        child: Text(
          l10n.studyProjectsSelectHint,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
        ),
      );
    }

    final documents = provider.documentsOf(project.id);
    final notes = provider.notesOf(project.id);
    final resolver = provider.resolverFor(project.id);

    // Only the bound conversations' titles matter here. ChatService notifies
    // on every streamed chunk, and on desktop this pane stays mounted.
    final hasChatService = _hasChatService(context);
    final titleKey = hasChatService
        ? context.select<ChatService, String>(
            (chat) => [
              for (final id in project.conversationIds)
                '$id\u0001${chat.getConversation(id)?.title ?? '\u0002'}',
            ].join('\u0000'),
          )
        : '';
    final boundConversations = <({String id, String title})>[];
    for (final entry
        in titleKey.isEmpty ? const <String>[] : titleKey.split('\u0000')) {
      final parts = entry.split('\u0001');
      if (parts.length != 2 || parts[1] == '\u0002') continue;
      final title = parts[1].trim().isEmpty
          ? l10n.studyDiscussionsUnnamed
          : parts[1];
      boundConversations.add((id: parts[0], title: title));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        if (widget.showDesktopHeader) ...[
          _DesktopProjectTitleBar(project: project),
          const SizedBox(height: 12),
        ],
        _ProjectHeaderSection(project: project),
        const SizedBox(height: 18),
        _SectionHeaderWithAction(
          title: l10n.studyMaterialsSection,
          actionLabel: l10n.studyMaterialsImport,
          actionIcon: Lucide.Upload,
          busy: _importing,
          onAction: () {
            Haptics.light();
            unawaited(_importMaterials());
          },
        ),
        if (_importing)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                const CupertinoActivityIndicator(radius: 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.studyMaterialsImporting,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (documents == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CupertinoActivityIndicator(radius: 12)),
          )
        else if (documents.isEmpty)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.studyMaterialsEmpty,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          )
        else
          SectionCard(
            children: [
              for (var i = 0; i < documents.length; i++) ...[
                if (i > 0) const IosRowDivider(indent: 12),
                _StudyDocumentRow(
                  document: documents[i],
                  isIndexed: resolver?.indexOf(documents[i].id) != null,
                  isIndexing: provider.isIndexing(documents[i].id),
                  onRead: () => unawaited(
                    openStudySourceReader(
                      context,
                      projectId: project.id,
                      documentId: documents[i].id,
                    ),
                  ),
                  onMore: (anchor) => unawaited(
                    _showDocumentActions(
                      documents[i],
                      isIndexed: resolver?.indexOf(documents[i].id) != null,
                      anchor: anchor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        const SizedBox(height: 18),
        _SectionHeaderWithAction(
          title: l10n.studyDiscussionsSection,
          actionLabel: l10n.studyDiscussionsStart,
          actionIcon: Lucide.MessageCirclePlus,
          onAction: !hasChatService
              ? null
              : () {
                  Haptics.light();
                  unawaited(_startDiscussion());
                },
        ),
        if (boundConversations.isEmpty)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.studyDiscussionsEmpty,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          )
        else
          SectionCard(
            children: [
              for (var i = 0; i < boundConversations.length; i++) ...[
                if (i > 0) const IosRowDivider(),
                IosNavRow(
                  icon: Lucide.MessageCircle,
                  label: boundConversations[i].title,
                  labelWeight: AppFontWeights.medium,
                  onTap: () {
                    Haptics.light();
                    _openConversation(boundConversations[i].id);
                  },
                ),
              ],
            ],
          ),
        IosSectionFooter(text: l10n.studyDiscussionsCaption),
        const SizedBox(height: 18),
        IosSectionHeader(text: l10n.studyNotesSection, first: true),
        if (notes == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CupertinoActivityIndicator(radius: 12)),
          )
        else if (notes.isEmpty)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.studyNotesEmpty,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          )
        else
          SectionCard(
            children: [
              for (var i = 0; i < notes.length; i++) ...[
                if (i > 0) const IosRowDivider(indent: 12),
                _StudyNoteRow(
                  note: notes[i],
                  onTap: () {
                    Haptics.light();
                    unawaited(
                      showStudyNoteDetail(
                        context,
                        projectId: project.id,
                        note: notes[i],
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
      ],
    );
  }
}

class _DesktopProjectTitleBar extends StatelessWidget {
  const _DesktopProjectTitleBar({required this.project});

  final StudyProject project;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.read<StudyProjectProvider>();

    return Row(
      children: [
        Expanded(
          child: Text(
            project.title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface,
            ),
          ),
        ),
        Tooltip(
          message: l10n.studyProjectEdit,
          child: IosIconButton(
            icon: Lucide.Pencil,
            size: 18,
            minSize: 36,
            semanticLabel: l10n.studyProjectEdit,
            onTap: () {
              Haptics.light();
              unawaited(showEditStudyProjectDialog(context, project));
            },
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: l10n.studyProjectDelete,
          child: IosIconButton(
            icon: Lucide.Trash2,
            size: 18,
            minSize: 36,
            color: cs.error,
            semanticLabel: l10n.studyProjectDelete,
            onTap: () async {
              Haptics.light();
              final confirmed = await confirmDeleteStudyProject(
                context,
                project,
              );
              if (!confirmed || !context.mounted) return;
              await runStudyAction(
                context,
                () => provider.deleteProject(project.id),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ProjectHeaderSection extends StatelessWidget {
  const _ProjectHeaderSection({required this.project});

  final StudyProject project;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.read<StudyProjectProvider>();
    final goal = project.goal.trim();

    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            goal.isEmpty ? l10n.studyProjectGoalEmpty : goal,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: goal.isEmpty
                  ? cs.onSurface.withValues(alpha: 0.5)
                  : cs.onSurface.withValues(alpha: 0.88),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedTabs(
            tabs: [
              SegmentedTab(label: l10n.studyModeExplain),
              SegmentedTab(label: l10n.studyModeGuidedPractice),
            ],
            index: project.mode == StudyInteractionMode.explain ? 0 : 1,
            onChanged: (index) {
              final nextMode = index == 0
                  ? StudyInteractionMode.explain
                  : StudyInteractionMode.guidedPractice;
              unawaited(
                runStudyAction(
                  context,
                  () => provider.updateProject(project.id, mode: nextMode),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeaderWithAction extends StatelessWidget {
  const _SectionHeaderWithAction({
    required this.title,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.busy = false,
  });

  final String title;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
          IosTileButton(
            icon: actionIcon,
            label: actionLabel,
            enabled: onAction != null && !busy,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            onTap: onAction ?? () {},
          ),
        ],
      ),
    );
  }
}

class _StudyDocumentRow extends StatelessWidget {
  const _StudyDocumentRow({
    required this.document,
    required this.isIndexed,
    required this.isIndexing,
    required this.onRead,
    required this.onMore,
  });

  final StudySourceDocument document;
  final bool isIndexed;
  final bool isIndexing;
  final VoidCallback onRead;
  final ValueChanged<Offset?> onMore;

  StudyBadgeTone _statusTone(StudySourceStatus status) {
    return switch (status) {
      StudySourceStatus.ready => StudyBadgeTone.success,
      StudySourceStatus.scannedNeedsOcr => StudyBadgeTone.warning,
      StudySourceStatus.pendingSourceLink => StudyBadgeTone.warning,
      StudySourceStatus.unreadable => StudyBadgeTone.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return IosCardPress(
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      pressedBlendStrength: 0,
      onTap: onRead,
      onLongPress: () => onMore(null),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Lucide.FileText,
                  size: 20,
                  color: cs.onSurface.withValues(alpha: 0.82),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        document.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.medium,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        document.fileName,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurface.withValues(alpha: 0.58),
                        ),
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (buttonCtx) => Tooltip(
                    message: l10n.studyProjectMoreActions,
                    child: IosIconButton(
                      icon: Lucide.Ellipsis,
                      size: 18,
                      minSize: 36,
                      semanticLabel: l10n.studyProjectMoreActions,
                      onTap: () {
                        Haptics.light();
                        final box = buttonCtx.findRenderObject() as RenderBox?;
                        final anchor = (box != null && box.hasSize)
                            ? box.localToGlobal(box.size.center(Offset.zero))
                            : null;
                        onMore(anchor);
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  StudyBadge(
                    label: studySourceStatusLabel(l10n, document.status),
                    tone: _statusTone(document.status),
                  ),
                  if (document.physicalPageCount != null)
                    StudyBadge(
                      label: l10n.studyDocPhysicalPages(
                        document.physicalPageCount!,
                      ),
                    ),
                  if (document.corpusPageRange != null)
                    StudyBadge(
                      label: l10n.studyDocCorpusPages(
                        document.corpusPageRange!.label,
                      ),
                    ),
                  if (isIndexing)
                    StudyBadge(
                      label: l10n.studyDocIndexing,
                      tone: StudyBadgeTone.primary,
                      leading: const CupertinoActivityIndicator(radius: 5.5),
                    )
                  else
                    StudyBadge(
                      label: isIndexed
                          ? l10n.studyDocIndexed
                          : l10n.studyDocNotIndexed,
                      tone: isIndexed
                          ? StudyBadgeTone.primary
                          : StudyBadgeTone.neutral,
                    ),
                ],
              ),
            ),
            if (document.status == StudySourceStatus.scannedNeedsOcr) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 30, right: 8),
                child: Text(
                  l10n.studyDocScannedHint,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StudyNoteRow extends StatelessWidget {
  const _StudyNoteRow({required this.note, required this.onTap});

  final StudyNote note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final grounded = note.evidenceStatus == StudyEvidenceStatus.grounded;
    final firstLine = note.body
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');

    return IosCardPress(
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      pressedBlendStrength: 0,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    note.title.isEmpty ? l10n.studyNoteDetailTitle : note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Lucide.ChevronRight,
                  size: 16,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ],
            ),
            if (firstLine.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                firstLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.62),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                StudyBadge(
                  label: studyEvidenceStatusLabel(l10n, note.evidenceStatus),
                  tone: grounded
                      ? StudyBadgeTone.success
                      : StudyBadgeTone.warning,
                  icon: grounded ? Lucide.CheckCircle : Lucide.TriangleAlert,
                ),
                StudyBadge(
                  label: l10n.studyNoteAnchorsCount(note.anchors.length),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
