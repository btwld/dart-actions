import 'dart:io';

/// Environment variables that can mint or carry a pub.dev credential.
///
/// Validation commands run the caller's own code (tests, analyzers, build
/// hooks), so they never receive these.
const credentialVariables = {
  'ACTIONS_ID_TOKEN_REQUEST_URL',
  'ACTIONS_ID_TOKEN_REQUEST_TOKEN',
  'PUB_TOKEN',
};

/// A command that failed.
class CommandException implements Exception {
  CommandException(this.command, this.exitCode, this.output);

  final String command;
  final int exitCode;
  final String output;

  @override
  String toString() => '`$command` exited with $exitCode';
}

/// The process environment without [credentialVariables].
Map<String, String> uncredentialedEnvironment([
  Map<String, String> extra = const {},
]) => {
  for (final MapEntry(:key, :value) in Platform.environment.entries)
    if (!credentialVariables.contains(key)) key: value,
  ...extra,
};

/// Runs [executable] and returns its combined output.
///
/// The child never sees [credentialVariables] unless [credentialed] is set.
/// Output is echoed to stdout when [echo] is set. Throws a
/// [CommandException] on a non-zero exit unless [allowFailure] is set.
Future<({int exitCode, String output, String stdout})> run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool credentialed = false,
  Map<String, String> environment = const {},
  bool echo = true,
  bool allowFailure = false,
}) async {
  final command = [executable, ...arguments].join(' ');
  if (echo) stdout.writeln('\$ $command');
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    includeParentEnvironment: false,
    environment: credentialed
        ? {...Platform.environment, ...environment}
        : uncredentialedEnvironment(environment),
  );
  final output = '${result.stdout}${result.stderr}';
  if (echo && output.trim().isNotEmpty) stdout.writeln(output.trimRight());
  if (result.exitCode != 0 && !allowFailure) {
    throw CommandException(command, result.exitCode, output);
  }

  return (
    exitCode: result.exitCode,
    output: output,
    stdout: '${result.stdout}',
  );
}

/// Runs git and returns its trimmed standard output.
Future<String> git(
  List<String> arguments, {
  String? workingDirectory,
  bool echo = false,
}) async {
  final result = await run(
    'git',
    arguments,
    workingDirectory: workingDirectory,
    echo: echo,
  );

  return result.stdout.trim();
}
