import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/services/haptics.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/features/study/pages/study_project_page.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/features/study/widgets/study_badges.dart';
import 'package:Kelivo/features/study/widgets/study_project_dialogs.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_settings_rows.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/shared/widgets/section_card.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

class StudyProjectsMobileLayout extends StatelessWidget {
  const StudyProjectsMobileLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<StudyProjectProvider>();
    final projects = provider.projects;

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
        title: Text(l10n.studyProjectsTitle),
        actions: [
          Tooltip(
            message: l10n.studyProjectCreate,
            child: IosIconButton(
              key: const ValueKey<String>('study-projects-create-action'),
              icon: Lucide.Plus,
              color: cs.onSurface,
              size: 22,
              minSize: 44,
              semanticLabel: l10n.studyProjectCreate,
              onTap: () {
                Haptics.light();
                unawaited(showCreateStudyProjectDialog(context));
              },
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: projects.isEmpty
          ? _StudyProjectsEmptyState(
              onCreate: () => unawaited(showCreateStudyProjectDialog(context)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                SectionCard(
                  children: [
                    for (var i = 0; i < projects.length; i++) ...[
                      if (i > 0) const IosRowDivider(),
                      _StudyProjectListTile(
                        project: projects[i],
                        materialCount: provider
                            .documentsOf(projects[i].id)
                            ?.length,
                        onTap: () {
                          Haptics.light();
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  StudyProjectPage(projectId: projects[i].id),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
  }
}

class _StudyProjectsEmptyState extends StatelessWidget {
  const _StudyProjectsEmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Lucide.BookOpen,
                size: 44,
                color: cs.onSurface.withValues(alpha: 0.26),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.studyProjectsEmptyTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface.withValues(alpha: 0.78),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.studyProjectsEmptyDescription,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.56),
                ),
              ),
              const SizedBox(height: 18),
              IosTileButton(
                key: const ValueKey<String>('study-projects-empty-create'),
                icon: Lucide.Plus,
                label: l10n.studyProjectCreate,
                onTap: onCreate,
              ),
            ],
          ),
        ),
      ),
    ).animate().fadeIn(duration: 200.ms);
  }
}

class _StudyProjectListTile extends StatelessWidget {
  const _StudyProjectListTile({
    required this.project,
    required this.materialCount,
    required this.onTap,
  });

  final StudyProject project;
  final int? materialCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final goal = project.goal.trim();
    final updated = l10n.studyProjectUpdatedAt(
      formatStudyDate(context, project.updatedAt),
    );
    final caption = materialCount != null
        ? '${l10n.studyProjectMaterialCount(materialCount!)} · $updated'
        : updated;

    return IosNavRow(
      key: ValueKey<String>('study-project-item-${project.id}'),
      icon: Lucide.BookOpen,
      label: project.title,
      labelWeight: AppFontWeights.medium,
      subtitle: goal.isEmpty ? null : goal,
      subtitleMaxLines: 1,
      caption: caption,
      onTap: onTap,
    );
  }
}
