import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'pubspec.dart';

/// The default location of the release configuration in a caller repository.
const defaultConfigPath = '.github/release.yaml';

/// How the packages of one repository share versions.
enum Versioning {
  /// Each package has its own version and tag.
  independent,

  /// Every package has the same version.
  fixed,
}

/// The tool that writes new versions and changelog sections.
enum Versioner {
  /// The Conventional Commits versioner in this tool.
  builtin,

  /// `melos version`, for repositories that already configure melos.
  melos,
}

/// The SDK that the release jobs install.
enum Sdk { dart, flutter }

/// A configuration problem that stops a release before it starts.
class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One package that this repository publishes.
class PackageConfig {
  PackageConfig({
    required this.path,
    required this.name,
    required this.tagPattern,
    required this.test,
    required this.flutter,
    this.allowWarnings = false,
  });

  /// The package directory, relative to the repository root.
  final String path;

  /// The package name from its pubspec.
  final String name;

  /// The tag pattern on pub.dev, for example `v{{version}}`.
  final String tagPattern;

  /// Whether the release runs this package's tests.
  final bool test;

  /// Whether this package needs the Flutter SDK.
  final bool flutter;

  /// Whether `pub publish --dry-run` warnings are accepted. Use it only for a
  /// warning that pub cannot avoid, such as the `lib/main.dart` entry point
  /// that analyzer plugins need.
  final bool allowWarnings;

  /// The tag for [version].
  String tagFor(String version) =>
      tagPattern.replaceAll(versionPlaceholder, version);

  /// The version in [tag], or `null` when [tag] does not match the pattern.
  String? versionIn(String tag) {
    final index = tagPattern.indexOf(versionPlaceholder);
    final prefix = tagPattern.substring(0, index);
    final suffix = tagPattern.substring(index + versionPlaceholder.length);
    if (!tag.startsWith(prefix) || !tag.endsWith(suffix)) return null;
    if (tag.length < prefix.length + suffix.length + 1) return null;
    final version = tag.substring(prefix.length, tag.length - suffix.length);

    return _semver.hasMatch(version) ? version : null;
  }

  /// The executable for pub commands on this package.
  String get executable => flutter ? 'flutter' : 'dart';
}

/// The placeholder that pub.dev tag patterns use for the version.
const versionPlaceholder = '{{version}}';

final _semver = RegExp(
  r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
);

/// The parsed `.github/release.yaml` of one repository.
class ReleaseConfig {
  ReleaseConfig({
    required this.sdk,
    required this.flutterVersion,
    required this.flutterVersionFile,
    required this.versioning,
    required this.versioner,
    required this.releaseBranches,
    required this.prePublish,
    required this.packages,
  });

  final Sdk sdk;

  /// An exact Flutter version, or `stable` when neither field is set.
  final String flutterVersion;

  /// A file such as `.fvmrc` that pins the Flutter version.
  final String flutterVersionFile;

  final Versioning versioning;
  final Versioner versioner;

  /// Branches that a release tag must be reachable from. A trailing `*`
  /// matches any suffix, as in `release/*`.
  final List<String> releaseBranches;

  /// An optional shell command that must pass before any upload.
  final String prePublish;

  /// Packages in publish order: each package comes after the packages it
  /// depends on.
  final List<PackageConfig> packages;

  /// Reads the configuration at [configPath] under [root].
  static ReleaseConfig load({
    String root = '.',
    String configPath = defaultConfigPath,
  }) {
    final file = File(p.join(root, configPath));
    if (!file.existsSync()) {
      throw ConfigException('$configPath is missing.');
    }

    return parse(file.readAsStringSync(), root: root, source: configPath);
  }

  /// Parses [yaml]. Package pubspecs are read from [root].
  static ReleaseConfig parse(
    String yaml, {
    String root = '.',
    String source = defaultConfigPath,
  }) {
    final Object? document;
    try {
      document = loadYaml(yaml);
    } on YamlException catch (error) {
      throw ConfigException('$source is not valid YAML: ${error.message}');
    }
    if (document is! Map) {
      throw ConfigException('$source must be a YAML map.');
    }

    const known = {
      'sdk',
      'flutter_version',
      'flutter_version_file',
      'versioning',
      'versioner',
      'release_branches',
      'pre_publish',
      'packages',
    };
    final unknown = document.keys.where((key) => !known.contains(key));
    if (unknown.isNotEmpty) {
      throw ConfigException(
        '$source has unknown keys: ${unknown.join(', ')}. '
        'Known keys: ${known.join(', ')}.',
      );
    }

    final versioning = _enumValue(
      document,
      'versioning',
      Versioning.values,
      Versioning.independent,
      source,
    );
    final versioner = _enumValue(
      document,
      'versioner',
      Versioner.values,
      Versioner.builtin,
      source,
    );

    final rawPackages = document['packages'];
    if (rawPackages is! List || rawPackages.isEmpty) {
      throw ConfigException('$source must list at least one package.');
    }

    final packages = <PackageConfig>[];
    final pubspecs = <String, String>{};
    for (final (index, entry) in rawPackages.indexed) {
      final where = '$source packages[$index]';
      if (entry is! Map) throw ConfigException('$where must be a map.');
      final unknownPackageKeys = entry.keys.where(
        (key) => !const {'path', 'tag', 'test', 'allow_warnings'}.contains(key),
      );
      if (unknownPackageKeys.isNotEmpty) {
        throw ConfigException(
          '$where has unknown keys: ${unknownPackageKeys.join(', ')}.',
        );
      }

      final path = p.normalize('${entry['path'] ?? '.'}');
      if (p.isAbsolute(path) || path.startsWith('..')) {
        throw ConfigException('$where path must stay inside the repository.');
      }
      final pubspecFile = File(p.join(root, path, 'pubspec.yaml'));
      if (!pubspecFile.existsSync()) {
        throw ConfigException('$where: $path/pubspec.yaml is missing.');
      }
      final pubspec = pubspecFile.readAsStringSync();
      final name = readPubspecName(pubspec);
      if (name == null) {
        throw ConfigException('$where: $path/pubspec.yaml has no name.');
      }
      if (isUnpublishable(pubspec)) {
        throw ConfigException(
          '$where: $name sets publish_to, so it cannot be released.',
        );
      }

      final tag = '${entry['tag'] ?? 'v$versionPlaceholder'}';
      if (!tag.contains(versionPlaceholder) ||
          tag.indexOf(versionPlaceholder) !=
              tag.lastIndexOf(versionPlaceholder)) {
        throw ConfigException(
          '$where tag must contain $versionPlaceholder exactly once.',
        );
      }

      final test = entry['test'] ?? true;
      if (test is! bool) throw ConfigException('$where test must be a bool.');
      final allowWarnings = entry['allow_warnings'] ?? false;
      if (allowWarnings is! bool) {
        throw ConfigException('$where allow_warnings must be a bool.');
      }

      pubspecs[name] = pubspec;
      packages.add(
        PackageConfig(
          path: path,
          name: name,
          tagPattern: tag,
          test: test,
          flutter: requiresFlutter(pubspec),
          allowWarnings: allowWarnings,
        ),
      );
    }

    final names = packages.map((package) => package.name).toList();
    final duplicates = {
      for (final name in names)
        if (names.where((other) => other == name).length > 1) name,
    };
    if (duplicates.isNotEmpty) {
      throw ConfigException(
        '$source lists ${duplicates.join(', ')} more than once.',
      );
    }

    // Independent packages need distinct tags, or one tag would publish
    // several packages that do not share a version.
    if (versioning == Versioning.independent) {
      final patterns = packages.map((package) => package.tagPattern).toList();
      if (patterns.toSet().length != patterns.length) {
        throw ConfigException(
          '$source: independent packages need distinct tag patterns.',
        );
      }
    }

    final sdkDefault = packages.any((package) => package.flutter)
        ? Sdk.flutter
        : Sdk.dart;
    final sdk = _enumValue(document, 'sdk', Sdk.values, sdkDefault, source);
    if (sdk == Sdk.dart && packages.any((package) => package.flutter)) {
      throw ConfigException(
        '$source sets sdk: dart, but a package depends on Flutter.',
      );
    }

    final flutterVersion = '${document['flutter_version'] ?? ''}';
    final flutterVersionFile = '${document['flutter_version_file'] ?? ''}';
    if (flutterVersion.isNotEmpty && flutterVersionFile.isNotEmpty) {
      throw ConfigException(
        '$source sets both flutter_version and flutter_version_file.',
      );
    }

    final branches = document['release_branches'] ?? const ['main'];
    if (branches is! List || branches.isEmpty) {
      throw ConfigException('$source release_branches must be a list.');
    }

    return ReleaseConfig(
      sdk: sdk,
      flutterVersion: flutterVersion.isEmpty && flutterVersionFile.isEmpty
          ? 'stable'
          : flutterVersion,
      flutterVersionFile: flutterVersionFile,
      versioning: versioning,
      versioner: versioner,
      releaseBranches: branches.map((branch) => '$branch').toList(),
      prePublish: '${document['pre_publish'] ?? ''}',
      packages: _publishOrderPreferringDev(packages, pubspecs),
    );
  }

  /// The packages that [tag] releases, with the version it names.
  ///
  /// Throws a [ConfigException] when no package matches.
  ({String version, List<PackageConfig> packages}) packagesForTag(String tag) {
    String? version;
    final matched = <PackageConfig>[];
    for (final package in packages) {
      final candidate = package.versionIn(tag);
      if (candidate == null) continue;
      version ??= candidate;
      matched.add(package);
    }
    if (version == null) {
      throw ConfigException(
        'Tag "$tag" matches no package tag pattern: '
        '${packages.map((package) => package.tagPattern).toSet().join(', ')}.',
      );
    }

    return (version: version, packages: matched);
  }
}

T _enumValue<T extends Enum>(
  Map<dynamic, dynamic> document,
  String key,
  List<T> values,
  T fallback,
  String source,
) {
  final raw = document[key];
  if (raw == null) return fallback;
  for (final value in values) {
    if (value.name == '$raw') return value;
  }
  throw ConfigException(
    '$source $key must be one of: ${values.map((value) => value.name).join(', ')}.',
  );
}

/// Orders [packages] after their dependencies, and after their
/// dev dependencies too unless that creates a cycle.
///
/// A dev dependency also has to resolve when the release checks a package
/// against pub.dev, so publishing it first is better when possible. Packages
/// often dev-depend on each other for tests, so such cycles fall back to the
/// regular dependencies only.
List<PackageConfig> _publishOrderPreferringDev(
  List<PackageConfig> packages,
  Map<String, String> pubspecs,
) {
  try {
    return _publishOrder(packages, pubspecs, includeDev: true);
  } on ConfigException {
    return _publishOrder(packages, pubspecs, includeDev: false);
  }
}

/// Orders [packages] so that every package follows its listed dependencies.
List<PackageConfig> _publishOrder(
  List<PackageConfig> packages,
  Map<String, String> pubspecs, {
  required bool includeDev,
}) {
  final byName = {for (final package in packages) package.name: package};
  final ordered = <PackageConfig>[];
  final state = <String, bool>{}; // false: visiting, true: done.

  void visit(String name, List<String> chain) {
    final current = state[name];
    if (current == true) return;
    if (current == false) {
      throw ConfigException(
        'Packages depend on each other in a cycle: '
        '${[...chain, name].join(' -> ')}.',
      );
    }
    state[name] = false;
    for (final dependency in dependenciesAmong(
      pubspecs[name]!,
      byName.keys.toSet(),
      includeDev: includeDev,
    )) {
      visit(dependency, [...chain, name]);
    }
    state[name] = true;
    ordered.add(byName[name]!);
  }

  for (final package in packages) {
    visit(package.name, const []);
  }

  return ordered;
}
