import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// StudyPi publishes builds as GitHub releases of its own repository.
/// A repository without any release answers 404, which means "no update".
final Uri studyPiLatestReleaseUri = Uri.parse(
  'https://api.github.com/repos/yubowen050929/StudyPi/releases/latest',
);

class UpdateInfo {
  final String version;
  final DateTime? releasedAt;
  final String? notes;

  /// Download links keyed by platform (`android`, `ios`, `macos`, `windows`,
  /// `linux`); `universal` is the release page.
  final Map<String, String> downloads;

  const UpdateInfo({
    required this.version,
    this.releasedAt,
    this.notes,
    this.downloads = const {},
  });

  String? bestDownloadUrl() {
    final String platform;
    if (Platform.isAndroid) {
      platform = 'android';
    } else if (Platform.isIOS) {
      platform = 'ios';
    } else if (Platform.isMacOS) {
      platform = 'macos';
    } else if (Platform.isWindows) {
      platform = 'windows';
    } else if (Platform.isLinux) {
      platform = 'linux';
    } else {
      platform = 'universal';
    }
    return downloads[platform] ?? downloads['universal'];
  }

  /// Parses a GitHub `releases/latest` response. The tag may carry a leading
  /// `v` (`v1.4.0`); assets are matched to platforms by file extension.
  factory UpdateInfo.fromGitHubRelease(Map<String, dynamic> json) {
    final tag = (json['tag_name'] ?? '').toString().trim();
    final version = tag.startsWith('v') || tag.startsWith('V')
        ? tag.substring(1)
        : tag;
    final downloads = <String, String>{};
    final page = json['html_url']?.toString();
    if (page != null && page.isNotEmpty) downloads['universal'] = page;
    for (final asset in (json['assets'] as List?) ?? const []) {
      if (asset is! Map) continue;
      final name = asset['name']?.toString().toLowerCase() ?? '';
      final url = asset['browser_download_url']?.toString() ?? '';
      if (url.isEmpty) continue;
      final platform = switch (name) {
        _ when name.endsWith('.apk') => 'android',
        _ when name.endsWith('.ipa') => 'ios',
        _ when name.endsWith('.dmg') => 'macos',
        _ when name.endsWith('.exe') || name.endsWith('.msix') => 'windows',
        _ when name.endsWith('.appimage') || name.endsWith('.deb') => 'linux',
        _ => null,
      };
      if (platform != null) downloads.putIfAbsent(platform, () => url);
    }
    return UpdateInfo(
      version: version,
      releasedAt: DateTime.tryParse(json['published_at']?.toString() ?? ''),
      notes: json['body']?.toString(),
      downloads: downloads,
    );
  }
}

class UpdateProvider extends ChangeNotifier {
  UpdateProvider({this._client, Future<String> Function()? currentVersion})
    : _currentVersion = currentVersion ?? _installedVersion;

  final http.Client? _client;
  final Future<String> Function() _currentVersion;

  UpdateInfo? _available;
  UpdateInfo? get available => _available;
  bool _checking = false;
  bool get checking => _checking;
  String? _error;
  String? get error => _error;

  static Future<String> _installedVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  Future<void> checkForUpdates() async {
    if (_checking) return;
    _checking = true;
    _error = null;
    notifyListeners();
    final client = _client ?? http.Client();
    try {
      final resp = await client.get(
        studyPiLatestReleaseUri,
        headers: const {'Accept': 'application/vnd.github+json'},
      );
      if (resp.statusCode == 404) {
        _available = null;
        return;
      }
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final info = UpdateInfo.fromGitHubRelease(data);
      final hasNew = isRemoteVersionNewer(
        remoteVersion: info.version,
        currentVersion: await _currentVersion(),
      );
      _available = hasNew ? info : null;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (_client == null) client.close();
      _checking = false;
      notifyListeners();
    }
  }
}

/// Compares `major.minor.patch` only; build numbers and suffixes are ignored.
@visibleForTesting
bool isRemoteVersionNewer({
  required String remoteVersion,
  required String currentVersion,
}) {
  List<int> parse(String v) {
    final parts = v.split(RegExp(r'[.+-]'));
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0,
    ];
  }

  final a = parse(remoteVersion);
  final b = parse(currentVersion);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}
