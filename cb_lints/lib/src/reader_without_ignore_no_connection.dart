import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

/// Reports a `yield*` in a `SyncEngine` reader whose stream does not go through
/// `ignoreNoConnection()`.
///
/// Every reader yields its local value and then the API's, and
/// `ignoreNoConnection()` is what closes that second stream quietly when the
/// device is offline. Without it the read surfaces a `SocketException` to the
/// epic instead of leaving the cached value on screen, which only shows up once
/// someone opens that screen offline.
class ReaderWithoutIgnoreNoConnection extends AnalysisRule {
  static const LintCode code = LintCode(
    'reader_without_ignore_no_connection',
    'A SyncEngine reader must end its stream with ignoreNoConnection(), or reads fail instead of degrading offline.',
    correctionMessage: 'Try adding .ignoreNoConnection() to this stream.',
    severity: DiagnosticSeverity.WARNING,
  );

  ReaderWithoutIgnoreNoConnection()
    : super(
        name: 'reader_without_ignore_no_connection',
        description:
            'A yield* in a class named *Reader under lib/src/data/sync_engine '
            'must go through ignoreNoConnection(), so reads degrade offline.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    if (_isSyncEngine(context)) {
      registry.addYieldStatement(this, _Visitor(this));
    }
  }

  /// Whether the library being analyzed is under the sync engine. The library's
  /// defining file decides, as the readers are parts of `index.dart`.
  static bool _isSyncEngine(RuleContext context) {
    final package = context.package;
    if (package == null) {
      return false;
    }
    final file = context.definingUnit.file;
    final pathContext = file.provider.pathContext;
    final segments = pathContext.split(pathContext.relative(file.path, from: package.root.path));
    return segments.join('/').startsWith('lib/src/data/sync_engine/');
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitYieldStatement(YieldStatement node) {
    if (node.star == null || !_isInReader(node) || goesThroughIgnoreNoConnection(node.expression)) {
      return;
    }
    // A `sync*` helper yields an Iterable, which the call does not exist on.
    if (!(node.thisOrAncestorOfType<FunctionBody>()?.isAsynchronous ?? false)) {
      return;
    }
    rule.reportAtToken(node.yieldKeyword);
  }

  bool _isInReader(AstNode node) {
    final String? name = node.thisOrAncestorOfType<ClassDeclaration>()?.declaredFragment?.element.name;
    return name != null && name.endsWith('Reader');
  }
}

/// Whether the stream [expression] gives goes through `ignoreNoConnection()`.
///
/// Follows the call chain only: a call inside a closure further up, such as in
/// an `asyncMap`, does not guard the stream being yielded.
bool goesThroughIgnoreNoConnection(Expression expression) {
  Expression? current = expression;
  while (current != null) {
    switch (current) {
      case MethodInvocation():
        if (current.methodName.name == 'ignoreNoConnection') {
          return true;
        }
        current = current.target;
      case ParenthesizedExpression():
        current = current.expression;
      case PropertyAccess():
        current = current.target;
      case ConditionalExpression():
        return goesThroughIgnoreNoConnection(current.thenExpression) &&
            goesThroughIgnoreNoConnection(current.elseExpression);
      default:
        return false;
    }
  }
  return false;
}
