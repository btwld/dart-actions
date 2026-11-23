import 'dart:io';

import 'package:path/path.dart' as p;

import 'changelog.dart';
import 'config.dart';
import 'process.dart';
import 'pubspec.dart';
import 'versioning.dart';

/// One package version change that a release PR proposes.
class PreparedRelease {
  PreparedRelease(this.package, this.from, this.to, this.section);

  final PackageConfig package;
  final String from;
  final String to;

  /// The changelog section for [to], without its heading.
  final String section;
}

/// The release PR content: title and Markdown body.
({String title, String body}) describeReleases(List<PreparedRelease> releases) {
  final title = releases.length == 1
      ? 'chore(release): ${releases.single.package.name} ${releases.single.to}'
      : releases.map((release) => release.to).toSet().length == 1
      ? 'chore(release): ${releases.first.to}'
      : 'chore(release): ${releases.length} packages';
  final body = StringBuffer(
    'This release PR was prepared by the btwld/dart-actions release '
    'workflow. Merging it tags the new versions, and each tag publishes its '
    'package to pub.dev.\n\n',
  );
  body.writeln('| Package | From | To |');
  body.writeln('|---|---|---|');
  for (final release in releases) {
    body.writeln(
      '| ${release.package.name} | ${release.from} | ${release.to} |',
    );
  }
  for (final release in releases) {
    body.write('\n## ${release.package.name} ${release.to}\n\n');
    body.writeln(
      release.section.isEmpty ? '_No changelog entries._' : release.section,
    );
  }

  return (title: title, body: body.toString());
}

/// Writes new versions and changelog sections with the built-in
/// Conventional Commits versioner.
///
/// [version] forces one version for [only] (or every package). Without it,
/// each package gets the next version that its commits since its last tag
/// require; a package without releasable commits is left alone. In fixed
/// mode every package moves to one shared version.
Future<List<PreparedRelease>> prepareBuiltin(
  ReleaseConfig config, {
  required String root,
  String? version,
  Set<String> only = const {},
}) async {
  if (version != null && !isVersion(version)) {
    throw ConfigException('"$version" is not a SemVer version.');
  }
  final unknown = only.difference(
    config.packages.map((package) => package.name).toSet(),
  );
  if (unknown.isNotEmpty) {
    throw ConfigException('Unknown packages: ${unknown.join(', ')}.');
  }
  final selected = config.packages
      .where((package) => only.isEmpty || only.contains(package.name))
      .toList();

  final tags = (await git(
    ['tag', '--list'],
    workingDirectory: root,
  )).split('\n').where((tag) => tag.isNotEmpty).toList();

  final states = <_PackageState>[];
  for (final package in selected) {
    final pubspecFile = File(p.join(root, package.path, 'pubspec.yaml'));
    final current = readPubspecVersion(pubspecFile.readAsStringSync());
    if (current == null || !isVersion(current)) {
      throw ConfigException('${package.name} has no valid version.');
    }
    final lastVersion = highestVersion(
      tags.map(package.versionIn).whereType<String>(),
    );
    final range = lastVersion == null
        ? 'HEAD'
        : '${package.tagFor(lastVersion)}..HEAD';
    final log = await git([
      'log',
      '--format=%s%x1f%b%x1e',
      range,
      '--',
      package.path,
    ], workingDirectory: root);
    final commits = log
        .split('\u001e')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .map((entry) {
          final [subject, ...body] = entry.split('\u001f');
          return ConventionalCommit.parse(subject, body.join('\n'));
        })
        .whereType<ConventionalCommit>()
        .toList();
    states.add(_PackageState(package, current, lastVersion, commits));
  }

  String? sharedTarget;
  if (config.versioning == Versioning.fixed) {
    sharedTarget = version ?? _fixedTarget(states);
    if (sharedTarget == null) return const [];
  }

  final releases = <PreparedRelease>[];
  for (final state in states) {
    final target = sharedTarget ?? version ?? state.target();
    if (target == null || target == state.lastVersion) continue;

    final directory = p.join(root, state.package.path);
    final changelogFile = File(p.join(directory, 'CHANGELOG.md'));
    final changelog = changelogFile.existsSync()
        ? changelogFile.readAsStringSync()
        : '';
    // The version and its changelog section are already in place, so this
    // release PR has nothing to change for the package.
    if (target == state.current && sectionFor(changelog, target) != null) {
      continue;
    }

    final pubspecFile = File(p.join(directory, 'pubspec.yaml'));
    pubspecFile.writeAsStringSync(
      withVersion(pubspecFile.readAsStringSync(), target),
    );

    var section = sectionFor(changelog, target);
    if (section == null) {
      var written = changelogSection(target, state.commits);
      if (!written.contains('\n- ')) {
        written = '$written\n- Maintenance release.\n';
      }
      changelogFile.writeAsStringSync(prependSection(changelog, written));
      section = sectionFor(changelogFile.readAsStringSync(), target)!;
    }
    releases.add(
      PreparedRelease(state.package, state.current, target, section),
    );
  }

  return releases;
}

String? _fixedTarget(List<_PackageState> states) {
  Bump? bump;
  for (final state in states) {
    final packageBump = state.bump;
    if (packageBump != null) {
      bump = bump == null ? packageBump : bump.max(packageBump);
    }
  }
  if (bump == null) return null;
  final base = highestVersion(
    states.map((state) => state.lastVersion ?? state.current),
  )!;
  final next = nextVersion(base, bump);
  final current = highestVersion(states.map((state) => state.current))!;

  return isHigher(current, next) ? current : next;
}

class _PackageState {
  _PackageState(this.package, this.current, this.lastVersion, this.commits);

  final PackageConfig package;
  final String current;
  final String? lastVersion;
  final List<ConventionalCommit> commits;

  Bump? get bump {
    Bump? result;
    for (final commit in commits) {
      final commitBump = commit.bump;
      if (commitBump != null) {
        result = result == null ? commitBump : result.max(commitBump);
      }
    }
    return result;
  }

  /// The next version, or `null` when no commit needs a release.
  String? target() {
    final needed = bump;
    if (needed == null) return null;
    final next = nextVersion(lastVersion ?? current, needed);
    // Keep a version that a maintainer already raised by hand.
    return isHigher(current, next) ? current : next;
  }
}

/// Runs `melos version` without committing, then reports what it changed.
Future<List<PreparedRelease>> prepareWithMelos(
  ReleaseConfig config, {
  required String root,
  String? version,
  Set<String> only = const {},
}) async {
  final before = {
    for (final package in config.packages)
      package.name: readPubspecVersion(
        File(p.join(root, package.path, 'pubspec.yaml')).readAsStringSync(),
      )!,
  };
  final selected = config.packages.where(
    (package) => only.isEmpty || only.contains(package.name),
  );
  // melos runs the version that the workspace pins, so resolve it first.
  await run(config.sdk == Sdk.flutter ? 'flutter' : 'dart', [
    'pub',
    'get',
  ], workingDirectory: root);
  await run('dart', [
    'run',
    'melos',
    'version',
    '--yes',
    '--no-git-commit-version',
    if (version != null)
      for (final package in selected)
        '--manual-version=${package.name}:$version',
  ], workingDirectory: root);

  final releases = <PreparedRelease>[];
  for (final package in config.packages) {
    final directory = p.join(root, package.path);
    final after = readPubspecVersion(
      File(p.join(directory, 'pubspec.yaml')).readAsStringSync(),
    )!;
    if (after == before[package.name]) continue;
    final changelog = File(p.join(directory, 'CHANGELOG.md'));
    releases.add(
      PreparedRelease(
        package,
        before[package.name]!,
        after,
        changelog.existsSync()
            ? sectionFor(changelog.readAsStringSync(), after) ?? ''
            : '',
      ),
    );
  }

  return releases;
}
