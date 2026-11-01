import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:cb_lints/src/add_ignore_no_connection.dart';
import 'package:test/test.dart';

class _FindYield extends RecursiveAstVisitor<void> {
  YieldStatement? found;

  @override
  void visitYieldStatement(YieldStatement node) {
    found = node;
  }
}

/// [statement] with the fix applied, or `null` if it offers none.
String? _fixed(String statement, {String eol = '\n'}) {
  final String content = 'Stream<int> read() async* {$eol    $statement$eol}$eol';
  final _FindYield finder = _FindYield();
  parseString(content: content, throwIfDiagnostics: false).unit.accept(finder);
  final List<IgnoreNoConnectionInsertion>? insertions = ignoreNoConnectionInsertions(
    finder.found!.expression,
    eol: eol,
  );
  if (insertions == null) {
    return null;
  }
  String result = content;
  for (final IgnoreNoConnectionInsertion insertion in insertions.reversed) {
    result = result.replaceRange(insertion.offset, insertion.offset, insertion.text);
  }
  return result.substring(result.indexOf('yield*'), result.lastIndexOf(';') + 1);
}

void main() {
  test('appends to a chain on one line', () {
    expect(_fixed('yield* api().notEquals(1);'), 'yield* api().notEquals(1).ignoreNoConnection();');
  });

  test('puts it on its own line after a chain over several, at the same indent', () {
    expect(
      _fixed('yield* api()\n        .notEquals(1);'),
      'yield* api()\n        .notEquals(1)\n        .ignoreNoConnection();',
    );
  });

  test('keeps the line ending of the file', () {
    expect(
      _fixed('yield* api()\r\n        .notEquals(1);', eol: '\r\n'),
      'yield* api()\r\n        .notEquals(1)\r\n        .ignoreNoConnection();',
    );
  });

  test('stays on the line of a call whose arguments span several', () {
    expect(_fixed('yield* api(\n      1,\n    );'), 'yield* api(\n      1,\n    ).ignoreNoConnection();');
  });

  test('adds it to both branches of a conditional', () {
    expect(_fixed('yield* flag ? a() : b();'), 'yield* flag ? a().ignoreNoConnection() : b().ignoreNoConnection();');
  });

  test('adds it only to the branch that needs it', () {
    expect(
      _fixed('yield* flag ? a().ignoreNoConnection() : b();'),
      'yield* flag ? a().ignoreNoConnection() : b().ignoreNoConnection();',
    );
  });

  test('offers nothing for an await, which throws before there is a stream', () {
    expect(_fixed('yield* await stream();'), isNull);
    expect(_fixed('yield* flag ? a() : await stream();'), isNull);
  });
}
