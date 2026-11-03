import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:cb_lints/src/package_paths.dart';

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
    'A SyncEngine reader must send its stream through ignoreNoConnection(), or reads fail instead of degrading offline.',
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
    if (isSyncEngineLibrary(context)) {
      registry.addYieldStatement(this, _Visitor(this));
    }
  }
}

/// Whether the library being analyzed is under the sync engine. The library's
/// defining file decides, as the readers are parts of `index.dart`.
bool isSyncEngineLibrary(RuleContext context) {
  return libraryPath(context)?.startsWith('lib/src/data/sync_engine/') ?? false;
}

/// Whether [node] is a `yield*` in an `async*` body of a class named `*Reader`.
///
/// A `sync*` helper yields an Iterable, which has no stream to guard.
bool isReaderStreamYield(YieldStatement node) {
  final String? name = node.thisOrAncestorOfType<ClassDeclaration>()?.declaredFragment?.element.name;
  return node.star != null &&
      name != null &&
      name.endsWith('Reader') &&
      (node.thisOrAncestorOfType<FunctionBody>()?.isAsynchronous ?? false);
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitYieldStatement(YieldStatement node) {
    if (!isReaderStreamYield(node) || goesThroughIgnoreNoConnection(node.expression)) {
      return;
    }
    rule.reportAtToken(node.yieldKeyword);
  }
}

/// Whether the stream [expression] gives goes through `ignoreNoConnection()`.
///
/// Follows the call chain only, through parentheses, casts and extension
/// overrides: a call inside a closure further up, such as in an `asyncMap`,
/// does not guard the stream being yielded.
bool goesThroughIgnoreNoConnection(Expression expression) {
  Expression? current = expression;
  while (current != null) {
    switch (current) {
      case MethodInvocation():
        if (current.methodName.name == 'ignoreNoConnection') {
          return !startsFromAwait(current.target);
        }
        current = current.target;
      case ParenthesizedExpression():
        current = current.expression;
      case AsExpression():
        current = current.expression;
      case ExtensionOverride():
        current = extendedExpression(current);
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

/// The receiver an extension override such as `IgnoreErrorExtension(stream)`
/// applies its member to, which the chain continues from.
Expression? extendedExpression(ExtensionOverride override) {
  final NodeList<Argument> arguments = override.argumentList.arguments;
  return arguments.isEmpty ? null : arguments.first.argumentExpression;
}

/// Whether the chain in [expression] starts from an `await`, which throws offline
/// before there is a stream for `ignoreNoConnection()` to guard.
bool startsFromAwait(Expression? expression) {
  Expression? current = expression;
  while (current != null) {
    switch (current) {
      case AwaitExpression():
        return true;
      case MethodInvocation():
        current = current.target;
      case ParenthesizedExpression():
        current = current.expression;
      case AsExpression():
        current = current.expression;
      case ExtensionOverride():
        current = extendedExpression(current);
      case PropertyAccess():
        current = current.target;
      default:
        return false;
    }
  }
  return false;
}
