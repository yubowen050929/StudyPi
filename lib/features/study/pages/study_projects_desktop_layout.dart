import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/services/haptics.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/features/study/pages/study_project_page.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/features/study/widgets/study_badges.dart';
import 'package:Kelivo/features/study/widgets/study_project_dialogs.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

class StudyProjectsDesktopLayout extends StatefulWidget {
  const StudyProjectsDesktopLayout({super.key});

  @override
  State<StudyProjectsDesktopLayout> createState() =>
      _StudyProjectsDesktopLayoutState();
}

class _StudyProjectsDesktopLayoutState
    extends State<StudyProjectsDesktopLayout> {
  String? _selectedId;

  Future<void> _createProject() async {
    final created = await showCreateStudyProjectDialog(context);
    if (!mounted || created == null) return;
    setState(() => _selectedId = created.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<StudyProjectProvider>();
    final projects = provider.projects;

    final selected =
        projects.where((p) => p.id == _selectedId).firstOrNull ??
        projects.firstOrNull;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.studyProjectsTitle,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: l10n.studyProjectCreate,
                        child: IosIconButton(
                          key: const ValueKey<String>(
                            'study-projects-desktop-create',
                          ),
                          icon: Lucide.Plus,
                          size: 20,
                          minSize: 36,
                          semanticLabel: l10n.studyProjectCreate,
                          onTap: () {
                            Haptics.light();
                            unawaited(_createProject());
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 0.6,
                  color: cs.outlineVariant.withValues(alpha: 0.16),
                ),
                Expanded(
                  child: projects.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l10n.studyProjectsEmptyTitle,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13.5,
                                color: cs.onSurface.withValues(alpha: 0.55),
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(10),
                          itemCount: projects.length,
                          itemBuilder: (context, index) {
                            final project = projects[index];
                            final isSelected = project.id == selected?.id;
                            final docCount = provider
                                .documentsOf(project.id)
                                ?.length;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _DesktopProjectRow(
                                project: project,
                                materialCount: docCount,
                                selected: isSelected,
                                onTap: () {
                                  Haptics.light();
                                  setState(() => _selectedId = project.id);
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 0.6,
            color: cs.outlineVariant.withValues(alpha: 0.16),
          ),
          Expanded(
            child: selected == null
                ? _DesktopEmptyPane(
                    onCreate: () {
                      Haptics.light();
                      unawaited(_createProject());
                    },
                  )
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 840),
                      child: StudyProjectPane(
                        key: ValueKey<String>(selected.id),
                        projectId: selected.id,
                        showDesktopHeader: true,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DesktopProjectRow extends StatelessWidget {
  const _DesktopProjectRow({
    required this.project,
    required this.materialCount,
    required this.selected,
    required this.onTap,
  });

  final StudyProject project;
  final int? materialCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final goal = project.goal.trim();
    final updated = l10n.studyProjectUpdatedAt(
      formatStudyDate(context, project.updatedAt),
    );
    final meta = materialCount != null
        ? '${l10n.studyProjectMaterialCount(materialCount!)} · $updated'
        : updated;

    return IosCardPress(
      baseColor: selected
          ? cs.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            Lucide.BookOpen,
            size: 18,
            color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.72),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected
                        ? AppFontWeights.semibold
                        : AppFontWeights.medium,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
                if (goal.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    goal,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopEmptyPane extends StatelessWidget {
  const _DesktopEmptyPane({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Lucide.BookOpen,
                size: 44,
                color: cs.onSurface.withValues(alpha: 0.28),
              ),
              const SizedBox(height: 14),
              Text(
                l10n.studyProjectsEmptyTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.studyProjectsEmptyDescription,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 18),
              IosTileButton(
                icon: Lucide.Plus,
                label: l10n.studyProjectCreate,
                onTap: onCreate,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
