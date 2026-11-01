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

String _fixed(String statement) {
  final String content = 'Stream<int> read() async* {\n    $statement\n}\n';
  final _FindYield finder = _FindYield();
  parseString(content: content, throwIfDiagnostics: false).unit.accept(finder);
  final Expression expression = finder.found!.expression;
  final IgnoreNoConnectionEdit edit = ignoreNoConnectionEdit(expression, 4);
  return content.substring(content.indexOf('yield*'), expression.offset) +
      edit.prefix +
      content.substring(expression.offset, expression.end) +
      edit.suffix +
      content.substring(expression.end, content.lastIndexOf(';') + 1);
}

void main() {
  test('appends to a chain on one line', () {
    expect(_fixed('yield* api().notEquals(1);'), 'yield* api().notEquals(1).ignoreNoConnection();');
  });

  test('puts it on its own line after a chain over several', () {
    expect(
      _fixed('yield* api()\n        .notEquals(1);'),
      'yield* api()\n        .notEquals(1)\n        .ignoreNoConnection();',
    );
  });

  test('wraps a conditional, which would otherwise guard one branch', () {
    expect(_fixed('yield* flag ? a() : b();'), 'yield* (flag ? a() : b()).ignoreNoConnection();');
  });

  test('wraps an await', () {
    expect(_fixed('yield* await stream();'), 'yield* (await stream()).ignoreNoConnection();');
  });
}
