import 'dart:io';

/// Whether [package] [version] is on pub.dev.
///
/// Only HTTP 404 means "not published". Any other failure throws, so a
/// release never skips or repeats an upload by mistake. [server] lets tests
/// use a local server.
Future<bool> isVersionPublished(
  String package,
  String version, {
  Uri? server,
}) async {
  final uri = (server ?? Uri.parse('https://pub.dev')).resolve(
    '/api/packages/${Uri.encodeComponent(package)}/versions/'
    '${Uri.encodeComponent(version)}',
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    final response = await request.close().timeout(const Duration(seconds: 15));
    await response.drain<void>().timeout(const Duration(seconds: 15));

    return switch (response.statusCode) {
      HttpStatus.ok => true,
      HttpStatus.notFound => false,
      final status => throw HttpException('Unexpected HTTP $status', uri: uri),
    };
  } finally {
    client.close(force: true);
  }
}

/// Waits until pub.dev serves [package] [version], so a dependent package
/// can resolve it.
Future<void> waitUntilPublished(
  String package,
  String version, {
  Duration interval = const Duration(seconds: 15),
  int attempts = 20,
  Uri? server,
}) async {
  for (var attempt = 1; attempt <= attempts; attempt++) {
    if (await isVersionPublished(package, version, server: server)) return;
    await Future<void>.delayed(interval);
  }
  throw StateError('pub.dev does not list $package $version yet.');
}

/// The warning and hint counts in a `pub publish --dry-run` summary, or
/// `null` when the output has no summary.
///
/// pub prints `Package has 0 warnings.` or
/// `Package has 0 warnings and 1 hint.` The last summary describes the
/// package that was validated.
({int warnings, int hints})? publishValidationCounts(String output) {
  final summaries = RegExp(r'Package has ([^.\n]*)\.').allMatches(output);
  if (summaries.isEmpty) return null;
  final summary = summaries.last.group(1)!;

  int countOf(String noun) {
    final match = RegExp('([0-9]+) ${noun}s?\\b').firstMatch(summary);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  return (warnings: countOf('warning'), hints: countOf('hint'));
}

/// Whether [package] has any version on pub.dev.
///
/// pub.dev automates uploads only for packages that exist, so the first
/// version of a new package must be published by hand.
Future<bool> isPackageOnPubDev(String package, {Uri? server}) async {
  final uri = (server ?? Uri.parse('https://pub.dev')).resolve(
    '/api/packages/${Uri.encodeComponent(package)}',
  );
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    final response = await request.close().timeout(const Duration(seconds: 15));
    await response.drain<void>().timeout(const Duration(seconds: 15));

    return switch (response.statusCode) {
      HttpStatus.ok => true,
      HttpStatus.notFound => false,
      final status => throw HttpException('Unexpected HTTP $status', uri: uri),
    };
  } finally {
    client.close(force: true);
  }
}
