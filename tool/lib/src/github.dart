import 'dart:convert';
import 'dart:io';

/// Writes `name=value` to the step outputs, or prints it outside Actions.
void setOutput(String name, String value) {
  final path = Platform.environment['GITHUB_OUTPUT'];
  if (path == null || path.isEmpty) {
    stdout.writeln('output $name=$value');
    return;
  }
  final delimiter = 'EOF_${DateTime.now().microsecondsSinceEpoch}';
  File(path).writeAsStringSync(
    '$name<<$delimiter\n$value\n$delimiter\n',
    mode: FileMode.append,
  );
}

/// Appends [markdown] to the job summary, when there is one.
void addSummary(String markdown) {
  final path = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (path == null || path.isEmpty) return;
  File(path).writeAsStringSync('$markdown\n', mode: FileMode.append);
}

/// Prints a workflow notice.
void notice(String message) => stdout.writeln('::notice::$message');

/// Prints a workflow warning.
void warning(String message) => stdout.writeln('::warning::$message');

/// Requests a GitHub OIDC token for pub.dev.
///
/// The job must grant `id-token: write`. The token is short-lived and is
/// requested immediately before each upload.
Future<String> requestPubDevIdToken() async {
  final url = Platform.environment['ACTIONS_ID_TOKEN_REQUEST_URL'];
  final token = Platform.environment['ACTIONS_ID_TOKEN_REQUEST_TOKEN'];
  if (url == null || url.isEmpty || token == null || token.isEmpty) {
    throw StateError(
      'No OIDC token is available. The publish job needs '
      '`permissions: id-token: write`.',
    );
  }

  final uri = Uri.parse(url).replace(
    queryParameters: {
      ...Uri.parse(url).queryParameters,
      'audience': 'https://pub.dev',
    },
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'OIDC token request failed with HTTP ${response.statusCode}',
      );
    }
    final value = (jsonDecode(body) as Map<String, dynamic>)['value'];
    if (value is! String || value.isEmpty) {
      throw const FormatException('The OIDC response has no token value.');
    }
    stdout.writeln('::add-mask::$value');

    return value;
  } finally {
    client.close(force: true);
  }
}
