import 'dart:io';

import 'package:path/path.dart' as p;

/// A temporary git repository with a bare `origin`.
class TestRepo {
  TestRepo._(this.root, this.origin);

  final String root;
  final String origin;

  static TestRepo create() {
    final base = Directory.systemTemp.createTempSync('release_tool_test_');
    final origin = p.join(base.path, 'origin.git');
    final root = p.join(base.path, 'work');
    _git(base.path, ['init', '--bare', '--initial-branch=main', origin]);
    _git(base.path, ['init', '--initial-branch=main', root]);
    _git(root, ['config', 'user.email', 'test@example.com']);
    _git(root, ['config', 'user.name', 'Test']);
    _git(root, ['config', 'commit.gpgsign', 'false']);
    _git(root, ['config', 'tag.gpgsign', 'false']);
    _git(root, ['remote', 'add', 'origin', origin]);

    return TestRepo._(root, origin);
  }

  void write(String path, String content) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String read(String path) => File(p.join(root, path)).readAsStringSync();

  void commit(String message) {
    _git(root, ['add', '-A']);
    _git(root, ['commit', '--allow-empty', '-m', message]);
  }

  void tag(String name) => _git(root, ['tag', name]);

  void push() {
    _git(root, ['push', '--quiet', '--tags', 'origin', 'HEAD:main']);
    _git(root, ['fetch', '--quiet', 'origin']);
  }

  String git(List<String> arguments) => _git(root, arguments);

  void delete() => Directory(p.dirname(root)).deleteSync(recursive: true);

  static String _git(String directory, List<String> arguments) {
    final result = Process.runSync(
      'git',
      arguments,
      workingDirectory: directory,
    );
    if (result.exitCode != 0) {
      throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
    }
    return '${result.stdout}'.trim();
  }
}

String pubspec(
  String name,
  String version, {
  Map<String, String> dependencies = const {},
  bool flutter = false,
  bool workspace = false,
}) {
  final buffer = StringBuffer('name: $name\nversion: $version\n')
    ..writeln('environment:')
    ..writeln('  sdk: ^3.8.0');
  if (flutter) buffer.writeln('  flutter: ">=3.32.0"');
  if (workspace) buffer.writeln('resolution: workspace');
  if (dependencies.isNotEmpty || flutter) {
    buffer.writeln('dependencies:');
    if (flutter) buffer.writeln('  flutter:\n    sdk: flutter');
    for (final MapEntry(:key, :value) in dependencies.entries) {
      buffer.writeln('  $key: $value');
    }
  }
  return buffer.toString();
}
