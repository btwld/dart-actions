/// A commit subject parsed with the Conventional Commits rules.
class ConventionalCommit {
  ConventionalCommit({
    required this.type,
    required this.scope,
    required this.breaking,
    required this.description,
  });

  final String type;
  final String? scope;
  final bool breaking;
  final String description;

  static final _header = RegExp(
    r'^(?<type>[a-zA-Z]+)(?:\((?<scope>[^)]*)\))?(?<bang>!)?:\s*(?<description>.+)$',
  );

  /// Parses [subject] and [body], or returns `null` for a non-conventional
  /// subject.
  static ConventionalCommit? parse(String subject, [String body = '']) {
    final match = _header.firstMatch(subject.trim());
    if (match == null) return null;

    return ConventionalCommit(
      type: match.namedGroup('type')!.toLowerCase(),
      scope: match.namedGroup('scope'),
      breaking:
          match.namedGroup('bang') != null ||
          RegExp(r'^BREAKING[ -]CHANGE:', multiLine: true).hasMatch(body),
      description: match.namedGroup('description')!.trim(),
    );
  }

  /// The release this commit needs, or `null` when it needs none.
  Bump? get bump {
    if (breaking) return Bump.major;
    return switch (type) {
      'feat' => Bump.minor,
      'fix' || 'perf' || 'revert' => Bump.patch,
      _ => null,
    };
  }
}

/// The size of a version change.
enum Bump {
  patch,
  minor,
  major;

  Bump max(Bump other) => index >= other.index ? this : other;
}

/// The changelog section for [version] built from [commits].
///
/// Commits that need no release, such as `docs:` or `chore:`, are left out.
String changelogSection(String version, List<ConventionalCommit> commits) {
  final groups = <String, List<String>>{
    'Breaking changes': [],
    'Features': [],
    'Fixes': [],
    'Performance': [],
  };
  for (final commit in commits) {
    final line = commit.scope == null || commit.scope!.isEmpty
        ? commit.description
        : '**${commit.scope}:** ${commit.description}';
    if (commit.breaking) {
      groups['Breaking changes']!.add(line);
    } else if (commit.type == 'feat') {
      groups['Features']!.add(line);
    } else if (commit.type == 'fix' || commit.type == 'revert') {
      groups['Fixes']!.add(line);
    } else if (commit.type == 'perf') {
      groups['Performance']!.add(line);
    }
  }

  final buffer = StringBuffer('## $version\n');
  for (final MapEntry(key: title, value: lines) in groups.entries) {
    if (lines.isEmpty) continue;
    buffer.write('\n### $title\n\n');
    for (final line in lines) {
      buffer.write('- $line\n');
    }
  }

  return buffer.toString();
}

/// Inserts [section] above the newest entry of [changelog].
///
/// A leading `# Title` line and any text before the first `## ` heading stay
/// at the top.
String prependSection(String changelog, String section) {
  if (changelog.trim().isEmpty) return '# Changelog\n\n$section';

  final lines = changelog.split('\n');
  final firstEntry = lines.indexWhere((line) => line.startsWith('## '));
  if (firstEntry == -1) {
    return '${changelog.trimRight()}\n\n$section';
  }
  final head = lines.take(firstEntry).join('\n').trimRight();
  final rest = lines.skip(firstEntry).join('\n');

  return head.isEmpty ? '$section\n$rest' : '$head\n\n$section\n$rest';
}

/// The body of the `## <version>` section of [changelog], or `null` when the
/// changelog has no such heading.
///
/// The heading may wrap the version in brackets, add a `v`, or add a date:
/// `## [1.2.0] - 2026-01-01`.
String? sectionFor(String changelog, String version) {
  final lines = changelog.split('\n');
  final heading = RegExp(
    '^##\\s+\\[?v?${RegExp.escape(version)}\\]?(?:\\s|\$)',
  );
  final start = lines.indexWhere(heading.hasMatch);
  if (start == -1) return null;
  final end = lines.indexWhere((line) => line.startsWith('## '), start + 1);

  return lines
      .sublist(start + 1, end == -1 ? lines.length : end)
      .join('\n')
      .trim();
}
