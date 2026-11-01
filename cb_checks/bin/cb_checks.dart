import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cb_checks/src/docs_check_command.dart';
import 'package:cb_checks/src/proto_optional_check_command.dart';

/// Run from the root of the repo being checked, which holds the paths below.
Future<void> main(List<String> args) async {
  final CommandRunner<int> runner = CommandRunner<int>('cb_checks', "Check a repo's docs and proto.")
    ..addCommand(DocsCheckCommand())
    ..addCommand(ProtoOptionalCheckCommand());

  try {
    exit(await runner.run(args) ?? 0);
  } on UsageException catch (error) {
    stderr.writeln(error);
    exit(64);
  }
}
