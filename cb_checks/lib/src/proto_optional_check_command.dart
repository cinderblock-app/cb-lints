import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

/// Fails when a proto field that has been `optional` no longer is, unless a
/// decoder handles the rows written before the change.
///
/// Stored rows are protobuf blobs, so a field that loses `optional` decodes as
/// its zero value in every row that never wrote it: an `int64` timestamp becomes
/// 1970. It still compiles and the generated round-trip test still passes, since
/// that test encodes before it decodes. See "The proto is a storage format" in
/// CLAUDE.md.
///
/// Git history is not used because CI clones are shallow, so the fields are
/// recorded in a ledger next to the proto. `--update` only ever adds
/// optional fields to it, so it cannot hide a dropped one. To retire a decoder
/// once no older database can be opened, delete the field from both of the
/// ledger's sections by hand.
class ProtoOptionalCheckCommand extends Command<int> {
  ProtoOptionalCheckCommand() {
    argParser
      ..addOption('proto', defaultsTo: 'lib/src/data/sync_engine/proto/cinderblock.proto', help: 'Path to the proto.')
      ..addOption(
        'ledger',
        defaultsTo: 'lib/src/data/sync_engine/proto/optional_fields.json',
        help: 'Path to the ledger of fields that have been optional.',
      )
      ..addOption(
        'converters',
        defaultsTo: 'lib/src/data/sync_engine/persistence/entity_converters.dart',
        help: 'Path to the file declaring the entity converters.',
      )
      ..addFlag('update', negatable: false, help: 'Add optional fields missing from the ledger.');
  }

  @override
  String get name => 'proto-optional-check';

  @override
  String get description => 'Verify no proto field loses `optional` without a decoder for old rows.';

  @override
  Future<int> run() async {
    final File ledgerFile = File(argResults!.option('ledger')!);
    final ProtoFields fields = parseProtoFields(File(argResults!.option('proto')!).readAsStringSync());
    final OptionalLedger ledger = OptionalLedger.parse(ledgerFile.readAsStringSync());

    final OptionalLedger updated = argResults!.flag('update') ? ledger.including(fields.optional) : ledger;
    if (argResults!.flag('update')) {
      ledgerFile.writeAsStringSync(updated.encode());
    }

    final List<String> problems = checkOptionalFields(
      fields: fields,
      ledger: updated,
      converters: File(argResults!.option('converters')!).readAsStringSync(),
    );
    for (final String problem in problems) {
      stderr.writeln(problem);
    }
    if (problems.isNotEmpty) {
      return 1;
    }
    stdout.writeln('proto-optional-check: ${fields.optional.length} optional fields, none dropped unhandled.');
    return 0;
  }
}

/// The fields a proto declares, as `Message.field_name`.
class ProtoFields {
  const ProtoFields({required this.optional, required this.required});

  final Set<String> optional;

  /// Singular fields without `optional`. Lists and maps have no presence, and
  /// their declarations do not match [_field], so they are in neither set.
  final Set<String> required;
}

final RegExp _message = RegExp(r'^message (\w+)');
final RegExp _field = RegExp(r'^\s+(optional\s+)?([\w.]+)\s+(\w+)\s*=\s*\d+\s*;');

ProtoFields parseProtoFields(String proto) {
  final Set<String> optional = <String>{};
  final Set<String> required = <String>{};

  String? message;
  for (final String line in const LineSplitter().convert(proto)) {
    final RegExpMatch? start = _message.firstMatch(line);
    if (start != null) {
      message = start.group(1);
      continue;
    }
    if (line.startsWith('}')) {
      message = null;
      continue;
    }
    if (message == null) {
      continue;
    }
    final RegExpMatch? field = _field.firstMatch(line);
    if (field == null) {
      continue;
    }
    (field.group(1) == null ? required : optional).add('$message.${field.group(3)}');
  }

  return ProtoFields(optional: optional, required: required);
}

/// Every field that has been `optional`, and the decoders that handle the ones
/// that no longer are.
class OptionalLedger {
  const OptionalLedger({required this.optional, required this.compat});

  factory OptionalLedger.parse(String json) {
    final Map<String, dynamic> data = jsonDecode(json) as Map<String, dynamic>;
    return OptionalLedger(
      optional: (data['optional'] as List<dynamic>).cast<String>().toSet(),
      compat: (data['compat'] as Map<String, dynamic>).cast<String, String>(),
    );
  }

  final Set<String> optional;

  /// Field to the name of the function in entity_converters.dart that decodes
  /// the rows written while it was optional.
  final Map<String, String> compat;

  OptionalLedger including(Set<String> fields) {
    return OptionalLedger(optional: <String>{...optional, ...fields}, compat: compat);
  }

  String encode() {
    final List<String> sortedFields = optional.toList()..sort();
    final List<String> sortedCompat = compat.keys.toList()..sort();
    final Map<String, Object> data = <String, Object>{
      'compat': <String, String>{for (final String field in sortedCompat) field: compat[field]!},
      'optional': sortedFields,
    };
    return '${const JsonEncoder.withIndent('  ').convert(data)}\n';
  }
}

List<String> checkOptionalFields({
  required ProtoFields fields,
  required OptionalLedger ledger,
  required String converters,
}) {
  final List<String> problems = <String>[];

  final List<String> unrecorded = fields.optional.difference(ledger.optional).toList()..sort();
  if (unrecorded.isNotEmpty) {
    problems.add(
      '${unrecorded.length} optional fields are not in the ledger (${unrecorded.take(5).join(', ')}). '
      'Run: tools/cb_checks.sh proto-optional-check --update',
    );
  }

  final List<String> dropped = ledger.optional.intersection(fields.required).toList()..sort();
  for (final String field in dropped) {
    final String? decoder = ledger.compat[field];
    if (decoder == null) {
      problems.add(
        '$field lost `optional`, so rows that never wrote it decode as its zero value. Keep it optional, '
        'or add a decoder to entity_converters.dart and name it under "compat" in the ledger '
        '(see _decodeInvoiceCompat and "The proto is a storage format" in CLAUDE.md).',
      );
    } else if (!_isDecoderOf(decoder, field.split('.').first, converters)) {
      problems.add(
        '$field names $decoder as its decoder, but no ProtoEntityConverter<${field.split('.').first}> '
        'in entity_converters.dart uses it.',
      );
    }
  }

  final List<String> stale = ledger.compat.keys.where((String it) => !fields.required.contains(it)).toList()..sort();
  for (final String field in stale) {
    problems.add('$field is under "compat" in the ledger but is not a required field. Remove the entry.');
  }

  return problems;
}

bool _isDecoderOf(String decoder, String message, String converters) {
  final String code = converters.replaceAll(RegExp(r'//.*'), '');
  return RegExp('ProtoEntityConverter<${RegExp.escape(message)}>\\(\\s*${RegExp.escape(decoder)}\\s*,').hasMatch(code);
}
