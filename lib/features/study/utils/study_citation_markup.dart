import '../../../core/services/study/study_citation_syntax.dart';

/// A reply with its `[[cite ...]]` markers rewritten into the markdown
/// renderer's `[citation](id)` capsules, numbered per distinct claim.
class StudyCitationMarkup {
  StudyCitationMarkup._(this.markdown, this._citations, this._labels);

  static const String idPrefix = 'studycite-';
  static const int maxPendingMarkerChars = 600;

  final String markdown;
  final Map<String, StudyCitation> _citations;
  final Map<String, String> _labels;

  static bool isStudyId(String id) => id.startsWith(idPrefix);

  StudyCitation? citationFor(String id) => _citations[id];

  String? labelFor(String id) => _labels[id];

  /// Null when [text] has no citation markers (and nothing to hide while
  /// streaming), so callers can keep the original text untouched.
  static StudyCitationMarkup? rewrite(String text, {bool streaming = false}) {
    final citations = StudyCitationSyntax.parse(text);
    var end = text.length;
    if (streaming) {
      // Hide a marker that is still being written instead of flashing its
      // attribute soup until the closing brackets arrive.
      // Bounded: text that merely mentions `[[cite` is shown again once it
      // is clearly longer than any marker.
      final tailStart = citations.isEmpty ? 0 : citations.last.end;
      final open = text.indexOf('[[cite', tailStart);
      if (open >= 0 &&
          !text.contains(']]', open) &&
          text.length - open <= maxPendingMarkerChars) {
        end = open;
      }
    }
    if (citations.isEmpty && end == text.length) return null;

    final buf = StringBuffer();
    final byId = <String, StudyCitation>{};
    final labels = <String, String>{};
    final numberBySignature = <String, int>{};
    var cursor = 0;
    for (final citation in citations) {
      if (citation.start >= end) break;
      buf.write(text.substring(cursor, citation.start));
      // `![citation](...)` would parse as an image after an exclamation mark.
      if (citation.start > 0 && text.codeUnitAt(citation.start - 1) == 0x21) {
        buf.write('\u200B');
      }
      final number = numberBySignature.putIfAbsent(
        citation.format(),
        () => numberBySignature.length + 1,
      );
      final id = '$idPrefix$number';
      byId.putIfAbsent(id, () => citation);
      labels[id] = '$number';
      buf.write('[citation]($id)');
      cursor = citation.end;
    }
    if (cursor < end) buf.write(text.substring(cursor, end));
    return StudyCitationMarkup._(buf.toString(), byId, labels);
  }
}
