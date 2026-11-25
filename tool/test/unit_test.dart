import 'dart:io';

import 'package:dart_actions_release/dart_actions_release.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('ConventionalCommit', () {
    test('reads type, scope, and breaking markers', () {
      final commit = ConventionalCommit.parse('feat(cli)!: add a flag')!;
      expect(commit.type, 'feat');
      expect(commit.scope, 'cli');
      expect(commit.breaking, isTrue);
      expect(commit.bump, Bump.major);
    });

    test('reads a breaking footer in the body', () {
      final commit = ConventionalCommit.parse(
        'fix: drop the old API',
        'Details.\n\nBREAKING CHANGE: the old API is gone.',
      )!;
      expect(commit.bump, Bump.major);
    });

    test('maps types to bumps', () {
      expect(ConventionalCommit.parse('feat: x')!.bump, Bump.minor);
      expect(ConventionalCommit.parse('fix: x')!.bump, Bump.patch);
      expect(ConventionalCommit.parse('perf: x')!.bump, Bump.patch);
      expect(ConventionalCommit.parse('docs: x')!.bump, isNull);
      expect(ConventionalCommit.parse('chore(deps): x')!.bump, isNull);
    });

    test('ignores other subjects', () {
      expect(ConventionalCommit.parse('Update README.md'), isNull);
    });
  });

  group('nextVersion', () {
    test('follows SemVer from 1.0.0', () {
      expect(nextVersion('1.2.3', Bump.patch), '1.2.4');
      expect(nextVersion('1.2.3', Bump.minor), '1.3.0');
      expect(nextVersion('1.2.3', Bump.major), '2.0.0');
    });

    test('follows the Dart 0.x convention', () {
      expect(nextVersion('0.2.2', Bump.patch), '0.2.3');
      expect(nextVersion('0.2.2', Bump.minor), '0.2.3');
      expect(nextVersion('0.2.2', Bump.major), '0.3.0');
    });

    test('stays on a prerelease line', () {
      expect(nextVersion('2.0.0-beta.3', Bump.major), '2.0.0-beta.4');
      expect(nextVersion('1.0.0-rc', Bump.patch), '1.0.0-rc.1');
    });
  });

  group('changelog', () {
    test('builds grouped sections', () {
      final section = changelogSection('1.1.0', [
        ConventionalCommit.parse('feat(ui): add a button')!,
        ConventionalCommit.parse('fix: stop a crash')!,
        ConventionalCommit.parse('docs: typo')!,
      ]);
      expect(
        section,
        '## 1.1.0\n\n### Features\n\n- **ui:** add a button\n\n'
        '### Fixes\n\n- stop a crash\n',
      );
    });

    test('prepends below the title', () {
      const changelog = '# Changelog\n\n## 1.0.0\n\n- First.\n';
      expect(
        prependSection(changelog, '## 1.1.0\n\n- Second.\n'),
        '# Changelog\n\n## 1.1.0\n\n- Second.\n\n## 1.0.0\n\n- First.\n',
      );
    });

    test('finds sections in common heading styles', () {
      const changelog =
          '# Changelog\n\n## [1.2.0] - 2026-01-01\n\n- New.\n\n'
          '## v1.1.0\n\n- Old.\n';
      expect(sectionFor(changelog, '1.2.0'), '- New.');
      expect(sectionFor(changelog, '1.1.0'), '- Old.');
      expect(sectionFor(changelog, '1.0.0'), isNull);
      // 1.2.0 must not match 1.2.0-beta.1.
      expect(sectionFor('## 1.2.0-beta.1\n\n- Beta.\n', '1.2.0'), isNull);
    });
  });

  group('publishValidationCounts', () {
    test('reads warnings and hints', () {
      expect(publishValidationCounts('Package has 0 warnings.'), (
        warnings: 0,
        hints: 0,
      ));
      expect(publishValidationCounts('Package has 2 warnings and 1 hint.'), (
        warnings: 2,
        hints: 1,
      ));
      expect(publishValidationCounts('no summary'), isNull);
    });
  });

  group('isVersionPublished', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response.statusCode = switch (request.uri.path) {
          '/api/packages/a/versions/1.0.0' => 200,
          '/api/packages/a/versions/2.0.0' => 404,
          _ => 500,
        };
        request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('maps 200 and 404 and throws on anything else', () async {
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      expect(await isVersionPublished('a', '1.0.0', server: uri), isTrue);
      expect(await isVersionPublished('a', '2.0.0', server: uri), isFalse);
      expect(
        isVersionPublished('a', '3.0.0', server: uri),
        throwsA(isA<HttpException>()),
      );
    });
  });

  group('ReleaseConfig', () {
    late TestRepo repo;

    setUp(() => repo = TestRepo.create());
    tearDown(() => repo.delete());

    test('orders packages after their dependencies', () {
      repo.write(
        'packages/b/pubspec.yaml',
        pubspec('b', '1.0.0', dependencies: {'a': '^1.0.0'}),
      );
      repo.write('packages/a/pubspec.yaml', pubspec('a', '1.0.0'));
      final config = ReleaseConfig.parse(
        'packages:\n'
        '  - path: packages/b\n    tag: b-v{{version}}\n'
        '  - path: packages/a\n    tag: a-v{{version}}\n',
        root: repo.root,
      );
      expect(config.packages.map((package) => package.name), ['a', 'b']);
      expect(config.sdk, Sdk.dart);
      expect(config.flutterVersion, 'stable');
    });

    test('detects Flutter packages', () {
      repo.write('pubspec.yaml', pubspec('app', '1.0.0', flutter: true));
      final config = ReleaseConfig.parse(
        'packages:\n  - path: .\n',
        root: repo.root,
      );
      expect(config.sdk, Sdk.flutter);
      expect(config.packages.single.executable, 'flutter');
      expect(config.packages.single.tagPattern, 'v{{version}}');
    });

    test('rejects bad configurations', () {
      repo.write('packages/a/pubspec.yaml', pubspec('a', '1.0.0'));
      repo.write('packages/b/pubspec.yaml', pubspec('b', '1.0.0'));
      repo.write('private/pubspec.yaml', 'name: private\npublish_to: none\n');
      void rejects(String yaml, String message) => expect(
        () => ReleaseConfig.parse(yaml, root: repo.root),
        throwsA(
          isA<ConfigException>().having(
            (error) => error.message,
            'message',
            contains(message),
          ),
        ),
      );

      rejects('pakages: []\n', 'unknown keys');
      rejects('packages: []\n', 'at least one package');
      rejects('packages:\n  - path: missing\n', 'pubspec.yaml is missing');
      rejects('packages:\n  - path: private\n', 'publish_to');
      rejects('packages:\n  - path: packages/a\n    tag: v1\n', 'exactly once');
      rejects(
        'packages:\n  - path: packages/a\n  - path: packages/b\n',
        'distinct tag patterns',
      );
      rejects('packages:\n  - path: ../x\n', 'inside the repository');
    });

    test('maps tags to packages', () {
      repo.write('packages/a/pubspec.yaml', pubspec('a', '1.0.0'));
      repo.write('packages/b/pubspec.yaml', pubspec('b', '1.0.0'));
      final config = ReleaseConfig.parse(
        'versioning: fixed\n'
        'packages:\n  - path: packages/a\n  - path: packages/b\n',
        root: repo.root,
      );
      final matched = config.packagesForTag('v1.2.0-beta.1');
      expect(matched.version, '1.2.0-beta.1');
      expect(matched.packages, hasLength(2));
      expect(
        () => config.packagesForTag('a-v1.0.0'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => config.packagesForTag('v1.0'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
