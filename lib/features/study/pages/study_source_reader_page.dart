import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/services/haptics.dart';
import 'package:Kelivo/core/services/study/study_mineru_indexer.dart';
import 'package:Kelivo/core/services/study/study_project_store.dart';
import 'package:Kelivo/features/settings/widgets/custom_theme_widgets.dart';
import 'package:Kelivo/features/study/providers/study_project_provider.dart';
import 'package:Kelivo/features/study/widgets/study_badges.dart';
import 'package:Kelivo/features/workspace/workspace_layout.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/custom_bottom_sheet.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/shared/widgets/markdown_with_highlight.dart';
import 'package:Kelivo/shared/widgets/section_card.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:Kelivo/theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

Future<void> openStudySourceReader(
  BuildContext context, {
  required String projectId,
  required String documentId,
  String? initialSectionId,
  String? highlightQuote,
}) {
  if (useDesktopWorkspaceLayout(context)) {
    final height = MediaQuery.sizeOf(context).height * 0.85;
    return showAppDialog<void>(
      context,
      maxWidth: 900,
      child: SizedBox(
        height: height,
        child: StudySourceReaderPage(
          projectId: projectId,
          documentId: documentId,
          initialSectionId: initialSectionId,
          highlightQuote: highlightQuote,
          dialog: true,
        ),
      ),
    );
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => StudySourceReaderPage(
        projectId: projectId,
        documentId: documentId,
        initialSectionId: initialSectionId,
        highlightQuote: highlightQuote,
      ),
    ),
  );
}

class StudySourceReaderPage extends StatefulWidget {
  const StudySourceReaderPage({
    super.key,
    required this.projectId,
    required this.documentId,
    this.initialSectionId,
    this.highlightQuote,
    this.dialog = false,
  });

  final String projectId;
  final String documentId;
  final String? initialSectionId;
  final String? highlightQuote;
  final bool dialog;

  @override
  State<StudySourceReaderPage> createState() => _StudySourceReaderPageState();
}

class _StudySourceReaderPageState extends State<StudySourceReaderPage> {
  ({StudyDocumentIndex index, List<String> lines})? _loadedIndex;
  bool _loading = true;
  bool _buildingIndex = false;
  int _selectedSectionIndex = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant StudySourceReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId ||
        oldWidget.documentId != widget.documentId ||
        oldWidget.initialSectionId != widget.initialSectionId) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final provider = context.read<StudyProjectProvider>();
    ({StudyDocumentIndex index, List<String> lines})? result;
    try {
      if (provider.documentsOf(widget.projectId) == null) {
        await provider.ensureProjectLoaded(widget.projectId);
      }
      result = await provider.currentIndex(widget.projectId, widget.documentId);
    } catch (e) {
      // Falls through to the unindexed view, which offers to build the index.
      debugPrint('Study reader could not load the index: $e');
      result = null;
    }
    if (!mounted) return;
    var sectionIdx = 0;
    if (result != null && widget.initialSectionId != null) {
      final found = result.index.sections.indexWhere(
        (s) => s.sectionId == widget.initialSectionId,
      );
      if (found >= 0) sectionIdx = found;
    }
    setState(() {
      _loadedIndex = result;
      _selectedSectionIndex = sectionIdx;
      _loading = false;
    });
  }

  Future<void> _buildIndex() async {
    if (_buildingIndex) return;
    setState(() => _buildingIndex = true);
    final provider = context.read<StudyProjectProvider>();
    final l10n = AppLocalizations.of(context)!;
    try {
      await provider.buildIndex(widget.projectId, widget.documentId);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.studyDocIndexFailed(e.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _buildingIndex = false);
    }
  }

  Future<void> _openOriginal(StudySourceDocument doc) async {
    final path = doc.originalPath;
    if (path == null || path.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      final res = await OpenFilex.open(path);
      if (!mounted) return;
      if (res.type != ResultType.done && res.message.isNotEmpty) {
        showAppSnackBar(
          context,
          message: l10n.studyReaderOpenOriginalFailed(res.message),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.studyReaderOpenOriginalFailed(e.toString()),
        type: NotificationType.error,
      );
    }
  }

  Future<void> _showMobileSectionPicker(StudyDocumentIndex index) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCustomBottomSheet<int>(
      context: context,
      title: l10n.studyReaderSections,
      count: index.sections.length,
      partialHeightFactor: 0.65,
      expandedHeightFactor: 0.90,
      builder: (sheetCtx, scrollController) {
        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: index.sections.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (ctx, i) {
            final section = index.sections[i];
            final selected = i == _selectedSectionIndex;
            return _SectionTile(
              section: section,
              selected: selected,
              onTap: () => Navigator.of(sheetCtx).pop(i),
            );
          },
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _selectedSectionIndex = picked);
    }
  }

  StudySourceDocument? _findDocument(StudyProjectProvider provider) {
    final docs = provider.documentsOf(widget.projectId);
    if (docs == null) return null;
    for (final doc in docs) {
      if (doc.id == widget.documentId) return doc;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<StudyProjectProvider>();
    final doc = _findDocument(provider);
    final title = doc?.title ?? _loadedIndex?.index.title ?? widget.documentId;
    final canOpenOriginal =
        doc?.originalPath != null && doc!.originalPath!.trim().isNotEmpty;

    final openOriginalButton = canOpenOriginal
        ? Tooltip(
            message: l10n.studyReaderOpenOriginal,
            child: IosIconButton(
              icon: Lucide.ExternalLink,
              size: widget.dialog ? 18 : 20,
              minSize: widget.dialog ? 32 : 44,
              color: cs.onSurface,
              semanticLabel: l10n.studyReaderOpenOriginal,
              onTap: () {
                Haptics.light();
                unawaited(_openOriginal(doc));
              },
            ),
          )
        : null;

    final body = _loading
        ? const Center(child: CupertinoActivityIndicator(radius: 14))
        : _loadedIndex != null && _loadedIndex!.index.sections.isNotEmpty
        ? _buildIndexedBody(context, _loadedIndex!.index, _loadedIndex!.lines)
        : _buildUnindexedBody(context, doc, provider);

    if (widget.dialog) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDialogHeader(
            title: title,
            actions: [if (openOriginalButton != null) openOriginalButton],
          ),
          Divider(
            height: 1,
            thickness: 0.6,
            color: cs.outlineVariant.withValues(alpha: 0.18),
          ),
          Expanded(child: body),
        ],
      );
    }

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
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (openOriginalButton != null) ...[
            openOriginalButton,
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: body,
    );
  }

  Widget _buildIndexedBody(
    BuildContext context,
    StudyDocumentIndex index,
    List<String> lines,
  ) {
    final sections = index.sections;
    final safeIdx = _selectedSectionIndex.clamp(0, sections.length - 1);
    final section = sections[safeIdx];
    final start = (section.startLine - 1).clamp(0, lines.length);
    final end = section.endLine.clamp(start, lines.length);
    final sectionText = lines.sublist(start, end).join('\n');

    return LayoutBuilder(
      builder: (context, constraints) {
        // Desktop always uses panes: bottom sheets are mobile-only.
        final wide = useDesktopWorkspaceLayout(context);
        if (wide) {
          final cs = Theme.of(context).colorScheme;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 280,
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: sections.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (ctx, i) {
                    return _SectionTile(
                      section: sections[i],
                      selected: i == safeIdx,
                      onTap: () {
                        Haptics.light();
                        setState(() => _selectedSectionIndex = i);
                      },
                    );
                  },
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 0.6,
                color: cs.outlineVariant.withValues(alpha: 0.18),
              ),
              Expanded(
                child: _buildSectionContentPane(
                  context,
                  index: index,
                  section: section,
                  sectionIndex: safeIdx,
                  sectionText: sectionText,
                  showMobilePickerButton: false,
                ),
              ),
            ],
          );
        }

        return _buildSectionContentPane(
          context,
          index: index,
          section: section,
          sectionIndex: safeIdx,
          sectionText: sectionText,
          showMobilePickerButton: true,
        );
      },
    );
  }

  Widget _buildSectionContentPane(
    BuildContext context, {
    required StudyDocumentIndex index,
    required StudyIndexedSection section,
    required int sectionIndex,
    required String sectionText,
    required bool showMobilePickerButton,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final sections = index.sections;
    final hasPrev = sectionIndex > 0;
    final hasNext = sectionIndex + 1 < sections.length;
    final quote = widget.highlightQuote?.trim() ?? '';
    final pdfLabel = _sectionPdfPagesLabel(l10n, section);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(
            children: [
              if (showMobilePickerButton) ...[
                Expanded(
                  child: IosCardPress(
                    borderRadius: BorderRadius.circular(10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    onTap: () {
                      Haptics.light();
                      unawaited(_showMobileSectionPicker(index));
                    },
                    child: Row(
                      children: [
                        Icon(Lucide.ListTree, size: 16, color: cs.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            section.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: AppFontWeights.semibold,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Lucide.ChevronDown,
                          size: 16,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ] else ...[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        section.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface,
                        ),
                      ),
                      if (pdfLabel != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          pdfLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              Tooltip(
                message: l10n.studyReaderPrevSection,
                child: IosIconButton(
                  icon: Lucide.ChevronLeft,
                  size: 18,
                  minSize: 36,
                  enabled: hasPrev,
                  semanticLabel: l10n.studyReaderPrevSection,
                  onTap: hasPrev
                      ? () {
                          Haptics.light();
                          setState(
                            () => _selectedSectionIndex = sectionIndex - 1,
                          );
                        }
                      : null,
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: l10n.studyReaderNextSection,
                child: IosIconButton(
                  icon: Lucide.ChevronRight,
                  size: 18,
                  minSize: 36,
                  enabled: hasNext,
                  semanticLabel: l10n.studyReaderNextSection,
                  onTap: hasNext
                      ? () {
                          Haptics.light();
                          setState(
                            () => _selectedSectionIndex = sectionIndex + 1,
                          );
                        }
                      : null,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            key: ValueKey<String>('reader-sec-${section.sectionId}'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              if (quote.isNotEmpty) ...[
                _HighlightQuoteCallout(quote: quote),
                const SizedBox(height: 12),
              ],
              SectionCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: MarkdownWithCodeHighlight(
                  text: sectionText,
                  useBlockRendering: true,
                  baseStyle: const TextStyle(fontSize: 15, height: 1.55),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUnindexedBody(
    BuildContext context,
    StudySourceDocument? doc,
    StudyProjectProvider provider,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final quote = widget.highlightQuote?.trim() ?? '';
    final rawText = doc?.extractedText?.trim() ?? '';
    final paragraphs = rawText.isEmpty
        ? const <String>[]
        : rawText
              .split(RegExp(r'\n\s*\n'))
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList(growable: false);
    final canBuildIndex =
        doc != null &&
        doc.status == StudySourceStatus.ready &&
        (doc.parsedMarkdownPath != null || doc.format != StudySourceFormat.pdf);
    final isIndexing = _buildingIndex || provider.isIndexing(widget.documentId);

    final headerItems = <Widget>[
      if (quote.isNotEmpty) ...[
        _HighlightQuoteCallout(quote: quote),
        const SizedBox(height: 12),
      ],
      SectionCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Lucide.ListTree, size: 18, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isIndexing
                    ? l10n.studyDocIndexing
                    : l10n.studyReaderNoIndexNotice,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.medium,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (isIndexing)
              const CupertinoActivityIndicator(radius: 9)
            else if (canBuildIndex)
              IosTileButton(
                icon: Lucide.Sparkles,
                label: l10n.studyReaderBuildIndex,
                onTap: () => unawaited(_buildIndex()),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ];

    if (paragraphs.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          ...headerItems,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text(
                l10n.studyReaderEmptyText,
                style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: paragraphs.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: headerItems,
          );
        }
        final paragraph = paragraphs[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SelectableText(
            paragraph,
            style: TextStyle(
              fontSize: 15,
              height: 1.55,
              color: cs.onSurface.withValues(alpha: 0.92),
            ),
          ),
        );
      },
    );
  }
}

String? _sectionPdfPagesLabel(
  AppLocalizations l10n,
  StudyIndexedSection section,
) {
  final range = section.physicalPageRange;
  if (range == null) return null;
  if (range.start == range.end) {
    return l10n.studyReaderSectionSinglePdfPage(range.start);
  }
  return l10n.studyReaderSectionPdfPages('${range.start}–${range.end}');
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final StudyIndexedSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final pdfLabel = _sectionPdfPagesLabel(l10n, section);
    final summary = section.summary.trim();

    return IosCardPress(
      baseColor: selected
          ? cs.primary.withValues(alpha: 0.12)
          : context.appColors.surfaceCard,
      borderRadius: BorderRadius.circular(10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  section.title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: selected
                        ? AppFontWeights.semibold
                        : AppFontWeights.medium,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ),
              if (pdfLabel != null) ...[
                const SizedBox(width: 6),
                StudyBadge(
                  label: pdfLabel,
                  tone: selected
                      ? StudyBadgeTone.primary
                      : StudyBadgeTone.neutral,
                ),
              ],
            ],
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.62),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HighlightQuoteCallout extends StatelessWidget {
  const _HighlightQuoteCallout({required this.quote});

  final String quote;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.35),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Lucide.Bookmark, size: 15, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                l10n.studyReaderHighlightedQuote,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            quote,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.45,
              color: cs.onSurface.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}
