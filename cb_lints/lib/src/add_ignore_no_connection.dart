import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analysis_server_plugin/edit/dart/dart_fix_kind_priority.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/precedence.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:cb_lints/src/reader_without_ignore_no_connection.dart';

/// Adds `.ignoreNoConnection()` to the stream a reader yields, the fix for
/// `reader_without_ignore_no_connection`.
///
/// Plugin fixes cannot be applied in bulk, so this is a quick fix in the IDE and
/// `dart fix` does not see it. It assumes the extension is in scope, as it is in
/// the parts of the sync engine's `index.dart`; elsewhere the result does not
/// compile until the import is added.
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
    if (statement == null || statement.star == null || !(statement.expression.staticType?.isDartAsyncStream ?? false)) {
      return;
    }
    await builder.addDartFileEdit(file, (builder) {
      final List<IgnoreNoConnectionInsertion>? insertions = ignoreNoConnectionInsertions(
        statement.expression,
        eol: builder.eol,
      );
      for (final IgnoreNoConnectionInsertion insertion in insertions ?? <IgnoreNoConnectionInsertion>[]) {
        builder.addSimpleInsertion(insertion.offset, insertion.text);
      }
    });
  }
}

/// Text to add at a place in the source.
typedef IgnoreNoConnectionInsertion = ({int offset, String text});

/// What to insert so that the stream [expression] gives goes through
/// `ignoreNoConnection()`, or `null` if no insertion can do that.
///
/// `yield* await x` has no such edit: the `await` throws offline before there is
/// a stream to guard, so wrapping it would clear the warning and keep the crash.
/// Only the branches of a conditional that need the call get it.
List<IgnoreNoConnectionInsertion>? ignoreNoConnectionInsertions(Expression expression, {String eol = '\n'}) {
  if (goesThroughIgnoreNoConnection(expression)) {
    return <IgnoreNoConnectionInsertion>[];
  }
  if (startsFromAwait(expression)) {
    return null;
  }
  switch (expression) {
    case ConditionalExpression():
      final List<IgnoreNoConnectionInsertion>? then = ignoreNoConnectionInsertions(expression.thenExpression, eol: eol);
      final List<IgnoreNoConnectionInsertion>? otherwise = ignoreNoConnectionInsertions(
        expression.elseExpression,
        eol: eol,
      );
      return then == null || otherwise == null ? null : <IgnoreNoConnectionInsertion>[...then, ...otherwise];
    default:
      if (expression.precedence < Precedence.postfix) {
        return <IgnoreNoConnectionInsertion>[
          (offset: expression.offset, text: '('),
          (offset: expression.end, text: ').ignoreNoConnection()'),
        ];
      }
      return <IgnoreNoConnectionInsertion>[
        (offset: expression.end, text: '${_chainBreak(expression, eol)}.ignoreNoConnection()'),
      ];
  }
}

/// A line break and indent matching the call before, if [expression] is a chain
/// with that call on a line of its own, as the readers write them.
String _chainBreak(Expression expression, String eol) {
  if (expression is! MethodInvocation || expression.target == null || expression.operator == null) {
    return '';
  }
  final LineInfo lines = (expression.root as CompilationUnit).lineInfo;
  final CharacterLocation target = lines.getLocation(expression.target!.end);
  final CharacterLocation operator = lines.getLocation(expression.operator!.offset);
  return target.lineNumber == operator.lineNumber ? '' : '$eol${' ' * (operator.columnNumber - 1)}';
}
