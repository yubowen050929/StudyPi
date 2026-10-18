import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/core/services/study/study_prompts.dart';
import 'package:Kelivo/features/settings/widgets/custom_theme_widgets.dart';
import 'package:Kelivo/features/study/pages/study_source_reader_page.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/features/study/widgets/study_action.dart';
import 'package:Kelivo/features/study/widgets/study_badges.dart';
import 'package:Kelivo/features/workspace/widgets/files/workspace_prompts.dart';
import 'package:Kelivo/features/workspace/workspace_layout.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/custom_bottom_sheet.dart';
import 'package:Kelivo/shared/widgets/form_sheet.dart';
import 'package:Kelivo/shared/widgets/ios_form_text_field.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/shared/widgets/section_card.dart';
import 'package:Kelivo/shared/widgets/segmented_tabs.dart';
import 'package:Kelivo/theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

class StudyProjectDraft {
  const StudyProjectDraft({
    required this.title,
    required this.goal,
    required this.mode,
  });

  final String title;
  final String goal;
  final StudyInteractionMode mode;
}

Future<StudyProject?> showCreateStudyProjectDialog(BuildContext context) async {
  final provider = context.read<StudyProjectProvider>();
  final draft = await _showProjectForm(context);
  if (draft == null || !context.mounted) return null;
  return runStudyAction(
    context,
    () => provider.createProject(
      title: draft.title,
      goal: draft.goal,
      mode: draft.mode,
    ),
  );
}

Future<StudyProject?> showEditStudyProjectDialog(
  BuildContext context,
  StudyProject project,
) async {
  final provider = context.read<StudyProjectProvider>();
  final draft = await _showProjectForm(context, initial: project);
  if (draft == null || !context.mounted) return null;
  return runStudyAction(
    context,
    () => provider.updateProject(
      project.id,
      title: draft.title,
      goal: draft.goal,
      mode: draft.mode,
    ),
  );
}

Future<StudyProjectDraft?> _showProjectForm(
  BuildContext context, {
  StudyProject? initial,
}) {
  final desktop = useDesktopWorkspaceLayout(context);
  if (desktop) {
    return showAppDialog<StudyProjectDraft>(
      context,
      maxWidth: 480,
      child: _StudyProjectForm(initial: initial, desktop: true),
    );
  }
  return showFormSheet<StudyProjectDraft>(
    context,
    builder: (_) => _StudyProjectForm(initial: initial, desktop: false),
  );
}

class _StudyProjectForm extends StatefulWidget {
  const _StudyProjectForm({required this.initial, required this.desktop});

  final StudyProject? initial;
  final bool desktop;

  @override
  State<_StudyProjectForm> createState() => _StudyProjectFormState();
}

class _StudyProjectFormState extends State<_StudyProjectForm> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.initial?.title ?? '',
  );
  late final TextEditingController _goalController = TextEditingController(
    text: widget.initial?.goal ?? '',
  );
  late StudyInteractionMode _mode =
      widget.initial?.mode ?? StudyInteractionMode.explain;

  @override
  void dispose() {
    _titleController.dispose();
    _goalController.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(
      StudyProjectDraft(
        title: title,
        goal: _goalController.text.trim(),
        mode: _mode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isEdit = widget.initial != null;
    final dialogTitle = isEdit
        ? l10n.studyProjectEdit
        : l10n.studyProjectCreate;
    final canSave = _titleController.text.trim().isNotEmpty;

    final fields = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionCard(
          children: [
            IosFormTextField(
              key: const ValueKey<String>('study-project-title-field'),
              label: l10n.studyProjectTitleLabel,
              controller: _titleController,
              hintText: l10n.studyProjectTitleHint,
              inlineLabel: false,
              autofocus: true,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
            ),
            IosFormTextField(
              key: const ValueKey<String>('study-project-goal-field'),
              label: l10n.studyProjectGoalLabel,
              controller: _goalController,
              hintText: l10n.studyProjectGoalHint,
              inlineLabel: false,
              minLines: 2,
              maxLines: 4,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.studyProjectModeLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedTabs(
                    tabs: [
                      SegmentedTab(label: l10n.studyModeExplain),
                      SegmentedTab(label: l10n.studyModeGuidedPractice),
                    ],
                    index: _mode == StudyInteractionMode.explain ? 0 : 1,
                    onChanged: (index) {
                      setState(() {
                        _mode = index == 0
                            ? StudyInteractionMode.explain
                            : StudyInteractionMode.guidedPractice;
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );

    final actions = FormSheetActions(
      key: const ValueKey<String>('study-project-save-button'),
      cancelLabel: l10n.studyProjectCancel,
      confirmLabel: isEdit ? l10n.studyProjectSave : l10n.studyProjectCreate,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: canSave ? _submit : null,
    );

    if (widget.desktop) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDialogHeader(title: dialogTitle),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: fields,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: actions,
          ),
        ],
      );
    }

    return FormSheet(title: dialogTitle, actions: actions, children: [fields]);
  }
}

Future<bool> confirmDeleteStudyProject(
  BuildContext context,
  StudyProject project,
) {
  final l10n = AppLocalizations.of(context)!;
  return showWorkspaceConfirm(
    context: context,
    title: l10n.studyProjectDelete,
    message: l10n.studyProjectDeleteMessage(project.title),
    confirmLabel: l10n.studyProjectConfirmDelete,
    destructive: true,
  );
}

Future<void> showStudyNoteDetail(
  BuildContext context, {
  required String projectId,
  required StudyNote note,
}) {
  final l10n = AppLocalizations.of(context)!;
  if (useDesktopWorkspaceLayout(context)) {
    return showAppDialog<void>(
      context,
      maxWidth: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDialogHeader(title: l10n.studyNoteDetailTitle),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: _StudyNoteDetailBody(projectId: projectId, note: note),
            ),
          ),
        ],
      ),
    );
  }
  return showCustomBottomSheet<void>(
    context: context,
    title: l10n.studyNoteDetailTitle,
    partialHeightFactor: 0.65,
    expandedHeightFactor: 0.90,
    builder: (sheetCtx, scrollController) => SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: _StudyNoteDetailBody(projectId: projectId, note: note),
    ),
  );
}

class _StudyNoteDetailBody extends StatelessWidget {
  const _StudyNoteDetailBody({required this.projectId, required this.note});

  final String projectId;
  final StudyNote note;

  Future<void> _deleteNote(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<StudyProjectProvider>();
    final confirmed = await showWorkspaceConfirm(
      context: context,
      title: l10n.studyNoteDeleteTitle,
      message: l10n.studyNoteDeleteMessage(note.title),
      confirmLabel: l10n.studyProjectConfirmDelete,
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await runStudyAction(
      context,
      () => provider.deleteNote(projectId, note.id),
    );
    if (context.mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<StudyProjectProvider>();
    final docs =
        provider.documentsOf(projectId) ?? const <StudySourceDocument>[];
    final docById = {for (final doc in docs) doc.id: doc};
    final grounded = note.evidenceStatus == StudyEvidenceStatus.grounded;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                note.title.isEmpty ? l10n.studyNoteDetailTitle : note.title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 8),
            StudyBadge(
              label: studyEvidenceStatusLabel(l10n, note.evidenceStatus),
              tone: grounded ? StudyBadgeTone.success : StudyBadgeTone.warning,
              icon: grounded ? Lucide.CheckCircle : Lucide.TriangleAlert,
            ),
          ],
        ),
        if (note.body.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              note.body,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: cs.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          l10n.studyNoteAnchorsHeading,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.78),
          ),
        ),
        const SizedBox(height: 8),
        if (note.anchors.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.studyNoteNoAnchors,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.58),
              ),
            ),
          )
        else
          for (var i = 0; i < note.anchors.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _NoteAnchorCard(
              projectId: projectId,
              anchor: note.anchors[i],
              document: docById[note.anchors[i].documentId],
            ),
          ],
        const SizedBox(height: 16),
        IosTileButton(
          icon: Lucide.Trash2,
          label: l10n.studyDocActionDelete,
          backgroundColor: cs.error,
          foregroundColor: cs.error,
          onTap: () => unawaited(_deleteNote(context)),
        ),
      ],
    );
  }
}

class _NoteAnchorCard extends StatelessWidget {
  const _NoteAnchorCard({
    required this.projectId,
    required this.anchor,
    required this.document,
  });

  final String projectId;
  final StudySourceAnchor anchor;
  final StudySourceDocument? document;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final docTitle = document?.title ?? anchor.documentId;
    final quote = anchor.quote?.trim() ?? '';

    return SectionCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Lucide.FileText,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  docTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (anchor.sectionId != null && anchor.sectionId!.isNotEmpty)
                StudyBadge(
                  label: anchor.sectionId!,
                  tone: StudyBadgeTone.primary,
                ),
              if (anchor.physicalPage != null)
                StudyBadge(
                  label: l10n.studyCitationPdfPage(anchor.physicalPage!),
                ),
              if (anchor.corpusPage != null)
                StudyBadge(
                  label: l10n.studyCitationBookPage(anchor.corpusPage!),
                ),
            ],
          ),
          if (quote.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: context.appColors.surfaceFill,
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(
                    color: cs.primary.withValues(alpha: 0.6),
                    width: 3,
                  ),
                ),
              ),
              child: SelectableText(
                quote,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
          if (document != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: IosTileButton(
                icon: Lucide.BookOpen,
                label: l10n.studyNoteViewSource,
                onTap: () {
                  unawaited(
                    openStudySourceReader(
                      context,
                      projectId: projectId,
                      documentId: anchor.documentId,
                      initialSectionId: anchor.sectionId,
                      highlightQuote: quote.isEmpty ? null : quote,
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
