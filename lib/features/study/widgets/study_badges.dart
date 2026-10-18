import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:Kelivo/core/services/study/study_citation_resolver.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/core/services/study/study_prompts.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

String studyModeLabel(AppLocalizations l10n, StudyInteractionMode mode) {
  return switch (mode) {
    StudyInteractionMode.explain => l10n.studyModeExplain,
    StudyInteractionMode.guidedPractice => l10n.studyModeGuidedPractice,
  };
}

String studySourceStatusLabel(AppLocalizations l10n, StudySourceStatus status) {
  return switch (status) {
    StudySourceStatus.ready => l10n.studyDocStatusReady,
    StudySourceStatus.scannedNeedsOcr => l10n.studyDocStatusScannedNeedsOcr,
    StudySourceStatus.unreadable => l10n.studyDocStatusUnreadable,
    StudySourceStatus.pendingSourceLink => l10n.studyDocStatusPendingSourceLink,
  };
}

String studyEvidenceStatusLabel(
  AppLocalizations l10n,
  StudyEvidenceStatus status,
) {
  return switch (status) {
    StudyEvidenceStatus.grounded => l10n.studyNoteEvidenceGrounded,
    StudyEvidenceStatus.insufficientEvidence =>
      l10n.studyNoteEvidenceInsufficient,
  };
}

String studyCitationIssueLabel(
  AppLocalizations l10n,
  StudyCitationIssue issue,
) {
  return switch (issue) {
    StudyCitationIssue.malformed => l10n.studyCitationIssueMalformed,
    StudyCitationIssue.unknownDocument =>
      l10n.studyCitationIssueUnknownDocument,
    StudyCitationIssue.documentNotReady =>
      l10n.studyCitationIssueDocumentNotReady,
    StudyCitationIssue.sourceVersionMismatch =>
      l10n.studyCitationIssueSourceVersionMismatch,
    StudyCitationIssue.missingLocator => l10n.studyCitationIssueMissingLocator,
    StudyCitationIssue.unknownSection => l10n.studyCitationIssueUnknownSection,
    StudyCitationIssue.sectionUnavailable =>
      l10n.studyCitationIssueSectionUnavailable,
    StudyCitationIssue.physicalPageOutOfRange =>
      l10n.studyCitationIssuePhysicalPageOutOfRange,
    StudyCitationIssue.physicalPageOutsideSection =>
      l10n.studyCitationIssuePhysicalPageOutsideSection,
    StudyCitationIssue.corpusPageOutOfRange =>
      l10n.studyCitationIssueCorpusPageOutOfRange,
    StudyCitationIssue.quoteTooShort => l10n.studyCitationIssueQuoteTooShort,
    StudyCitationIssue.quoteNotFound => l10n.studyCitationIssueQuoteNotFound,
  };
}

String formatStudyDate(BuildContext context, DateTime date) {
  final local = date.toLocal();
  final locale = Localizations.localeOf(context).toLanguageTag();
  final now = DateTime.now();
  if (now.year == local.year) {
    return DateFormat.MMMd(locale).format(local);
  }
  return DateFormat.yMMMd(locale).format(local);
}

enum StudyBadgeTone { neutral, primary, success, warning, error }

class StudyBadge extends StatelessWidget {
  const StudyBadge({
    super.key,
    required this.label,
    this.tone = StudyBadgeTone.neutral,
    this.icon,
    this.leading,
  });

  final String label;
  final StudyBadgeTone tone;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    final (Color fg, Color bg) = switch (tone) {
      StudyBadgeTone.neutral => (
        cs.onSurface.withValues(alpha: 0.72),
        appColors.surfaceFill,
      ),
      StudyBadgeTone.primary => (
        cs.primary,
        cs.primary.withValues(alpha: 0.12),
      ),
      StudyBadgeTone.success => (
        appColors.success,
        appColors.success.withValues(alpha: 0.12),
      ),
      StudyBadgeTone.warning => (
        appColors.warning,
        appColors.warning.withValues(alpha: 0.14),
      ),
      StudyBadgeTone.error => (cs.error, cs.error.withValues(alpha: 0.12)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 4),
          ] else if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: AppFontWeights.medium,
                color: fg,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
