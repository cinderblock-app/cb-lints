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
/// new optional fields, new messages with their fields, and removed required
/// fields, so that adding one back counts as new. It cannot hide either edit. A
/// message that disappears fails until it is deleted from the ledger by hand, as
/// renaming one keeps its rows. To retire a decoder once no older database can be
/// opened, delete the field from `compat` and `optional`, and add it to `required`.
///
/// A decoder on a table's converter does not reach a copy of that message embedded
/// in another blob, such as the entities inside a queued operation. This cannot see
/// that, nor whether the decoder touches the field: it only asks that one exists.
class ProtoOptionalCheckCommand extends Command<int> {
  ProtoOptionalCheckCommand() {
    argParser
      ..addOption('proto', defaultsTo: 'lib/src/data/sync_engine/proto/cinderblock.proto', help: 'Path to the proto.')
      ..addOption(
        'ledger',
        defaultsTo: 'lib/src/data/sync_engine/proto/optional_fields.json',
        help: 'Path to the ledger of what the proto has held.',
      )
      ..addOption(
        'converters',
        defaultsTo: 'lib/src/data/sync_engine/persistence/entity_converters.dart',
        help: 'Path to the file declaring the entity converters.',
      )
      ..addFlag(
        'init',
        negatable: false,
        help: 'Record everything in the proto as it is, on a ledger that has no messages yet. Once per ledger.',
      )
      ..addFlag(
        'update',
        negatable: false,
        help: 'Record new optional fields, new messages, and removed required fields.',
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
    final bool init = argResults!.flag('init');

    final OptionalLedger ledger;
    try {
      ledger = OptionalLedger.parse(ledgerFile.readAsStringSync(), partial: init);
    } on FormatException catch (error) {
      stderr.writeln('${ledgerFile.path}: ${error.message}');
      return 1;
    }
    if (init && ledger.messages.isNotEmpty) {
      stderr.writeln('${ledgerFile.path} already has messages. --init would accept everything in the proto as it is.');
      return 1;
    }

    final OptionalLedger updated = init
        ? ledger.initializedFrom(fields)
        : argResults!.flag('update')
        ? ledger.updatedFrom(fields)
        : ledger;
    if (init || argResults!.flag('update')) {
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
final RegExp _oneof = RegExp(r'^\s+oneof \w+\s*\{');
final RegExp _field = RegExp(r'^\s+(optional\s+)?([\w.]+)\s+(\w+)\s*=\s*\d+\s*;');

ProtoFields parseProtoFields(String proto) {
  final Set<String> messages = <String>{};
  final Set<String> optional = <String>{};
  final Set<String> required = <String>{};

  String? message;
  bool inOneof = false;
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
    // An arm that a row never wrote decodes as not set, not as a zero, and `optional`
    // cannot be written on one.
    if (_oneof.hasMatch(line)) {
      inOneof = true;
      continue;
    }
    if (inOneof) {
      inOneof = !line.trim().startsWith('}');
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

  /// Throws a [FormatException] on a missing section, unless [partial]: an empty
  /// section means nothing to compare with, so a lost one must not pass for that.
  factory OptionalLedger.parse(String json, {bool partial = false}) {
    final Map<String, dynamic> data = jsonDecode(json) as Map<String, dynamic>;
    T? section<T>(String key) {
      if (!partial && !data.containsKey(key)) {
        throw FormatException('the ledger has no "$key" section');
      }
      return data[key] as T?;
    }

    Set<String> names(String key) => <String>{...?section<List<dynamic>>(key)?.cast<String>()};
    Map<String, String> entries(String key) => <String, String>{
      ...?section<Map<String, dynamic>>(key)?.cast<String, String>(),
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

  /// This ledger with everything in [fields] accepted as it is.
  OptionalLedger initializedFrom(ProtoFields fields) {
    return OptionalLedger(
      optional: <String>{...optional, ...fields.optional},
      compat: compat,
      messages: <String>{...messages, ...fields.messages},
      required: <String>{...required, ...fields.required},
      zeroValueOk: zeroValueOk,
    );
  }

  /// This ledger with what cannot lose data recorded: new optional fields, new
  /// messages with their required fields, and removed required fields. A required
  /// field on a known message stays out, so that it keeps failing until someone
  /// handles it.
  OptionalLedger updatedFrom(ProtoFields fields) {
    return OptionalLedger(
      optional: <String>{...optional, ...fields.optional},
      compat: compat,
      messages: <String>{...messages, ...fields.messages},
      required: <String>{
        ...required.intersection(fields.required),
        ...fields.required.where((String it) => !messages.contains(it.split('.').first)),
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

  final List<String> goneMessages = ledger.messages.difference(fields.messages).toList()..sort();
  for (final String message in goneMessages) {
    problems.add(
      'Message $message is gone. If it was renamed, its rows are still there and decode through the new name, so '
      'its new fields need handling. Either way, delete it from "messages" in the ledger by hand.',
    );
  }

  final List<String> gone = ledger.required.difference(fields.required).toList()..sort();
  if (gone.isNotEmpty) {
    problems.add(
      '${gone.length} required fields in the ledger are gone (${gone.take(5).join(', ')}), and adding one back must '
      'count as new. Run: $_update',
    );
  }

  final List<String> required = fields.required.toList()..sort();
  for (final String field in required) {
    final bool wasOptional = ledger.optional.contains(field);
    if (ledger.compat.containsKey(field) ||
        (!wasOptional && (ledger.required.contains(field) || newMessages.contains(field.split('.').first)))) {
      continue;
    }
    if (wasOptional) {
      problems.add(
        '$field lost `optional`, so rows that never wrote it decode as its zero value. Keep it optional, '
        'or add a decoder to entity_converters.dart and name it under "compat" in the ledger '
        '(see _decodeInvoiceCompat and "The proto is a storage format" in CLAUDE.md).',
      );
    } else if ((ledger.zeroValueOk[field] ?? '').trim().isEmpty) {
      problems.add(
        '$field is a new required field on a message that already has rows, which decode it as its zero '
        '(0, "", false, 1970, the first enum value). Make it optional, or name a decoder under "compat", or '
        'if the zero value is right, say why under "zero_value_ok" in the ledger. A renamed field counts: old '
        'rows hold the old number. If the message has never shipped, add the field to "required" instead.',
      );
    }
  }

  final List<String> decoders = ledger.compat.keys.toList()..sort();
  for (final String field in decoders) {
    final String message = field.split('.').first;
    if (!fields.required.contains(field)) {
      problems.add('$field is under "compat" in the ledger but is not a required field. Remove the entry.');
    } else if (!_isDecoderOf(ledger.compat[field]!, message, converters)) {
      problems.add(
        '$field names ${ledger.compat[field]} as its decoder, but no ProtoEntityConverter in entity_converters.dart '
        "uses it for $message: on its own converter, or on a parent's whose decoder names it.",
      );
    }
  }
  final List<String> staleZero = ledger.zeroValueOk.keys.where((String it) => !fields.required.contains(it)).toList()
    ..sort();
  for (final String field in staleZero) {
    problems.add('$field is under "zero_value_ok" in the ledger but is not a required field. Remove the entry.');
  }

  return problems;
}

/// Whether a converter uses [decoder], and it is for [message]: on that message's
/// own converter, or on a parent's, as a message stored inside another is decoded
/// by the parent's, whose body then has to name it.
bool _isDecoderOf(String decoder, String message, String converters) {
  final String code = converters.replaceAll(RegExp(r'//.*'), '');
  final String name = RegExp.escape(decoder);
  if (RegExp('ProtoEntityConverter<${RegExp.escape(message)}>\\(\\s*$name\\s*,').hasMatch(code)) {
    return true;
  }
  if (!RegExp('ProtoEntityConverter<\\w+>\\(\\s*$name\\s*,').hasMatch(code)) {
    return false;
  }
  final RegExpMatch? body = RegExp('\\b$name\\([^)]*\\)\\s*(\\{.*?\\n\\}|=>.*?;)', dotAll: true).firstMatch(code);
  return body != null && RegExp('\\b${RegExp.escape(message)}\\b').hasMatch(body.group(1)!);
}
