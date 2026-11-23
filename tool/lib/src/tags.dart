import 'dart:io';

import 'package:path/path.dart' as p;

import 'changelog.dart';
import 'config.dart';
import 'github.dart';
import 'process.dart';
import 'pub_dev.dart';
import 'pubspec.dart';
import 'versioning.dart';

/// A release tag that the current commit still needs.
class PendingTag {
  PendingTag(this.tag, this.version, this.packages, this.notes);

  final String tag;
  final String version;
  final List<PackageConfig> packages;

  /// The GitHub release notes, built from the changelog sections.
  final String notes;

  bool get preRelease => isPreRelease(version);

  String get title =>
      packages.length == 1 ? '${packages.single.name} $version' : version;
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

  final byTag =
      <
        String,
        ({String version, List<PackageConfig> packages, List<String> notes})
      >{};
  for (final package in config.packages) {
    final directory = p.join(root, package.path);
    final version = readPubspecVersion(
      File(p.join(directory, 'pubspec.yaml')).readAsStringSync(),
    )!;
    final tag = package.tagFor(version);
    if (remoteTags.contains(tag)) continue;

    final changelog = File(p.join(directory, 'CHANGELOG.md'));
    final section = changelog.existsSync()
        ? sectionFor(changelog.readAsStringSync(), version)
        : null;
    if (section == null) {
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

    final entry = byTag.putIfAbsent(
      tag,
      () => (version: version, packages: [], notes: []),
    );
    entry.packages.add(package);
    entry.notes.add(
      config.packages.length == 1 ? section : '## ${package.name}\n\n$section',
    );
  }

  return [
    for (final MapEntry(key: tag, value: entry) in byTag.entries)
      PendingTag(tag, entry.version, entry.packages, entry.notes.join('\n\n')),
  ];
}

/// Creates and pushes [tags] one at a time, then creates a GitHub release
/// for each.
///
/// GitHub starts no workflows when one push carries more than three tags, so
/// each tag gets its own push. The push must use a GitHub App token: a tag
/// pushed with the default `GITHUB_TOKEN` starts no workflow, and the publish
/// workflow would never run.
Future<void> pushTags(
  List<PendingTag> tags, {
  required String root,
  bool createReleases = true,
}) async {
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

    if (!createReleases) continue;
    final notes = File(
      p.join(Directory.systemTemp.path, 'release_notes_${tag.tag}.md'),
    )..writeAsStringSync(tag.notes);
    await run(
      'gh',
      [
        'release',
        'create',
        tag.tag,
        '--verify-tag',
        '--title',
        tag.title,
        '--notes-file',
        notes.path,
        if (tag.preRelease) '--prerelease',
      ],
      workingDirectory: root,
      credentialed: true,
    );
  }
  addSummary(
    tags.isEmpty
        ? 'No new release tags.'
        : '### Release tags\n\n${tags.map((tag) => '- `${tag.tag}`').join('\n')}',
  );
}
