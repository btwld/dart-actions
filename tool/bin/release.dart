import 'dart:io';

import 'package:dart_actions_release/dart_actions_release.dart';

const _usage =
    '''
Release tool for the btwld/dart-actions v2 workflows.

Usage: dart run dart_actions_release:release <command> [options]

Every command reads .github/release.yaml in the repository given by --root.

Commands:
  check                    Validate the configuration and list packages.
  plan --tag=<tag>         Check that a tag may release, and write the plan
       [--commit=<sha>]    to the step outputs. Use --no-ancestry only
       [--no-ancestry]     for local checks.
  verify --tag=<tag>       Analyze and test the tagged packages, then run
                           pre_publish. Holds no credential.
  publish --tag=<tag>      Publish the tagged packages in dependency order.
          [--dry-run]      Stop before the upload.
  prepare [--version=<v>]  Write the next versions and changelog sections.
          [--packages=a,b] Limit an explicit version to some packages.
          [--summary=<f>]  Write the release PR body to a file.
  tag [--push]             List the tags HEAD needs; with --push, create
      [--no-release]       and push them and create GitHub releases.

Global options:
  --root=<dir>             Repository root. Defaults to the current directory.
  --config=<path>          Configuration path. Defaults to $defaultConfigPath.
''';

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  final flags = <String>{};
  final positional = <String>[];
  for (final argument in arguments) {
    if (argument.startsWith('--')) {
      final [name, ...value] = argument.substring(2).split('=');
      value.isEmpty ? flags.add(name) : options[name] = value.join('=');
    } else {
      positional.add(argument);
    }
  }
  if (positional.length != 1 || flags.contains('help')) {
    stdout.write(_usage);
    exitCode = flags.contains('help') ? 0 : 64;
    return;
  }

  final root = options['root'] ?? '.';
  try {
    final config = ReleaseConfig.load(
      root: root,
      configPath: options['config'] ?? defaultConfigPath,
    );
    switch (positional.single) {
      case 'check':
        setOutput('sdk', config.sdk.name);
        setOutput('flutter_version', config.flutterVersion);
        setOutput('flutter_version_file', config.flutterVersionFile);
        stdout.writeln('Configuration is valid. Publish order:');
        for (final package in config.packages) {
          stdout.writeln(
            '  ${package.name} (${package.path}) tag ${package.tagPattern}',
          );
        }
      case 'plan':
        final plan = await planTag(
          config,
          _required(options, 'tag'),
          root: root,
          commit: options['commit'],
          checkAncestry: !flags.contains('no-ancestry'),
          packageExists: isPackageOnPubDev,
        );
        writePlanOutputs(config, plan);
      case 'verify':
        final plan = await planTag(
          config,
          _required(options, 'tag'),
          root: root,
          checkAncestry: false,
        );
        await verifyPackages(config, plan.packages, root: root);
      case 'publish':
        final plan = await planTag(
          config,
          _required(options, 'tag'),
          root: root,
          checkAncestry: false,
        );
        await publishPlan(plan, root: root, dryRun: flags.contains('dry-run'));
      case 'prepare':
        final only = (options['packages'] ?? '')
            .split(',')
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty)
            .toSet();
        final version = options['version'];
        final releases = config.versioner == Versioner.melos
            ? await prepareWithMelos(
                config,
                root: root,
                version: version,
                only: only,
              )
            : await prepareBuiltin(
                config,
                root: root,
                version: version,
                only: only,
              );
        setOutput('changed', '${releases.isNotEmpty}');
        if (releases.isEmpty) {
          stdout.writeln('No package needs a release.');
          return;
        }
        final description = describeReleases(releases);
        setOutput('title', description.title);
        if (options['summary'] case final path?) {
          File(path).writeAsStringSync(description.body);
        }
        stdout.writeln(description.title);
        stdout.writeln(description.body);
      case 'tag':
        final tags = await pendingTags(config, root: root);
        setOutput('tags', tags.map((tag) => tag.tag).join(' '));
        if (tags.isEmpty) stdout.writeln('No new release tags.');
        for (final tag in tags) {
          stdout.writeln(
            '${flags.contains('push') ? 'Tagging' : 'Needs'} ${tag.tag}',
          );
        }
        if (flags.contains('push')) {
          await pushTags(
            tags,
            root: root,
            createReleases: !flags.contains('no-release'),
          );
        }
      default:
        stdout.write(_usage);
        exitCode = 64;
    }
  } on ConfigException catch (error) {
    stderr.writeln('::error::$error');
    exitCode = 1;
  } on ReleaseException catch (error) {
    stderr.writeln('::error::The release cannot continue:\n$error');
    exitCode = 1;
  } on CommandException catch (error) {
    stderr.writeln('::error::$error');
    exitCode = 1;
  }
}

String _required(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.isEmpty) {
    throw ConfigException('--$name is required.');
  }
  return value;
}
