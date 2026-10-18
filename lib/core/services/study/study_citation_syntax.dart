/// The inline citation marker grammar, independent of project storage so
/// renderers and speech can handle markers without loading any sources.
library;

/// One inline citation written by a model or restored from a saved anchor.
///
/// Wire format inside replies and workspace notes:
/// `[[cite doc="<id>" sec="sec-3" page="12" book_page="95" quote="..."]]`.
/// `page` is the 1-based physical page inside the PDF file; `book_page` is the
/// printed textbook page. The two are never converted into each other.
class StudyCitation {
  const StudyCitation({
    required this.documentId,
    this.sectionId,
    this.physicalPage,
    this.corpusPage,
    this.quote,
    this.contentSha256,
    this.start = 0,
    this.end = 0,
    this.malformed = false,
  });

  final String documentId;
  final String? sectionId;
  final int? physicalPage;
  final int? corpusPage;
  final String? quote;

  /// Source version pinned by a saved anchor; model citations leave it null.
  final String? contentSha256;

  /// UTF-16 offsets of the whole `[[cite ...]]` marker in the parsed text.
  final int start;
  final int end;

  /// The marker was recognised but its attributes could not be parsed.
  final bool malformed;

  /// Canonical marker text, escaping quotes and backslashes in values.
  String format() {
    final buf = StringBuffer('[[cite doc="${_escape(documentId)}"');
    if (sectionId != null) buf.write(' sec="${_escape(sectionId!)}"');
    if (physicalPage != null) buf.write(' page="$physicalPage"');
    if (corpusPage != null) buf.write(' book_page="$corpusPage"');
    if (quote != null) buf.write(' quote="${_escape(quote!)}"');
    buf.write(']]');
    return buf.toString();
  }

  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

class StudyCitationSyntax {
  const StudyCitationSyntax._();

  /// [text] without its citation markers, for speech and plain-text copies.
  static String stripMarkers(String text) {
    final citations = parse(text);
    if (citations.isEmpty) return text;
    final buf = StringBuffer();
    var cursor = 0;
    for (final citation in citations) {
      buf.write(text.substring(cursor, citation.start));
      cursor = citation.end;
    }
    buf.write(text.substring(cursor));
    return buf.toString();
  }

  /// Finds `[[cite ...]]` markers outside fenced code blocks and inline code.
  static List<StudyCitation> parse(String text) {
    final citations = <StudyCitation>[];
    var i = 0;
    var atLineStart = true;
    String? fenceChar;
    var fenceLen = 0;
    while (i < text.length) {
      if (atLineStart) {
        final fence = _fenceAt(text, i);
        if (fenceChar == null && fence != null) {
          fenceChar = fence.char;
          fenceLen = fence.length;
        } else if (fenceChar != null &&
            fence != null &&
            fence.char == fenceChar &&
            fence.length >= fenceLen &&
            fence.restIsBlank) {
          fenceChar = null;
          fenceLen = 0;
        }
        atLineStart = false;
        if (fence != null) {
          i = _lineEnd(text, i);
          continue;
        }
      }
      final ch = text.codeUnitAt(i);
      if (ch == 0x0A) {
        atLineStart = true;
        i++;
        continue;
      }
      if (fenceChar != null) {
        i = _lineEnd(text, i);
        continue;
      }
      if (ch == 0x60) {
        final run = _runLength(text, i, 0x60);
        final close = _findBacktickRun(text, i + run, run);
        if (close >= 0) {
          i = close + run;
          continue;
        }
        i += run;
        continue;
      }
      if (text.startsWith('[[cite', i)) {
        final afterTag = i + 6;
        if (afterTag < text.length &&
            (text.startsWith(']]', afterTag) ||
                _isSpace(text.codeUnitAt(afterTag)))) {
          final parsed = _parseMarker(text, i, afterTag);
          if (parsed != null) {
            citations.add(parsed);
            i = parsed.end;
            continue;
          }
        }
      }
      i++;
    }
    return citations;
  }

  static StudyCitation? _parseMarker(String text, int start, int cursor) {
    final attrs = <String, String>{};
    var malformed = false;
    var i = cursor;
    while (true) {
      while (i < text.length && _isSpace(text.codeUnitAt(i))) {
        i++;
      }
      if (i >= text.length) return null;
      if (text.startsWith(']]', i)) {
        i += 2;
        break;
      }
      final keyStart = i;
      while (i < text.length && _isKeyChar(text.codeUnitAt(i))) {
        i++;
      }
      final key = text.substring(keyStart, i);
      if (key.isEmpty ||
          i + 1 >= text.length ||
          text[i] != '=' ||
          text[i + 1] != '"') {
        final close = text.indexOf(']]', i);
        if (close < 0) return null;
        malformed = true;
        i = close + 2;
        break;
      }
      i += 2;
      final value = StringBuffer();
      var closed = false;
      while (i < text.length) {
        final c = text[i];
        if (c == r'\' && i + 1 < text.length) {
          value.write(text[i + 1]);
          i += 2;
          continue;
        }
        if (c == '"') {
          closed = true;
          i++;
          break;
        }
        if (c == '\n') break;
        value.write(c);
        i++;
      }
      if (!closed) {
        final close = text.indexOf(']]', i);
        if (close < 0) return null;
        malformed = true;
        i = close + 2;
        break;
      }
      if (attrs.containsKey(key)) malformed = true;
      attrs[key] = value.toString();
    }

    final documentId = attrs['doc']?.trim() ?? '';
    final sectionId = _nonEmpty(attrs['sec']);
    final rawPage = _nonEmpty(attrs['page']);
    final rawBookPage = _nonEmpty(attrs['book_page']);
    final physicalPage = rawPage == null ? null : int.tryParse(rawPage);
    final corpusPage = rawBookPage == null ? null : int.tryParse(rawBookPage);
    if (documentId.isEmpty ||
        (rawPage != null && physicalPage == null) ||
        (rawBookPage != null && corpusPage == null)) {
      malformed = true;
    }
    return StudyCitation(
      documentId: documentId,
      sectionId: sectionId,
      physicalPage: physicalPage,
      corpusPage: corpusPage,
      quote: _nonEmpty(attrs['quote']),
      start: start,
      end: i,
      malformed: malformed,
    );
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static ({String char, int length, bool restIsBlank})? _fenceAt(
    String text,
    int lineStart,
  ) {
    var i = lineStart;
    var indent = 0;
    while (i < text.length && text[i] == ' ' && indent < 4) {
      i++;
      indent++;
    }
    if (i >= text.length || indent > 3) return null;
    final char = text[i];
    if (char != '`' && char != '~') return null;
    final run = _runLength(text, i, char.codeUnitAt(0));
    if (run < 3) return null;
    final lineEnd = _lineEnd(text, i);
    final rest = text.substring(i + run, lineEnd);
    // A backtick fence's info string cannot contain backticks.
    if (char == '`' && rest.contains('`')) return null;
    return (char: char, length: run, restIsBlank: rest.trim().isEmpty);
  }

  static int _lineEnd(String text, int from) {
    final newline = text.indexOf('\n', from);
    return newline < 0 ? text.length : newline;
  }

  static int _runLength(String text, int from, int codeUnit) {
    var i = from;
    while (i < text.length && text.codeUnitAt(i) == codeUnit) {
      i++;
    }
    return i - from;
  }

  static int _findBacktickRun(String text, int from, int length) {
    var i = from;
    while (i < text.length) {
      final next = text.indexOf('`', i);
      if (next < 0) return -1;
      final run = _runLength(text, next, 0x60);
      if (run == length) return next;
      i = next + run;
    }
    return -1;
  }

  static bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A;

  static bool _isKeyChar(int c) =>
      (c >= 0x61 && c <= 0x7A) || c == 0x5F || (c >= 0x30 && c <= 0x39);
}
