import 'package:dart_actions_release/dart_actions_release.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TestRepo repo;

  setUp(() => repo = TestRepo.create());
  tearDown(() => repo.delete());

  ReleaseConfig load() => ReleaseConfig.load(root: repo.root);

  group('planTag', () {
    setUp(() {
      repo.write('.github/release.yaml', 'packages:\n  - path: .\n');
      repo.write('pubspec.yaml', pubspec('demo', '1.0.0'));
      repo.write('CHANGELOG.md', '# Changelog\n\n## 1.0.0\n\n- First.\n');
      repo.commit('feat: first');
      repo.push();
    });

    test('accepts a tag on main that matches the pubspec', () async {
      final plan = await planTag(load(), 'v1.0.0', root: repo.root);
      expect(plan.version, '1.0.0');
      expect(plan.packages.single.name, 'demo');
    });

    test(
      'rejects a version mismatch and a missing changelog section',
      () async {
        expect(
          planTag(load(), 'v1.0.1', root: repo.root),
          throwsA(
            isA<ReleaseException>().having(
              (error) => error.failures,
              'failures',
              hasLength(2),
            ),
          ),
        );
      },
    );

    test('rejects a commit that is not on a release branch', () async {
      repo.git(['checkout', '-b', 'feature']);
      repo.commit('feat: unreviewed');
      expect(
        planTag(load(), 'v1.0.0', root: repo.root),
        throwsA(isA<ReleaseException>()),
      );
    });
  });

  group('prepareBuiltin', () {
    test(
      'bumps an independent package from its commits since its tag',
      () async {
        repo.write(
          '.github/release.yaml',
          'packages:\n'
              '  - path: packages/a\n    tag: a-v{{version}}\n'
              '  - path: packages/b\n    tag: b-v{{version}}\n',
        );
        repo.write('packages/a/pubspec.yaml', pubspec('a', '1.0.0'));
        repo.write(
          'packages/a/CHANGELOG.md',
          '# Changelog\n\n## 1.0.0\n\n- First.\n',
        );
        repo.write('packages/b/pubspec.yaml', pubspec('b', '0.1.0'));
        repo.write('packages/b/CHANGELOG.md', '## 0.1.0\n\n- First.\n');
        repo.commit('chore: initial');
        repo.tag('a-v1.0.0');
        repo.tag('b-v0.1.0');

        repo.write('packages/a/lib/a.dart', '// new');
        repo.commit('feat(a): add a thing');
        repo.write('packages/a/lib/b.dart', '// fix');
        repo.commit('fix: repair a thing');
        repo.write('packages/b/README.md', 'docs');
        repo.commit('docs: explain b');

        final releases = await prepareBuiltin(load(), root: repo.root);
        expect(
          releases.map((release) => '${release.package.name} ${release.to}'),
          ['a 1.1.0'],
        );
        expect(
          repo.read('packages/a/pubspec.yaml'),
          contains('version: 1.1.0'),
        );
        expect(
          repo.read('packages/a/CHANGELOG.md'),
          startsWith(
            '# Changelog\n\n## 1.1.0\n\n### Features\n\n- **a:** add a thing\n\n'
            '### Fixes\n\n- repair a thing\n\n## 1.0.0',
          ),
        );
        expect(
          repo.read('packages/b/pubspec.yaml'),
          contains('version: 0.1.0'),
        );
      },
    );

    test('moves fixed packages to one shared version', () async {
      repo.write(
        '.github/release.yaml',
        'versioning: fixed\npackages:\n  - path: packages/a\n  - path: packages/b\n',
      );
      repo.write('packages/a/pubspec.yaml', pubspec('a', '2.0.0-beta.3'));
      repo.write(
        'packages/b/pubspec.yaml',
        pubspec('b', '2.0.0-beta.3', dependencies: {'a': '^2.0.0-beta.3'}),
      );
      repo.commit('chore: initial');
      repo.tag('v2.0.0-beta.3');
      repo.write('packages/b/lib/b.dart', '// fix');
      repo.commit('fix(b): repair');

      final releases = await prepareBuiltin(load(), root: repo.root);
      expect(
        releases.map((release) => '${release.package.name} ${release.to}'),
        ['a 2.0.0-beta.4', 'b 2.0.0-beta.4'],
      );
      expect(
        repo.read('packages/a/CHANGELOG.md'),
        contains('- Maintenance release.'),
      );
    });

    test('uses an explicit version', () async {
      repo.write('.github/release.yaml', 'packages:\n  - path: .\n');
      repo.write('pubspec.yaml', pubspec('demo', '1.0.0-rc.2'));
      repo.commit('chore: initial');
      repo.tag('v1.0.0-rc.2');

      final releases = await prepareBuiltin(
        load(),
        root: repo.root,
        version: '1.0.0',
      );
      expect(releases.single.to, '1.0.0');
      expect(describeReleases(releases).title, 'chore(release): demo 1.0.0');
    });

    test('does nothing without releasable commits', () async {
      repo.write('.github/release.yaml', 'packages:\n  - path: .\n');
      repo.write('pubspec.yaml', pubspec('demo', '1.0.0'));
      repo.commit('chore: initial');
      repo.tag('v1.0.0');
      repo.commit('docs: words');

      expect(await prepareBuiltin(load(), root: repo.root), isEmpty);
    });
  });

  group('pendingTags', () {
    test(
      'lists untagged, unpublished versions with changelog sections',
      () async {
        repo.write(
          '.github/release.yaml',
          'packages:\n'
              '  - path: packages/b\n    tag: b-v{{version}}\n'
              '  - path: packages/a\n    tag: a-v{{version}}\n'
              '  - path: packages/c\n    tag: c-v{{version}}\n'
              '  - path: packages/d\n    tag: d-v{{version}}\n',
        );
        repo.write('packages/a/pubspec.yaml', pubspec('a', '1.1.0'));
        repo.write('packages/a/CHANGELOG.md', '## 1.1.0\n\n- New.\n');
        repo.write(
          'packages/b/pubspec.yaml',
          pubspec('b', '1.0.0', dependencies: {'a': '^1.1.0'}),
        );
        repo.write('packages/b/CHANGELOG.md', '## 1.0.0\n\n- First.\n');
        repo.write('packages/c/pubspec.yaml', pubspec('c', '0.5.0'));
        repo.write('packages/c/CHANGELOG.md', '## 0.4.0\n\n- Old.\n');
        repo.write('packages/d/pubspec.yaml', pubspec('d', '3.0.0'));
        repo.write('packages/d/CHANGELOG.md', '## 3.0.0\n\n- Out.\n');
        repo.commit('chore(release): a 1.1.0');
        repo.push();

        final tags = await pendingTags(
          load(),
          root: repo.root,
          isPublished: (package, version) async => package == 'd',
        );
        // a comes first: b depends on it. c has no section, d is published.
        expect(tags.map((tag) => tag.tag), ['a-v1.1.0', 'b-v1.0.0']);
        expect(tags.first.notes, '## a\n\n- New.');

        await pushTags(tags, root: repo.root, createReleases: false);
        final remote = repo.git(['ls-remote', '--tags', 'origin']);
        expect(remote, contains('refs/tags/a-v1.1.0'));
        expect(remote, contains('refs/tags/b-v1.0.0'));
        expect(
          await pendingTags(
            load(),
            root: repo.root,
            isPublished: (package, _) async => package == 'd',
          ),
          isEmpty,
          reason: 'pushed tags are not listed again',
        );
      },
    );
  });
}
