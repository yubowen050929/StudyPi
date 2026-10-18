import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/study/study_citation_resolver.dart';
import '../../../core/services/study/study_project_store.dart';
import '../../../features/settings/widgets/custom_theme_widgets.dart';
import '../../../features/workspace/workspace_layout.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/custom_bottom_sheet.dart';
import '../../../shared/widgets/form_sheet.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../pages/study_source_reader_page.dart';
import '../providers/study_project_provider.dart';
import 'study_badges.dart';

export 'study_badges.dart' show studyCitationIssueLabel;

/// Shows the details of a study citation tapped in a chat reply: whether it
/// was verified, where it points, and actions to read the source or save it
/// as a note. Bottom sheet on mobile, dialog on desktop.
Future<void> showStudyCitationDetails(
  BuildContext context, {
  required String projectId,
  required StudyResolvedCitation? resolved,
  String? conversationId,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (useDesktopWorkspaceLayout(context)) {
    await showAppDialog<void>(
      context,
      maxWidth: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDialogHeader(title: l10n.studyCitationSheetTitle),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: _StudyCitationDetailsBody(
                projectId: projectId,
                resolved: resolved,
                conversationId: conversationId,
              ),
            ),
          ),
        ],
      ),
    );
    return;
  }

  await showCustomBottomSheet<void>(
    context: context,
    title: l10n.studyCitationSheetTitle,
    partialHeightFactor: 0.60,
    expandedHeightFactor: 0.88,
    builder: (sheetCtx, scrollController) => SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: _StudyCitationDetailsBody(
        projectId: projectId,
        resolved: resolved,
        conversationId: conversationId,
      ),
    ),
  );
}

class _StudyCitationDetailsBody extends StatelessWidget {
  const _StudyCitationDetailsBody({
    required this.projectId,
    required this.resolved,
    required this.conversationId,
  });

  final String projectId;
  final StudyResolvedCitation? resolved;
  final String? conversationId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    final current = resolved;

    if (current == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            l10n.studyCitationUnavailable,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ),
      );
    }

    final citation = current.citation;
    final grounded = current.isGroundedEvidence;
    final verifiedNoQuote = current.verified && !grounded;
    final (
      IconData statusIcon,
      Color statusColor,
      String statusLabel,
    ) = grounded
        ? (
            Lucide.CheckCircle,
            appColors.success,
            l10n.studyCitationStatusGrounded,
          )
        : verifiedNoQuote
        ? (
            Lucide.BadgeInfo,
            appColors.warning,
            l10n.studyCitationStatusLocatedNoQuote,
          )
        : (Lucide.XCircle, cs.error, l10n.studyCitationStatusUnverified);

    final materialTitle =
        current.document?.title ??
        (citation.documentId.isEmpty ? '—' : citation.documentId);
    final sectionTitle = current.section?.title ?? citation.sectionId;
    final quote = citation.quote?.trim() ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(statusIcon, size: 18, color: statusColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: AppFontWeights.semibold,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              if (current.issues.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final issue in current.issues)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '• ',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface.withValues(alpha: 0.8),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            studyCitationIssueLabel(l10n, issue),
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              color: cs.onSurface.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailRow(
                label: l10n.studyCitationMaterialLabel,
                value: materialTitle,
              ),
              if (sectionTitle != null && sectionTitle.isNotEmpty) ...[
                const SizedBox(height: 8),
                _DetailRow(
                  label: l10n.studyCitationSectionLabel,
                  value: sectionTitle,
                ),
              ],
              if (citation.physicalPage != null ||
                  citation.corpusPage != null) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (citation.physicalPage != null)
                      StudyBadge(
                        label: l10n.studyCitationPdfPage(
                          citation.physicalPage!,
                        ),
                      ),
                    if (citation.corpusPage != null)
                      StudyBadge(
                        label: l10n.studyCitationBookPage(citation.corpusPage!),
                      ),
                  ],
                ),
              ],
              if (quote.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: appColors.surfaceFill,
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
                      fontSize: 13.5,
                      height: 1.45,
                      color: cs.onSurface.withValues(alpha: 0.88),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            if (current.document != null) ...[
              Expanded(
                child: IosTileButton(
                  icon: Lucide.BookOpen,
                  label: l10n.studyNoteViewSource,
                  onTap: () {
                    unawaited(
                      openStudySourceReader(
                        context,
                        projectId: projectId,
                        documentId: current.document!.id,
                        initialSectionId:
                            current.section?.sectionId ?? citation.sectionId,
                        highlightQuote: quote.isEmpty ? null : quote,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: IosTileButton(
                icon: Lucide.Bookmark,
                label: l10n.studyCitationSaveAsNote,
                backgroundColor: cs.primary,
                foregroundColor: cs.primary,
                onTap: () => unawaited(
                  _promptSaveCitationAsNote(
                    context,
                    projectId: projectId,
                    resolved: current,
                    conversationId: conversationId,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurface.withValues(alpha: 0.58),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> _promptSaveCitationAsNote(
  BuildContext context, {
  required String projectId,
  required StudyResolvedCitation resolved,
  required String? conversationId,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final provider = context.read<StudyProjectProvider>();
  final defaultTitle =
      resolved.section?.title ??
      resolved.document?.title ??
      resolved.citation.documentId;

  final desktop = useDesktopWorkspaceLayout(context);
  final draft = await (desktop
      ? showAppDialog<({String title, String body})>(
          context,
          maxWidth: 480,
          child: _SaveNoteForm(initialTitle: defaultTitle, desktop: true),
        )
      : showFormSheet<({String title, String body})>(
          context,
          builder: (_) =>
              _SaveNoteForm(initialTitle: defaultTitle, desktop: false),
        ));

  if (draft == null || !context.mounted) return;
  final StudyNote note;
  try {
    note = await provider.saveNote(
      projectId,
      title: draft.title,
      body: draft.body,
      anchors: [resolved.toAnchor()],
      conversationId: conversationId,
    );
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
    }
    return;
  }
  if (!context.mounted) return;
  final grounded = note.evidenceStatus == StudyEvidenceStatus.grounded;
  showAppSnackBar(
    context,
    message: grounded
        ? l10n.studyCitationNoteSavedGrounded
        : l10n.studyCitationNoteSavedInsufficient,
    type: grounded ? NotificationType.success : NotificationType.warning,
  );
}

class _SaveNoteForm extends StatefulWidget {
  const _SaveNoteForm({required this.initialTitle, required this.desktop});

  final String initialTitle;
  final bool desktop;

  @override
  State<_SaveNoteForm> createState() => _SaveNoteFormState();
}

class _SaveNoteFormState extends State<_SaveNoteForm> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.initialTitle,
  );
  final TextEditingController _bodyController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Navigator.of(
      context,
    ).pop((title: title, body: _bodyController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final canSave = _titleController.text.trim().isNotEmpty;

    final fields = SectionCard(
      children: [
        IosFormTextField(
          label: l10n.studyCitationNoteTitleLabel,
          controller: _titleController,
          inlineLabel: false,
          onChanged: (_) => setState(() {}),
        ),
        IosFormTextField(
          label: l10n.studyCitationNoteBodyLabel,
          controller: _bodyController,
          hintText: l10n.studyCitationNoteBodyHint,
          inlineLabel: false,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
        ),
      ],
    );

    final actions = FormSheetActions(
      cancelLabel: l10n.studyProjectCancel,
      confirmLabel: l10n.studyProjectSave,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: canSave ? _submit : null,
    );

    if (widget.desktop) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDialogHeader(title: l10n.studyCitationSaveNoteTitle),
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

    return FormSheet(
      title: l10n.studyCitationSaveNoteTitle,
      actions: actions,
      children: [fields],
    );
  }
}
