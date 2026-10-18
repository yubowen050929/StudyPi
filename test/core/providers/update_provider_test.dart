import 'dart:convert';

import 'package:Kelivo/core/providers/update_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _release(String tag) => {
  'tag_name': tag,
  'html_url': 'https://github.com/yubowen050929/StudyPi/releases/tag/$tag',
  'published_at': '2026-10-18T12:00:00Z',
  'body': 'Notes',
  'assets': [
    {
      'name': 'studypi-android-arm64-v8a.apk',
      'browser_download_url': 'https://example.com/studypi.apk',
    },
    {
      'name': 'StudyPi.dmg',
      'browser_download_url': 'https://example.com/studypi.dmg',
    },
    {'name': 'checksums.txt', 'browser_download_url': 'https://example.com/c'},
  ],
};

UpdateProvider _provider(http.Response response, {String current = '1.3.1'}) {
  return UpdateProvider(
    client: MockClient((request) async {
      expect(request.url, studyPiLatestReleaseUri);
      return response;
    }),
    currentVersion: () async => current,
  );
}

void main() {
  test('parses a GitHub release into version, notes and platform links', () {
    final info = UpdateInfo.fromGitHubRelease(_release('v1.4.0'));
    expect(info.version, '1.4.0');
    expect(info.notes, 'Notes');
    expect(info.releasedAt, DateTime.utc(2026, 10, 18, 12));
    expect(info.downloads, {
      'universal':
          'https://github.com/yubowen050929/StudyPi/releases/tag/v1.4.0',
      'android': 'https://example.com/studypi.apk',
      'macos': 'https://example.com/studypi.dmg',
    });
  });

  test('offers a newer StudyPi release', () async {
    final provider = _provider(
      http.Response(jsonEncode(_release('v1.4.0')), 200),
    );
    await provider.checkForUpdates();
    expect(provider.error, isNull);
    expect(provider.available?.version, '1.4.0');
  });

  test('ignores a release that is not newer', () async {
    final provider = _provider(
      http.Response(jsonEncode(_release('v1.3.1')), 200),
    );
    await provider.checkForUpdates();
    expect(provider.error, isNull);
    expect(provider.available, isNull);
  });

  test('treats a repository without releases as up to date', () async {
    final provider = _provider(http.Response('{"message":"Not Found"}', 404));
    await provider.checkForUpdates();
    expect(provider.error, isNull);
    expect(provider.available, isNull);
  });

  test('reports other HTTP failures', () async {
    final provider = _provider(http.Response('rate limited', 403));
    await provider.checkForUpdates();
    expect(provider.error, contains('403'));
    expect(provider.available, isNull);
  });

  test('compares major.minor.patch and ignores build suffixes', () {
    expect(
      isRemoteVersionNewer(remoteVersion: '1.10.0', currentVersion: '1.9.9'),
      isTrue,
    );
    expect(
      isRemoteVersionNewer(remoteVersion: '1.3.1+90', currentVersion: '1.3.1'),
      isFalse,
    );
    expect(
      isRemoteVersionNewer(remoteVersion: '1.3.0', currentVersion: '1.3.1'),
      isFalse,
    );
  });
}
