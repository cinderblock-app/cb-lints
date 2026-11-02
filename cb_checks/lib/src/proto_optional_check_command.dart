import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

/// Fails when a proto edit would make old rows decode a field as its zero value,
/// unless someone has said what handles that.
///
/// Stored rows are protobuf blobs, and the generated decoder only guards a nullable
/// field with `hasX()`. So a required field that a row never wrote takes its zero
/// value: an `int64` timestamp becomes 1970, a `@Default(true)` bool becomes false,
/// an enum becomes its first value. It still compiles and the generated round-trip
/// test still passes, since that test encodes before it decodes. See "The proto is
/// a storage format" in CLAUDE.md. Two edits do this:
///
/// - A field that has been `optional` loses it. That needs a decoder.
/// - A required field appears on a message that already existed, which includes
///   renaming a field, as old rows hold the old number. That needs a decoder, or a
///   reason why the zero value is right. A field on a new message needs neither, as
///   no old row has that message.
///
/// Git history is not used because CI clones are shallow, so these are recorded in
/// a ledger next to the proto. `--update` only ever records what cannot lose data:
/// new optional fields, and new messages with their fields. It cannot hide either
/// edit. To retire a decoder once no older database can be opened, delete the field
/// from `compat` and `optional` by hand.
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
      ..addFlag(
        'update',
        negatable: false,
        help: 'Record new optional fields and new messages. On a ledger that has no messages yet, record everything.',
      );
  }

  @override
  String get name => 'proto-optional-check';

  @override
  String get description => 'Verify no proto edit decodes old rows as zero values without saying what handles it.';

  @override
  Future<int> run() async {
    final File ledgerFile = File(argResults!.option('ledger')!);
    final ProtoFields fields = parseProtoFields(File(argResults!.option('proto')!).readAsStringSync());
    final OptionalLedger ledger = OptionalLedger.parse(ledgerFile.readAsStringSync());

    final OptionalLedger updated = argResults!.flag('update') ? ledger.updatedFrom(fields) : ledger;
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
    stdout.writeln(
      'proto-optional-check: ${fields.optional.length} optional and ${fields.required.length} required fields, '
      'none unhandled.',
    );
    return 0;
  }
}

/// The fields a proto declares, as `Message.field_name`.
class ProtoFields {
  const ProtoFields({required this.messages, required this.optional, required this.required});

  final Set<String> messages;

  final Set<String> optional;

  /// Singular fields without `optional`. Lists and maps have no presence, and
  /// their declarations do not match [_field], so they are in neither set.
  final Set<String> required;
}

final RegExp _message = RegExp(r'^message (\w+)');
final RegExp _field = RegExp(r'^\s+(optional\s+)?([\w.]+)\s+(\w+)\s*=\s*\d+\s*;');

ProtoFields parseProtoFields(String proto) {
  final Set<String> messages = <String>{};
  final Set<String> optional = <String>{};
  final Set<String> required = <String>{};

  String? message;
  for (final String line in const LineSplitter().convert(proto)) {
    final RegExpMatch? start = _message.firstMatch(line);
    if (start != null) {
      message = start.group(1);
      messages.add(message!);
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

  return ProtoFields(messages: messages, optional: optional, required: required);
}

/// What the proto has held, and what handles the fields old rows do not have.
class OptionalLedger {
  const OptionalLedger({
    required this.optional,
    required this.compat,
    this.messages = const <String>{},
    this.required = const <String>{},
    this.zeroValueOk = const <String, String>{},
  });

  factory OptionalLedger.parse(String json) {
    final Map<String, dynamic> data = jsonDecode(json) as Map<String, dynamic>;
    Set<String> names(String key) => <String>{...?(data[key] as List<dynamic>?)?.cast<String>()};
    Map<String, String> entries(String key) => <String, String>{
      ...?(data[key] as Map<String, dynamic>?)?.cast<String, String>(),
    };
    return OptionalLedger(
      optional: names('optional'),
      compat: entries('compat'),
      messages: names('messages'),
      required: names('required'),
      zeroValueOk: entries('zero_value_ok'),
    );
  }

  /// Every field that has been `optional`.
  final Set<String> optional;

  /// Field to the name of the function in entity_converters.dart that decodes the
  /// rows written before it was required.
  final Map<String, String> compat;

  /// Every message the proto has held.
  final Set<String> messages;

  /// The required fields that were there from the start, or came with a new message.
  final Set<String> required;

  /// Field to why its zero value is right for rows written before it existed.
  final Map<String, String> zeroValueOk;

  /// This ledger with what cannot lose data recorded: new optional fields, and new
  /// messages with their required fields. A required field on a known message stays
  /// out, so that it keeps failing until someone handles it.
  ///
  /// A ledger with no messages has recorded nothing to compare with, so everything
  /// is recorded, once.
  OptionalLedger updatedFrom(ProtoFields fields) {
    final bool first = messages.isEmpty;
    return OptionalLedger(
      optional: <String>{...optional, ...fields.optional},
      compat: compat,
      messages: <String>{...messages, ...fields.messages},
      required: <String>{
        ...required,
        ...fields.required.where((String it) => first || !messages.contains(it.split('.').first)),
      },
      zeroValueOk: zeroValueOk,
    );
  }

  String encode() {
    List<String> sorted(Iterable<String> names) => names.toList()..sort();
    Map<String, String> sortedEntries(Map<String, String> entries) {
      return <String, String>{for (final String key in sorted(entries.keys)) key: entries[key]!};
    }

    final Map<String, Object> data = <String, Object>{
      'compat': sortedEntries(compat),
      'zero_value_ok': sortedEntries(zeroValueOk),
      'messages': sorted(messages),
      'optional': sorted(optional),
      'required': sorted(required),
    };
    return '${const JsonEncoder.withIndent('  ').convert(data)}\n';
  }
}

const String _update = 'fvm dart run tool/bin/tools.dart proto-optional-check --update';

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
      'Run: $_update',
    );
  }

  final Set<String> newMessages = fields.messages.difference(ledger.messages);
  if (newMessages.isNotEmpty) {
    problems.add(
      '${newMessages.length} messages are not in the ledger (${(newMessages.toList()..sort()).take(5).join(', ')}). '
      'Run: $_update',
    );
  }

  final List<String> required = fields.required.toList()..sort();
  for (final String field in required) {
    final bool wasOptional = ledger.optional.contains(field);
    if (!wasOptional && ledger.required.contains(field)) {
      continue;
    }
    if (!wasOptional && newMessages.contains(field.split('.').first)) {
      continue;
    }
    final String? decoder = ledger.compat[field];
    if (decoder != null) {
      if (!_isDecoderOf(decoder, field.split('.').first, converters)) {
        problems.add(
          '$field names $decoder as its decoder, but no ProtoEntityConverter<${field.split('.').first}> '
          'in entity_converters.dart uses it.',
        );
      }
    } else if (wasOptional) {
      problems.add(
        '$field lost `optional`, so rows that never wrote it decode as its zero value. Keep it optional, '
        'or add a decoder to entity_converters.dart and name it under "compat" in the ledger '
        '(see _decodeInvoiceCompat and "The proto is a storage format" in CLAUDE.md).',
      );
    } else if (!ledger.zeroValueOk.containsKey(field)) {
      problems.add(
        '$field is a new required field on a message that already has rows, which decode it as its zero '
        '(0, "", false, 1970, the first enum value). Make it optional, or name a decoder under "compat", or '
        'if the zero value is right, say why under "zero_value_ok" in the ledger. A renamed field counts: old '
        'rows hold the old number.',
      );
    }
  }

  final List<String> staleCompat = ledger.compat.keys.where((String it) => !fields.required.contains(it)).toList()
    ..sort();
  for (final String field in staleCompat) {
    problems.add('$field is under "compat" in the ledger but is not a required field. Remove the entry.');
  }
  final List<String> staleZero = ledger.zeroValueOk.keys.where((String it) => !fields.required.contains(it)).toList()
    ..sort();
  for (final String field in staleZero) {
    problems.add('$field is under "zero_value_ok" in the ledger but is not a required field. Remove the entry.');
  }

  return problems;
}

bool _isDecoderOf(String decoder, String message, String converters) {
  final String code = converters.replaceAll(RegExp(r'//.*'), '');
  return RegExp('ProtoEntityConverter<${RegExp.escape(message)}>\\(\\s*${RegExp.escape(decoder)}\\s*,').hasMatch(code);
}
