import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/edit/dart/dart_fix_kind_priority.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/precedence.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';

/// Adds `.ignoreNoConnection()` to the stream a reader yields, the fix for
/// `reader_without_ignore_no_connection`.
///
/// Plugin fixes cannot be applied in bulk, so this is a quick fix in the IDE and
/// `dart fix` does not see it.
class AddIgnoreNoConnection extends ResolvedCorrectionProducer {
  static const FixKind _kind = FixKind(
    'cb_lints.fix.addIgnoreNoConnection',
    DartFixKindPriority.standard,
    'Add .ignoreNoConnection()',
  );

  AddIgnoreNoConnection({required super.context});

  @override
  CorrectionApplicability get applicability => CorrectionApplicability.singleLocation;

  @override
  FixKind get fixKind => _kind;

  @override
  Future<void> compute(ChangeBuilder builder) async {
    final YieldStatement? statement = node.thisOrAncestorOfType<YieldStatement>();
    if (statement == null || statement.star == null) {
      return;
    }
    final Expression expression = statement.expression;
    final int column = unitResult.lineInfo.getLocation(statement.offset).columnNumber - 1;
    final IgnoreNoConnectionEdit edit = ignoreNoConnectionEdit(expression, column);
    await builder.addDartFileEdit(file, (builder) {
      if (edit.prefix.isNotEmpty) {
        builder.addSimpleInsertion(expression.offset, edit.prefix);
      }
      builder.addSimpleInsertion(expression.end, edit.suffix);
    });
  }
}

/// What to insert around an expression to call `ignoreNoConnection()` on it.
typedef IgnoreNoConnectionEdit = ({String prefix, String suffix});

/// The edit for [expression] in a statement at [statementColumn].
///
/// A chain over several lines gets the call on a line of its own, as the readers
/// write it, and anything that binds less tightly than a call gets parentheses.
IgnoreNoConnectionEdit ignoreNoConnectionEdit(Expression expression, int statementColumn) {
  if (expression.precedence < Precedence.postfix) {
    return (prefix: '(', suffix: ').ignoreNoConnection()');
  }
  final LineInfo lines = (expression.root as CompilationUnit).lineInfo;
  final bool multiline =
      lines.getLocation(expression.offset).lineNumber != lines.getLocation(expression.end).lineNumber;
  final String separator = multiline ? '\n${' ' * (statementColumn + 4)}' : '';
  return (prefix: '', suffix: '$separator.ignoreNoConnection()');
}
