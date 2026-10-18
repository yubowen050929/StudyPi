import 'study_citation_syntax.dart';
import 'study_mineru_indexer.dart';
import 'study_project_store.dart';

export 'study_citation_syntax.dart';

extension StudySourceAnchorCitation on StudySourceAnchor {
  /// The anchor as a claim to re-verify, pinned to its saved source version.
  StudyCitation toCitation() => StudyCitation(
    documentId: documentId,
    sectionId: sectionId,
    physicalPage: physicalPage,
    corpusPage: corpusPage,
    quote: quote,
    contentSha256: contentSha256,
  );
}

enum StudyCitationIssue {
  malformed,
  unknownDocument,
  documentNotReady,
  sourceVersionMismatch,
  missingLocator,
  unknownSection,
  sectionUnavailable,
  physicalPageOutOfRange,
  physicalPageOutsideSection,
  corpusPageOutOfRange,
  quoteTooShort,
  quoteNotFound,
}

/// Where a quote was actually found.
enum StudyQuoteScope { section, document }

class StudyResolvedCitation {
  const StudyResolvedCitation({
    required this.citation,
    required this.issues,
    this.document,
    this.section,
    this.quoteScope,
  });

  final StudyCitation citation;
  final List<StudyCitationIssue> issues;
  final StudySourceDocument? document;

  /// Cited section, or the single section that contains the quote.
  final StudyIndexedSection? section;
  final StudyQuoteScope? quoteScope;

  /// Every supplied locator is consistent with the current source.
  bool get verified => issues.isEmpty;

  /// Verified and backed by a quote actually found in the source. Page or
  /// section numbers alone only say where to look, not what the source says.
  bool get isGroundedEvidence => verified && quoteScope != null;

  /// Anchor for a note. Only verified citations become anchors with a pinned
  /// source version; others keep the model's claims for later inspection.
  StudySourceAnchor toAnchor() => StudySourceAnchor(
    documentId: citation.documentId,
    contentSha256: verified ? document?.contentSha256 : citation.contentSha256,
    sectionId: citation.sectionId ?? section?.sectionId,
    physicalPage: citation.physicalPage,
    corpusPage: citation.corpusPage,
    quote: citation.quote,
  );
}

/// Parses inline citations and checks every supplied locator against the
/// project's documents and current workspace indexes.
class StudyCitationResolver {
  StudyCitationResolver({
    required Iterable<StudySourceDocument> documents,
    Map<String, StudyDocumentIndex> indexes = const {},
    List<String>? Function(StudyDocumentIndex index)? readIndexedLines,
  }) : _documents = {for (final doc in documents) doc.id: doc},
       _indexes = Map.unmodifiable(indexes),
       _readIndexedLines =
           readIndexedLines ?? StudyMineruIndexer.tryReadIndexedLines;

  /// Normalised quotes shorter than this match too easily to count as proof.
  static const int minQuoteChars = 6;

  final Map<String, StudySourceDocument> _documents;
  final Map<String, StudyDocumentIndex> _indexes;
  final List<String>? Function(StudyDocumentIndex index) _readIndexedLines;
  final Map<String, List<String>?> _linesCache = {};
  final Map<String, String> _normalizedSectionCache = {};
  final Map<String, String> _normalizedDocumentCache = {};
  final Map<String, StudyResolvedCitation> _resultCache = {};

  /// Documents the resolver checks against, by id.
  Map<String, StudySourceDocument> get documents =>
      Map.unmodifiable(_documents);

  /// Current index of [documentId], if one was supplied.
  StudyDocumentIndex? indexOf(String documentId) => _indexes[documentId];

  List<StudyResolvedCitation> resolveAll(String text) => [
    for (final citation in StudyCitationSyntax.parse(text)) resolve(citation),
  ];

  /// Results are cached per claim, so re-rendering a streaming reply only
  /// verifies citations it has not seen before.
  StudyResolvedCitation resolve(StudyCitation citation) {
    final key = '${citation.format()}\u0000${citation.contentSha256}';
    final cached = _resultCache[key];
    if (cached != null) {
      return StudyResolvedCitation(
        citation: citation,
        issues: cached.issues,
        document: cached.document,
        section: cached.section,
        quoteScope: cached.quoteScope,
      );
    }
    return _resultCache[key] = _resolveUncached(citation);
  }

  StudyResolvedCitation _resolveUncached(StudyCitation citation) {
    if (citation.malformed) {
      return StudyResolvedCitation(
        citation: citation,
        issues: const [StudyCitationIssue.malformed],
      );
    }
    final doc = _documents[citation.documentId];
    if (doc == null) {
      return StudyResolvedCitation(
        citation: citation,
        issues: const [StudyCitationIssue.unknownDocument],
      );
    }
    if (doc.status != StudySourceStatus.ready || doc.contentSha256 == null) {
      return StudyResolvedCitation(
        citation: citation,
        document: doc,
        issues: const [StudyCitationIssue.documentNotReady],
      );
    }
    if (citation.contentSha256 != null &&
        citation.contentSha256 != doc.contentSha256) {
      return StudyResolvedCitation(
        citation: citation,
        document: doc,
        issues: const [StudyCitationIssue.sourceVersionMismatch],
      );
    }

    final issues = <StudyCitationIssue>[];
    final quote = citation.quote?.trim() ?? '';
    if (citation.sectionId == null &&
        citation.physicalPage == null &&
        citation.corpusPage == null &&
        quote.isEmpty) {
      issues.add(StudyCitationIssue.missingLocator);
    }

    final index = _indexes[doc.id];
    StudyIndexedSection? section;
    if (citation.sectionId != null) {
      section = index?.sections
          .where((item) => item.sectionId == citation.sectionId)
          .firstOrNull;
      if (index == null) {
        issues.add(StudyCitationIssue.sectionUnavailable);
      } else if (section == null) {
        issues.add(StudyCitationIssue.unknownSection);
      }
    }

    final page = citation.physicalPage;
    if (page != null) {
      final count = doc.physicalPageCount;
      if (count == null || page < 1 || page > count) {
        issues.add(StudyCitationIssue.physicalPageOutOfRange);
      }
    }
    final bookPage = citation.corpusPage;
    if (bookPage != null) {
      final range = doc.corpusPageRange;
      if (range == null || bookPage < range.start || bookPage > range.end) {
        issues.add(StudyCitationIssue.corpusPageOutOfRange);
      }
    }

    StudyQuoteScope? quoteScope;
    if (quote.isNotEmpty) {
      final probe = normalizeForMatch(quote);
      if (probe.length < minQuoteChars) {
        issues.add(StudyCitationIssue.quoteTooShort);
      } else if (citation.sectionId != null) {
        if (section != null) {
          final text = _normalizedSection(index!, section);
          if (text != null && text.contains(probe)) {
            quoteScope = StudyQuoteScope.section;
          } else if (text == null) {
            issues.add(StudyCitationIssue.sectionUnavailable);
          } else {
            issues.add(StudyCitationIssue.quoteNotFound);
          }
        }
      } else {
        final matches = index == null
            ? const <StudyIndexedSection>[]
            : [
                for (final item in index.sections)
                  if (_normalizedSection(index, item)?.contains(probe) ?? false)
                    item,
              ];
        // A repeated sentence may appear in several sections; the cited page
        // picks the one it belongs to when section page spans are known.
        final onPage = page == null
            ? matches
            : [
                for (final item in matches)
                  if (item.physicalPageRange == null ||
                      (page >= item.physicalPageRange!.start &&
                          page <= item.physicalPageRange!.end))
                    item,
              ];
        final candidates = onPage.isEmpty ? matches : onPage;
        if (candidates.length == 1) {
          section = candidates.single;
          quoteScope = StudyQuoteScope.section;
        } else if (matches.isNotEmpty ||
            _normalizedDocument(doc).contains(probe)) {
          quoteScope = StudyQuoteScope.document;
        } else {
          issues.add(StudyCitationIssue.quoteNotFound);
        }
      }
    }

    // A located section knows which physical pages it spans; a page outside
    // that span means the quote or section and the page disagree.
    final sectionPages = section?.physicalPageRange;
    if (page != null &&
        sectionPages != null &&
        !issues.contains(StudyCitationIssue.physicalPageOutOfRange) &&
        (page < sectionPages.start || page > sectionPages.end)) {
      issues.add(StudyCitationIssue.physicalPageOutsideSection);
    }

    return StudyResolvedCitation(
      citation: citation,
      issues: List<StudyCitationIssue>.unmodifiable(issues.toSet()),
      document: doc,
      section: section,
      quoteScope: quoteScope,
    );
  }

  String _normalizedDocument(StudySourceDocument doc) =>
      _normalizedDocumentCache.putIfAbsent(
        doc.id,
        () => normalizeForMatch(doc.extractedText ?? ''),
      );

  String? _normalizedSection(
    StudyDocumentIndex index,
    StudyIndexedSection section,
  ) {
    final key = '${index.documentId}\u0000${section.sectionId}';
    final cached = _normalizedSectionCache[key];
    if (cached != null) return cached;
    final lines = _linesCache.putIfAbsent(
      index.documentId,
      () => _readIndexedLines(index),
    );
    if (lines == null ||
        section.startLine < 1 ||
        section.endLine > lines.length) {
      return null;
    }
    final normalized = normalizeForMatch(
      lines.sublist(section.startLine - 1, section.endLine).join('\n'),
    );
    _normalizedSectionCache[key] = normalized;
    return normalized;
  }

  /// Comparison form tolerant of line wrapping, Markdown emphasis, inline math
  /// delimiters and curly versus straight quotes. Applied to both sides.
  ///
  /// Whitespace survives as one space only between two characters of a
  /// space-delimited script, so `the rapist` never matches `therapist`, while
  /// a line break inside a Chinese sentence is ignored.
  static String normalizeForMatch(String text) {
    final out = StringBuffer();
    var pendingSpace = false;
    var previousSpaced = false;
    for (final rune in text.runes) {
      if (_isWhitespace(rune)) {
        pendingSpace = true;
        continue;
      }
      // Markdown emphasis, code ticks and math delimiters.
      if (rune == 0x2A || rune == 0x5F || rune == 0x60 || rune == 0x24) {
        continue;
      }
      final char = switch (rune) {
        0x201C || 0x201D || 0x201E || 0xFF02 => 0x22,
        0x2018 || 0x2019 || 0xFF07 => 0x27,
        _ => rune,
      };
      final spaced = _isSpacedScript(char);
      if (pendingSpace && previousSpaced && spaced) out.write(' ');
      pendingSpace = false;
      out.writeCharCode(char);
      previousSpaced = spaced;
    }
    return out.toString();
  }

  static bool _isWhitespace(int c) =>
      c == 0x20 ||
      (c >= 0x09 && c <= 0x0D) ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000 ||
      c == 0xFEFF;

  /// Scripts that separate words with spaces: Latin, Greek, Cyrillic, digits.
  static bool _isSpacedScript(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7) ||
      (c >= 0x370 && c <= 0x3FF) ||
      (c >= 0x400 && c <= 0x52F) ||
      (c >= 0x1E00 && c <= 0x1EFF);
}
