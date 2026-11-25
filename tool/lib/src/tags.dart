import 'dart:io';

import 'package:path/path.dart' as p;

import 'changelog.dart';
import 'config.dart';
import 'github.dart';
import 'process.dart';
import 'pub_dev.dart';
import 'pubspec.dart';
import 'release.dart';
import 'versioning.dart';

/// A release tag that the current commit still needs.
class PendingTag {
  PendingTag(this.tag, this.version, this.packages);

  final String tag;
  final String version;
  final List<PackageConfig> packages;

  String get title => releaseTitle(packages, version);
}

/// The name of the release of [packages] at [version].
String releaseTitle(List<PackageConfig> packages, String version) =>
    packages.length == 1 ? '${packages.single.name} $version' : version;

/// The GitHub release notes for [plan], built from the changelog sections.
String releaseNotes(
  ReleaseConfig config,
  TagPlan plan, {
  required String root,
}) => [
  for (final package in plan.packages)
    if (_changelogSection(package, plan.version, root: root)
        case final section?)
      config.packages.length == 1 ? section : '## ${package.name}\n\n$section',
].join('\n\n');

String? _changelogSection(
  PackageConfig package,
  String version, {
  required String root,
}) {
  final changelog = File(p.join(root, package.path, 'CHANGELOG.md'));

  return changelog.existsSync()
      ? sectionFor(changelog.readAsStringSync(), version)
      : null;
}

/// Lists the tags that the pubspec versions at HEAD need.
///
/// A package is skipped when its tag already exists on `origin`, when its
/// changelog has no section for the version, or when the version is already
/// on pub.dev (so adopting this workflow does not tag old releases). Tags
/// come back in publish order. [isPublished] lets tests avoid the network.
Future<List<PendingTag>> pendingTags(
  ReleaseConfig config, {
  required String root,
  Future<bool> Function(String package, String version)? isPublished,
}) async {
  final published = isPublished ?? isVersionPublished;
  final remoteTags =
      (await git(['ls-remote', '--tags', 'origin'], workingDirectory: root))
          .split('\n')
          .map((line) => line.split('\t').last)
          .where((ref) => ref.startsWith('refs/tags/'))
          .map(
            (ref) => ref.substring('refs/tags/'.length).replaceAll('^{}', ''),
          )
          .toSet();

  final byTag = <String, ({String version, List<PackageConfig> packages})>{};
  for (final package in config.packages) {
    final directory = p.join(root, package.path);
    final version = readPubspecVersion(
      File(p.join(directory, 'pubspec.yaml')).readAsStringSync(),
    )!;
    final tag = package.tagFor(version);
    if (remoteTags.contains(tag)) continue;

    if (_changelogSection(package, version, root: root) == null) {
      warning(
        '${package.name} $version has no changelog section, so it gets no tag.',
      );
      continue;
    }
    if (await published(package.name, version)) {
      notice(
        '${package.name} $version is already on pub.dev; not tagging it now.',
      );
      continue;
    }

    byTag
        .putIfAbsent(tag, () => (version: version, packages: []))
        .packages
        .add(package);
  }

  return [
    for (final MapEntry(key: tag, value: entry) in byTag.entries)
      PendingTag(tag, entry.version, entry.packages),
  ];
}

/// Creates and pushes [tags] one at a time.
///
/// GitHub starts no workflows when one push carries more than three tags, so
/// each tag gets its own push. The push must use a GitHub App token: a tag
/// pushed with the default `GITHUB_TOKEN` starts no workflow, and the publish
/// workflow would never run. The publish workflow creates the GitHub release
/// after the upload, so no release announces a version pub.dev lacks.
Future<void> pushTags(List<PendingTag> tags, {required String root}) async {
  final commit = await git(['rev-parse', 'HEAD'], workingDirectory: root);
  for (final tag in tags) {
    await run('git', [
      'tag',
      '--annotate',
      tag.tag,
      '--message',
      'Release ${tag.title}',
      commit,
    ], workingDirectory: root);
    await run('git', [
      'push',
      'origin',
      'refs/tags/${tag.tag}',
    ], workingDirectory: root);
  }
  addSummary(
    tags.isEmpty
        ? 'No new release tags.'
        : '### Release tags\n\n${tags.map((tag) => '- `${tag.tag}`').join('\n')}',
  );
}

/// Creates the GitHub release for [plan] once pub.dev serves every package.
///
/// Does nothing when the release already exists, so a re-run is safe.
/// [waitForVersion] lets tests avoid the network.
Future<void> announceRelease(
  ReleaseConfig config,
  TagPlan plan, {
  required String root,
  Future<void> Function(String package, String version)? waitForVersion,
}) async {
  final wait = waitForVersion ?? waitUntilPublished;
  for (final package in plan.packages) {
    try {
      await wait(package.name, plan.version);
    } on StateError catch (error) {
      throw ReleaseException([
        '${error.message} The GitHub release waits until pub.dev serves '
            'every package of the tag.',
      ]);
    }
  }

  final existing = await run(
    'gh',
    ['release', 'view', plan.tag, '--json', 'tagName'],
    workingDirectory: root,
    credentialed: true,
    echo: false,
    allowFailure: true,
  );
  if (existing.exitCode == 0) {
    notice('The GitHub release ${plan.tag} already exists.');
    return;
  }

  final notes = File(
    p.join(Directory.systemTemp.path, 'release_notes_${plan.tag}.md'),
  )..writeAsStringSync(releaseNotes(config, plan, root: root));
  await run(
    'gh',
    [
      'release',
      'create',
      plan.tag,
      '--verify-tag',
      '--title',
      releaseTitle(plan.packages, plan.version),
      '--notes-file',
      notes.path,
      if (isPreRelease(plan.version)) '--prerelease',
    ],
    workingDirectory: root,
    credentialed: true,
  );
  addSummary('Created the GitHub release ${plan.tag}.');
}
