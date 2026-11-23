import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

Map<dynamic, dynamic> _document(String pubspec) {
  final document = loadYaml(pubspec);

  return document is Map ? document : const {};
}

/// The `name` field of [pubspec], or `null` when it is missing.
String? readPubspecName(String pubspec) {
  final name = _document(pubspec)['name'];

  return name == null ? null : '$name';
}

/// The `version` field of [pubspec], or `null` when it is missing.
String? readPubspecVersion(String pubspec) {
  final version = _document(pubspec)['version'];

  return version == null ? null : '$version';
}

/// Whether [pubspec] opts out of publishing with `publish_to`.
bool isUnpublishable(String pubspec) =>
    _document(pubspec).containsKey('publish_to');

/// Whether the package described by [pubspec] needs the Flutter SDK.
bool requiresFlutter(String pubspec) {
  final document = _document(pubspec);
  final environment = document['environment'];
  if (environment is Map && environment.containsKey('flutter')) return true;
  for (final section in const ['dependencies', 'dev_dependencies']) {
    final dependencies = document[section];
    if (dependencies is! Map) continue;
    for (final dependency in dependencies.values) {
      if (dependency is Map && dependency['sdk'] == 'flutter') return true;
    }
  }

  return false;
}

/// The names in [candidates] that [pubspec] depends on directly.
Set<String> dependenciesAmong(
  String pubspec,
  Set<String> candidates, {
  bool includeDev = true,
}) {
  final document = _document(pubspec);
  final sections = ['dependencies', if (includeDev) 'dev_dependencies'];

  return {
    for (final section in sections)
      if (document[section] case final Map dependencies)
        for (final name in dependencies.keys)
          if (candidates.contains('$name')) '$name',
  };
}

/// Returns [pubspec] with its `version` set to [version].
String withVersion(String pubspec, String version) {
  final editor = YamlEditor(pubspec);
  editor.update(['version'], version);

  return editor.toString();
}

/// Removes `resolution: workspace`, so pub resolves the package on its own
/// against pub.dev, as a consumer would.
String detachFromWorkspace(String pubspec) {
  if (!_document(pubspec).containsKey('resolution')) return pubspec;
  final editor = YamlEditor(pubspec);
  editor.remove(['resolution']);

  return editor.toString();
}

/// Points the [overrides] dependencies of [pubspec] at local paths.
String withPathOverrides(String pubspec, Map<String, String> overrides) {
  if (overrides.isEmpty) return pubspec;
  final editor = YamlEditor(pubspec);
  if (_document(pubspec)['dependency_overrides'] is! Map) {
    editor.update(['dependency_overrides'], <String, Object?>{});
  }
  for (final MapEntry(:key, :value) in overrides.entries) {
    editor.update(['dependency_overrides', key], {'path': value});
  }

  return editor.toString();
}

/// Whether [pubspec] belongs to a pub workspace (`resolution: workspace`).
bool isWorkspaceMember(String pubspec) =>
    _document(pubspec)['resolution'] == 'workspace';
