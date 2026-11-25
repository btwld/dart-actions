import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'changelog.dart';
import 'config.dart';
import 'github.dart';
import 'process.dart';
import 'pub_dev.dart';
import 'pubspec.dart';

/// A release check that failed. The message lists every failure.
class ReleaseException implements Exception {
  ReleaseException(this.failures);

  final List<String> failures;

  @override
  String toString() => failures.map((failure) => '  - $failure').join('\n');
}

/// The packages that one tag releases, after every check passed.
class TagPlan {
  TagPlan(this.tag, this.version, this.packages);

  final String tag;
  final String version;
  final List<PackageConfig> packages;

  Map<String, Object?> toJson() => {
    'tag': tag,
    'version': version,
    'packages': [
      for (final package in packages)
        {'name': package.name, 'path': package.path},
    ],
  };
}

/// Checks that [tag] may release packages from [root].
///
/// The tag must match a package tag pattern. Every matched package must
/// declare the tagged version and document it in its changelog. [commit] must
/// be reachable from a release branch on `origin`, unless [checkAncestry] is
/// false. With [packageExists], every package must already be on pub.dev.
Future<TagPlan> planTag(
  ReleaseConfig config,
  String tag, {
  required String root,
  String? commit,
  bool checkAncestry = true,
  Future<bool> Function(String package)? packageExists,
}) async {
  final matched = config.packagesForTag(tag);
  final failures = <String>[];

  for (final package in matched.packages) {
    if (packageExists != null && !await packageExists(package.name)) {
      failures.add(
        '${package.name} is not on pub.dev yet. pub.dev only automates '
        'uploads for existing packages: publish the first version by hand.',
      );
    }
    final pubspec = File(p.join(root, package.path, 'pubspec.yaml'));
    final declared = readPubspecVersion(pubspec.readAsStringSync());
    if (declared != matched.version) {
      failures.add(
        '${package.name} declares version "$declared", '
        'but the tag names "${matched.version}".',
      );
    }
    final changelog = File(p.join(root, package.path, 'CHANGELOG.md'));
    if (!changelog.existsSync()) {
      failures.add('${package.name} has no CHANGELOG.md.');
    } else if (sectionFor(changelog.readAsStringSync(), matched.version) ==
        null) {
      failures.add(
        '${package.name} CHANGELOG.md has no "## ${matched.version}" section.',
      );
    }
  }

  if (checkAncestry) {
    final branch = await _releaseBranchContaining(
      config,
      commit ?? await git(['rev-parse', 'HEAD'], workingDirectory: root),
      root: root,
    );
    if (branch == null) {
      failures.add(
        'The tagged commit is not on a release branch '
        '(${config.releaseBranches.join(', ')}). Tag reviewed, merged code only.',
      );
    }
  }

  if (failures.isNotEmpty) throw ReleaseException(failures);

  return TagPlan(tag, matched.version, matched.packages);
}

Future<String?> _releaseBranchContaining(
  ReleaseConfig config,
  String commit, {
  required String root,
}) async {
  final refs = (await git([
    'for-each-ref',
    '--format=%(refname:strip=3)',
    'refs/remotes/origin',
  ], workingDirectory: root)).split('\n').where((ref) => ref.isNotEmpty);

  for (final ref in refs) {
    if (!config.releaseBranches.any(
      (pattern) => _branchMatches(pattern, ref),
    )) {
      continue;
    }
    final result = await run(
      'git',
      ['merge-base', '--is-ancestor', commit, 'refs/remotes/origin/$ref'],
      workingDirectory: root,
      echo: false,
      allowFailure: true,
    );
    if (result.exitCode == 0) return ref;
  }

  return null;
}

bool _branchMatches(String pattern, String branch) => pattern.endsWith('*')
    ? branch.startsWith(pattern.substring(0, pattern.length - 1))
    : branch == pattern;

/// Analyzes and tests [packages] in the workspace, then runs the configured
/// `pre_publish` command. Nothing here holds a credential.
Future<void> verifyPackages(
  ReleaseConfig config,
  List<PackageConfig> packages, {
  required String root,
}) async {
  for (final package in packages) {
    final directory = p.join(root, package.path);
    stdout.writeln('::group::Verify ${package.name}');
    await run(package.executable, ['pub', 'get'], workingDirectory: directory);
    // Nested packages such as example/ need their own resolution before the
    // package directory can be analyzed. Workspace members resolve already.
    for (final nested in await _nestedPackages(package, root: root)) {
      await run(package.executable, [
        'pub',
        'get',
      ], workingDirectory: p.join(root, nested));
    }
    await run(package.executable, [
      'analyze',
      // flutter analyze fails on infos by default; dart analyze does not.
      if (package.flutter) '--no-fatal-infos',
    ], workingDirectory: directory);
    if (package.test && Directory(p.join(directory, 'test')).existsSync()) {
      await run(package.executable, ['test'], workingDirectory: directory);
    }
    stdout.writeln('::endgroup::');
  }

  if (config.prePublish.isNotEmpty) {
    stdout.writeln('::group::pre_publish');
    await run('bash', [
      '-euo',
      'pipefail',
      '-c',
      config.prePublish,
    ], workingDirectory: root);
    stdout.writeln('::endgroup::');
  }
}

/// Directories under [package] that hold their own tracked pubspec.
Future<List<String>> _nestedPackages(
  PackageConfig package, {
  required String root,
}) async {
  final pubspecs = (await git([
    'ls-files',
    '-z',
    '--',
    p.join(package.path, '**', 'pubspec.yaml'),
  ], workingDirectory: root)).split('\u0000').where((file) => file.isNotEmpty);

  return [
    for (final pubspec in pubspecs)
      if (p.normalize(p.dirname(pubspec)) != p.normalize(package.path))
        if (!isWorkspaceMember(File(p.join(root, pubspec)).readAsStringSync()))
          p.dirname(pubspec),
  ];
}

/// Publishes [plan] in dependency order.
///
/// For each package: skip it when the version is already on pub.dev; resolve
/// and analyze a copy outside the workspace against pub.dev; restore files the
/// build changed; run the dry run; then fetch a pub.dev credential, upload,
/// and remove the credential. With [dryRun], stop before the credential.
Future<void> publishPlan(
  TagPlan plan, {
  required String root,
  bool dryRun = false,
  Duration resolveRetryDelay = const Duration(seconds: 30),
}) async {
  final summary = StringBuffer('### ${plan.tag}\n\n');
  // In a dry run nothing is uploaded, so later packages resolve these
  // siblings from their staged copies instead of from pub.dev.
  final notUploaded = <String, PackageConfig>{};
  for (final package in plan.packages) {
    stdout.writeln('::group::Publish ${package.name} ${plan.version}');
    if (await isVersionPublished(package.name, plan.version)) {
      notice('${package.name} ${plan.version} is already on pub.dev.');
      summary.writeln('- ${package.name} ${plan.version}: already published');
      stdout.writeln('::endgroup::');
      continue;
    }

    final directory = p.join(root, package.path);
    await run(package.executable, ['pub', 'get'], workingDirectory: directory);
    await _checkHostedResolution(
      package,
      root: root,
      retryDelay: resolveRetryDelay,
      localSiblings: notUploaded,
    );
    await _restoreTrackedFiles(package, root: root);
    await _dryRun(package, directory);

    if (dryRun) {
      notUploaded[package.name] = package;
      summary.writeln('- ${package.name} ${plan.version}: dry run passed');
    } else {
      await _upload(package, directory);
      await waitUntilPublished(package.name, plan.version);
      summary.writeln('- ${package.name} ${plan.version}: published');
    }
    stdout.writeln('::endgroup::');
  }
  addSummary(summary.toString());
}

/// Copies the package out of the workspace and resolves it against pub.dev.
///
/// Inside a pub workspace, sibling constraints resolve to local directories,
/// so a workspace check never proves that a pub.dev consumer can resolve
/// this release.
Future<void> _checkHostedResolution(
  PackageConfig package, {
  required String root,
  required Duration retryDelay,
  Map<String, PackageConfig> localSiblings = const {},
}) async {
  final staging = Directory.systemTemp.createTempSync('release_stage_');
  try {
    final source = File(
      p.join(root, package.path, 'pubspec.yaml'),
    ).readAsStringSync();
    final siblings = [
      for (final name in dependenciesAmong(source, localSiblings.keys.toSet()))
        localSiblings[name]!,
    ];
    final files = (await git(
      [
        'ls-files',
        '-z',
        '--',
        package.path,
        'analysis_options.yaml',
        for (final sibling in siblings) sibling.path,
      ],
      workingDirectory: root,
    )).split('\u0000').where((file) => file.isNotEmpty);
    for (final relative in files) {
      final source = File(p.join(root, relative));
      if (!source.existsSync()) continue;
      if (p.basename(relative) == 'pubspec_overrides.yaml') continue;
      final target = File(p.join(staging.path, relative));
      target.parent.createSync(recursive: true);
      source.copySync(target.path);
    }
    final stagedDirectory = p.join(staging.path, package.path);
    final pubspec = File(p.join(stagedDirectory, 'pubspec.yaml'));
    pubspec.writeAsStringSync(
      withPathOverrides(detachFromWorkspace(pubspec.readAsStringSync()), {
        for (final sibling in siblings)
          sibling.name: p.relative(
            p.join(staging.path, sibling.path),
            from: stagedDirectory,
          ),
      }),
    );
    for (final sibling in siblings) {
      final siblingPubspec = File(
        p.join(staging.path, sibling.path, 'pubspec.yaml'),
      );
      siblingPubspec.writeAsStringSync(
        detachFromWorkspace(siblingPubspec.readAsStringSync()),
      );
    }

    // pub.dev can list a new sibling version before its package index
    // serves it to pub get, so retry for up to 10 minutes.
    for (var attempt = 1; ; attempt++) {
      final result = await run(
        package.executable,
        ['pub', 'get'],
        workingDirectory: stagedDirectory,
        allowFailure: true,
      );
      if (result.exitCode == 0) break;
      if (attempt == 20) {
        throw ReleaseException([
          '${package.name} does not resolve against pub.dev outside the '
              'workspace.',
        ]);
      }
      stdout.writeln('Resolution attempt $attempt failed; retrying.');
      await Future<void>.delayed(retryDelay);
    }
    // Only lib/ reaches consumers; examples and tests have their own
    // resolution and were analyzed in the verify job.
    await run(package.executable, [
      'analyze',
      // flutter analyze fails on infos by default; dart analyze does not.
      if (package.flutter) '--no-fatal-infos',
      'lib',
    ], workingDirectory: stagedDirectory);
  } finally {
    staging.deleteSync(recursive: true);
  }
}

/// Restores tracked files that dependency resolution or tests changed.
///
/// `flutter pub get` can rewrite `analysis_options.yaml`, and pub refuses to
/// publish a package with modified tracked files. The release publishes the
/// tagged tree.
Future<void> _restoreTrackedFiles(
  PackageConfig package, {
  required String root,
}) async {
  final modified = await git([
    'diff',
    '--name-only',
    '--',
    package.path,
  ], workingDirectory: root);
  if (modified.isEmpty) return;
  warning(
    'Build steps changed tracked files; restoring them: '
    '${modified.split('\n').join(', ')}',
  );
  await git(['checkout', '--', package.path], workingDirectory: root);
}

Future<void> _dryRun(PackageConfig package, String directory) async {
  final result = await run(
    package.executable,
    ['pub', 'publish', '--dry-run'],
    workingDirectory: directory,
    allowFailure: true,
  );
  final counts = publishValidationCounts(result.output);
  if (counts == null) {
    throw ReleaseException([
      '${package.name}: the dry run exited with ${result.exitCode} and '
          'printed no validation summary.',
    ]);
  }
  final warnings = counts.warnings;
  if (warnings > 0 && !package.allowWarnings) {
    throw ReleaseException([
      '${package.name}: the dry run reported $warnings '
          '${warnings == 1 ? 'warning' : 'warnings'}. Fix them, or set '
          'allow_warnings for a warning pub cannot avoid.',
    ]);
  }
  // pub exits with 65 for warnings alone; any other failure stops here.
  if (result.exitCode != 0 && !(result.exitCode == 65 && warnings > 0)) {
    throw ReleaseException([
      '${package.name}: the dry run exited with ${result.exitCode}.',
    ]);
  }
  if (warnings > 0) {
    warning('${package.name}: accepting $warnings dry-run warnings.');
  }
}

/// Uploads with a short-lived pub.dev credential.
///
/// The credential is added only for this command and removed afterwards.
/// While a credential is registered, pub sends it with public reads too, and
/// pub.dev rejects those with HTTP 403 (dart-lang/pub-dev#9576). That is why
/// the dry run above validates first and the upload passes
/// `--skip-validation`. pub.dev still validates the archive on upload.
Future<void> _upload(PackageConfig package, String directory) async {
  final token = await requestPubDevIdToken();
  final environment = {'PUB_TOKEN': token};
  try {
    await run(
      'dart',
      ['pub', 'token', 'add', 'https://pub.dev', '--env-var', 'PUB_TOKEN'],
      credentialed: true,
      environment: environment,
      workingDirectory: directory,
    );
    await run(
      package.executable,
      ['pub', 'publish', '--force', '--skip-validation'],
      credentialed: true,
      environment: environment,
      workingDirectory: directory,
    );
  } finally {
    await run(
      'dart',
      ['pub', 'token', 'remove', 'https://pub.dev'],
      allowFailure: true,
      workingDirectory: directory,
    );
  }
}

/// Writes [plan] to the step outputs.
void writePlanOutputs(ReleaseConfig config, TagPlan plan) {
  setOutput('plan', jsonEncode(plan.toJson()));
  setOutput('sdk', config.sdk.name);
  setOutput('flutter_version', config.flutterVersion);
  setOutput('flutter_version_file', config.flutterVersionFile);
  addSummary(
    '### Release plan for ${plan.tag}\n\n'
    '${plan.packages.map((package) => '- ${package.name} ${plan.version}').join('\n')}',
  );
}
