import 'package:cb_checks/src/proto_optional_check_command.dart';
import 'package:test/test.dart';

const String _proto = '''
syntax = "proto3";

enum Status {
  STATUS_OPEN = 0;
}

message Invoice {
  string id = 1;
  optional int64 paid_at = 2;
  int64 due_date = 3;
  repeated string tags = 4;
  map<string, string> extras = 5;
  reserved 6, 7;
  oneof payload {
    string text = 8;
  }
}

message Note {
  optional string body = 1;
}
''';

const String _converters = '''
Invoice _decodeInvoiceCompat(List<int> bytes) => decodeInvoice(bytes);

const ProtoEntityConverter<Invoice> invoice\$ = ProtoEntityConverter<Invoice>(
  _decodeInvoiceCompat,
  encodeInvoice,
);
''';

const Set<String> _messages = <String>{'Invoice', 'Note'};
const Set<String> _optional = <String>{'Invoice.paid_at', 'Note.body'};
const Set<String> _required = <String>{'Invoice.id', 'Invoice.due_date'};

List<String> _check({
  Set<String> messages = _messages,
  Set<String> optional = _optional,
  Set<String> required = _required,
  Map<String, String> compat = const <String, String>{},
  Map<String, String> zeroValueOk = const <String, String>{},
  String converters = _converters,
}) {
  return checkOptionalFields(
    fields: parseProtoFields(_proto),
    ledger: OptionalLedger(
      messages: messages,
      optional: optional,
      required: required,
      compat: compat,
      zeroValueOk: zeroValueOk,
    ),
    converters: converters,
  );
}

void main() {
  group('parseProtoFields', () {
    test('splits singular fields by presence, per message', () {
      final ProtoFields fields = parseProtoFields(_proto);

      expect(fields.messages, _messages);
      expect(fields.optional, _optional);
      expect(fields.required, _required);
    });

    test('counts a oneof arm as neither, and resumes after the oneof', () {
      final ProtoFields fields = parseProtoFields('''
message Op {
  string id = 1;
  oneof value {
    string text = 2;
    Other other = 3;
  }
  string after = 4;
}
''');

      expect(fields.required, <String>{'Op.id', 'Op.after'});
    });
  });

  group('a field that lost optional', () {
    const Set<String> required = <String>{'Invoice.id'};
    const Set<String> optional = <String>{..._optional, 'Invoice.due_date'};

    test('fails', () {
      final List<String> problems = _check(optional: optional, required: required);

      expect(problems.single, startsWith('Invoice.due_date lost `optional`'));
    });

    test('fails even if a reason says the zero value is fine, as it needs a decoder', () {
      final List<String> problems = _check(
        optional: optional,
        required: required,
        zeroValueOk: const <String, String>{'Invoice.due_date': 'it is fine'},
      );

      expect(problems.single, startsWith('Invoice.due_date lost `optional`'));
    });

    test('passes when a converter uses the named decoder', () {
      final List<String> problems = _check(
        optional: optional,
        required: required,
        compat: const <String, String>{'Invoice.due_date': '_decodeInvoiceCompat'},
      );

      expect(problems, isEmpty);
    });

    test('fails when no converter uses the named decoder', () {
      final List<String> problems = _check(
        optional: optional,
        required: required,
        compat: const <String, String>{'Invoice.due_date': '_decodeElsewhere'},
      );

      expect(problems.single, contains('_decodeElsewhere'));
    });

    test('fails when the decoder belongs to another message', () {
      final List<String> problems = _check(
        optional: optional,
        required: required,
        compat: const <String, String>{'Invoice.due_date': '_decodeNote'},
        converters: 'const ProtoEntityConverter<Note> note = ProtoEntityConverter<Note>(_decodeNote, encodeNote);',
      );

      expect(problems.single, contains('for Invoice'));
    });

    test('passes on a parent\'s converter whose decoder names the message', () {
      const String parent = '''
Operation _decodeOperationCompat(List<int> bytes) {
  final Operation operation = decodeOperation(bytes);
  return switch (operation.info) {
    final Invoice info when info.dueDate == 0 => operation.copyWith(info: info),
    _ => operation,
  };
}

const ProtoEntityConverter<Operation> operation\$ = ProtoEntityConverter<Operation>(
  _decodeOperationCompat,
  encodeOperation,
);
''';
      final List<String> problems = _check(
        optional: optional,
        required: required,
        compat: const <String, String>{'Invoice.due_date': '_decodeOperationCompat'},
        converters: parent,
      );

      expect(problems, isEmpty);
    });

    test('fails on a parent\'s converter whose decoder does not name the message', () {
      const String parent = '''
Operation _decodeOperationCompat(List<int> bytes) {
  return decodeOperation(bytes);
}

const ProtoEntityConverter<Operation> operation\$ = ProtoEntityConverter<Operation>(
  _decodeOperationCompat,
  encodeOperation,
);
''';
      final List<String> problems = _check(
        optional: optional,
        required: required,
        compat: const <String, String>{'Invoice.due_date': '_decodeOperationCompat'},
        converters: parent,
      );

      expect(problems.single, contains('for Invoice'));
    });

    test('does not count a commented-out converter', () {
      final List<String> problems = _check(
        optional: optional,
        required: required,
        compat: const <String, String>{'Invoice.due_date': '_decodeInvoice'},
        converters: '// ProtoEntityConverter<Invoice>(_decodeInvoice, encodeInvoice)',
      );

      expect(problems.single, contains('_decodeInvoice'));
    });
  });

  group('a new required field on a known message', () {
    const Set<String> required = <String>{'Invoice.id'};

    test('fails', () {
      final List<String> problems = _check(required: required);

      expect(problems.single, startsWith('Invoice.due_date is a new required field'));
    });

    test('fails when it is a rename of an optional field', () {
      final List<String> problems = _check(
        optional: const <String>{..._optional, 'Invoice.due_on'},
        required: required,
      );

      expect(problems.single, startsWith('Invoice.due_date is a new required field'));
    });

    test('passes with a reason', () {
      expect(_check(required: required, zeroValueOk: const <String, String>{'Invoice.due_date': 'why'}), isEmpty);
    });

    test('passes with a decoder', () {
      final List<String> problems = _check(
        required: required,
        compat: const <String, String>{'Invoice.due_date': '_decodeInvoiceCompat'},
      );

      expect(problems, isEmpty);
    });
  });

  group('the rest of the ledger', () {
    test('passes when it matches', () {
      expect(_check(), isEmpty);
    });

    test('fails on an optional field it does not hold', () {
      final List<String> problems = _check(optional: const <String>{'Invoice.paid_at'});

      expect(problems.single, contains('Note.body'));
      expect(problems.single, contains('--update'));
    });

    test('asks for an update on a new message, without calling its fields unhandled', () {
      final List<String> problems = _check(
        messages: const <String>{'Note'},
        required: const <String>{},
        optional: const <String>{'Note.body', 'Invoice.paid_at'},
      );

      expect(problems.single, contains('1 messages are not in the ledger (Invoice)'));
    });

    test('fails on an entry for a field that is not required', () {
      expect(
        _check(compat: const <String, String>{'Note.body': '_decodeInvoiceCompat'}).single,
        startsWith('Note.body is under "compat"'),
      );
      expect(
        _check(zeroValueOk: const <String, String>{'Note.body': 'why'}).single,
        startsWith('Note.body is under "zero_value_ok"'),
      );
    });

    test('ignores a removed optional field, which is flagged if it comes back required', () {
      expect(_check(optional: const <String>{..._optional, 'Invoice.gone'}), isEmpty);
    });

    test('asks for an update on a removed required field', () {
      final List<String> problems = _check(required: const <String>{..._required, 'Invoice.gone'});

      expect(problems.single, contains('Invoice.gone'));
      expect(problems.single, contains('--update'));
    });

    test('fails on a message that is gone', () {
      expect(_check(messages: const <String>{..._messages, 'Vendor'}).single, startsWith('Message Vendor is gone'));
    });

    test('fails on a recorded field whose decoder is not used', () {
      final List<String> problems = _check(compat: const <String, String>{'Invoice.id': '_decodeDeleted'});

      expect(problems.single, contains('_decodeDeleted'));
    });

    test('does not take an empty reason', () {
      final List<String> problems = _check(
        required: const <String>{'Invoice.id'},
        zeroValueOk: const <String, String>{'Invoice.due_date': ' '},
      );

      expect(problems.single, startsWith('Invoice.due_date is a new required field'));
    });
  });

  group('updatedFrom', () {
    final ProtoFields fields = parseProtoFields(_proto);

    test('records a new message with its fields', () {
      final OptionalLedger ledger = const OptionalLedger(
        messages: <String>{'Note'},
        optional: <String>{'Note.body'},
        compat: <String, String>{},
      ).updatedFrom(fields);

      expect(ledger.messages, _messages);
      expect(ledger.required, _required);
      expect(ledger.optional, _optional);
    });

    test('drops a removed required field, so that adding it back counts as new', () {
      final OptionalLedger ledger = const OptionalLedger(
        messages: _messages,
        optional: _optional,
        required: <String>{..._required, 'Invoice.gone'},
        compat: <String, String>{},
      ).updatedFrom(fields);

      expect(ledger.required, _required);
    });

    test('initializedFrom accepts everything', () {
      final OptionalLedger ledger = const OptionalLedger(
        optional: <String>{},
        compat: <String, String>{},
      ).initializedFrom(fields);

      expect(ledger.messages, _messages);
      expect(ledger.required, _required);
      expect(checkOptionalFields(fields: fields, ledger: ledger, converters: _converters), isEmpty);
    });

    test('cannot hide a new required field on a known message', () {
      final OptionalLedger ledger = const OptionalLedger(
        messages: _messages,
        optional: _optional,
        required: <String>{'Invoice.id'},
        compat: <String, String>{},
      ).updatedFrom(fields);

      expect(ledger.required, isNot(contains('Invoice.due_date')));
      expect(
        checkOptionalFields(fields: fields, ledger: ledger, converters: _converters).single,
        startsWith('Invoice.due_date is a new required field'),
      );
    });

    test('cannot hide a field that lost optional', () {
      final OptionalLedger ledger = const OptionalLedger(
        messages: _messages,
        optional: <String>{..._optional, 'Invoice.due_date'},
        required: <String>{'Invoice.id'},
        compat: <String, String>{},
      ).updatedFrom(fields);

      expect(
        checkOptionalFields(fields: fields, ledger: ledger, converters: _converters).single,
        startsWith('Invoice.due_date lost `optional`'),
      );
    });
  });

  group('OptionalLedger', () {
    test('round-trips, sorted', () {
      const OptionalLedger ledger = OptionalLedger(
        messages: <String>{'B', 'A'},
        optional: <String>{'B.b', 'A.a'},
        required: <String>{'B.c', 'A.c'},
        compat: <String, String>{'A.a': '_decode'},
        zeroValueOk: <String, String>{'B.c': 'why'},
      );

      final String encoded = ledger.encode();
      final OptionalLedger parsed = OptionalLedger.parse(encoded);

      expect(encoded.indexOf('A.a"\n'), lessThan(encoded.indexOf('B.b"')));
      expect(parsed.messages, ledger.messages);
      expect(parsed.optional, ledger.optional);
      expect(parsed.required, ledger.required);
      expect(parsed.compat, ledger.compat);
      expect(parsed.zeroValueOk, ledger.zeroValueOk);
    });

    test('refuses a ledger missing a section, as an empty one would pass for it', () {
      expect(() => OptionalLedger.parse('{"compat": {}, "optional": ["A.a"]}'), throwsFormatException);
    });

    test('reads a partial ledger when asked, for --init', () {
      final OptionalLedger ledger = OptionalLedger.parse('{"compat": {}, "optional": ["A.a"]}', partial: true);

      expect(ledger.optional, <String>{'A.a'});
      expect(ledger.messages, isEmpty);
    });
  });
}
