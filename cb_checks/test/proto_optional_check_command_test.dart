import 'package:test/test.dart';
import 'package:cb_checks/src/proto_optional_check_command.dart';

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

List<String> _check(Set<String> optional, {Map<String, String> compat = const <String, String>{}}) {
  return checkOptionalFields(
    fields: parseProtoFields(_proto),
    ledger: OptionalLedger(optional: optional, compat: compat),
    converters: _converters,
  );
}

void main() {
  const Set<String> current = <String>{'Invoice.paid_at', 'Note.body'};

  group('parseProtoFields', () {
    test('splits singular fields by presence, per message', () {
      final ProtoFields fields = parseProtoFields(_proto);

      expect(fields.optional, current);
      expect(fields.required, <String>{'Invoice.id', 'Invoice.due_date', 'Invoice.text'});
    });
  });

  group('checkOptionalFields', () {
    test('passes when the ledger matches', () {
      expect(_check(current), isEmpty);
    });

    test('fails on an optional field missing from the ledger', () {
      final List<String> problems = _check(<String>{'Invoice.paid_at'});

      expect(problems.single, contains('Note.body'));
      expect(problems.single, contains('--update'));
    });

    test('fails when a recorded field lost optional', () {
      final List<String> problems = _check(<String>{...current, 'Invoice.due_date'});

      expect(problems.single, startsWith('Invoice.due_date lost `optional`'));
    });

    test('passes when a converter uses the named decoder', () {
      final List<String> problems = _check(
        <String>{...current, 'Invoice.due_date'},
        compat: <String, String>{'Invoice.due_date': '_decodeInvoiceCompat'},
      );

      expect(problems, isEmpty);
    });

    test('fails when no converter uses the named decoder', () {
      final List<String> problems = _check(
        <String>{...current, 'Invoice.due_date'},
        compat: <String, String>{'Invoice.due_date': '_decodeElsewhere'},
      );

      expect(problems.single, contains('_decodeElsewhere'));
    });

    test('fails when the decoder belongs to another message', () {
      final List<String> problems = checkOptionalFields(
        fields: parseProtoFields(_proto),
        ledger: const OptionalLedger(
          optional: <String>{...current, 'Invoice.id'},
          compat: <String, String>{'Invoice.id': '_decodeNote'},
        ),
        converters: 'const ProtoEntityConverter<Note> note = ProtoEntityConverter<Note>(_decodeNote, encodeNote);',
      );

      expect(problems.single, contains('ProtoEntityConverter<Invoice>'));
    });

    test('does not count a commented-out converter', () {
      final List<String> problems = checkOptionalFields(
        fields: parseProtoFields(_proto),
        ledger: const OptionalLedger(
          optional: <String>{...current, 'Invoice.id'},
          compat: <String, String>{'Invoice.id': '_decodeInvoice'},
        ),
        converters: '// ProtoEntityConverter<Invoice>(_decodeInvoice, encodeInvoice)',
      );

      expect(problems.single, contains('_decodeInvoice'));
    });

    test('fails on a decoder entry for a field that is still optional', () {
      final List<String> problems = _check(current, compat: <String, String>{'Note.body': '_decodeInvoiceCompat'});

      expect(problems.single, startsWith('Note.body is under "compat"'));
    });

    test('ignores a recorded field that was removed', () {
      expect(_check(<String>{...current, 'Invoice.gone'}), isEmpty);
    });
  });

  group('OptionalLedger', () {
    test('updating cannot hide a dropped field', () {
      final OptionalLedger ledger = const OptionalLedger(
        optional: <String>{'Invoice.due_date'},
        compat: <String, String>{},
      ).including(parseProtoFields(_proto).optional);

      expect(ledger.optional, <String>{...current, 'Invoice.due_date'});
      expect(
        checkOptionalFields(fields: parseProtoFields(_proto), ledger: ledger, converters: _converters).single,
        startsWith('Invoice.due_date lost'),
      );
    });

    test('round-trips, sorted', () {
      const OptionalLedger ledger = OptionalLedger(
        optional: <String>{'B.b', 'A.a'},
        compat: <String, String>{'A.a': '_decode'},
      );

      final String encoded = ledger.encode();

      expect(encoded.indexOf('A.a'), lessThan(encoded.indexOf('B.b')));
      expect(OptionalLedger.parse(encoded).optional, ledger.optional);
      expect(OptionalLedger.parse(encoded).compat, ledger.compat);
    });
  });
}
