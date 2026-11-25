import 'package:pub_semver/pub_semver.dart';

import 'changelog.dart';

/// The next version after [current] for a change of size [bump].
///
/// - A prerelease stays on its release line: `2.0.0-beta.3` becomes
///   `2.0.0-beta.4`. Leave a prerelease line by passing an explicit version.
/// - Before 1.0.0, a breaking change bumps the minor number and any other
///   change bumps the patch number, as the Dart package conventions describe.
/// - From 1.0.0, the usual SemVer rules apply.
String nextVersion(String current, Bump bump) {
  final version = Version.parse(current);
  if (version.isPreRelease) return _nextPreRelease(version).toString();
  if (version.major == 0) {
    return (bump == Bump.major ? version.nextMinor : version.nextPatch)
        .toString();
  }

  return switch (bump) {
    Bump.major => version.nextMajor,
    Bump.minor => version.nextMinor,
    Bump.patch => version.nextPatch,
  }.toString();
}

Version _nextPreRelease(Version version) {
  final parts = [...version.preRelease];
  final lastNumber = parts.lastIndexWhere((part) => part is int);
  if (lastNumber == -1) {
    parts.add(1);
  } else {
    parts[lastNumber] = (parts[lastNumber] as int) + 1;
  }

  return Version(
    version.major,
    version.minor,
    version.patch,
    pre: parts.join('.'),
  );
}

/// The highest version in [versions], or `null` when it is empty.
String? highestVersion(Iterable<String> versions) {
  Version? highest;
  for (final raw in versions) {
    final Version version;
    try {
      version = Version.parse(raw);
    } on FormatException {
      continue;
    }
    if (highest == null || version > highest) highest = version;
  }

  return highest?.toString();
}

/// Whether [version] is a valid SemVer version.
bool isVersion(String version) {
  try {
    Version.parse(version);
    return true;
  } on FormatException {
    return false;
  }
}

/// Whether [version] is a prerelease, such as `1.0.0-beta.1`.
bool isPreRelease(String version) => Version.parse(version).isPreRelease;

/// Whether [a] is a higher version than [b].
bool isHigher(String a, String b) => Version.parse(a) > Version.parse(b);
