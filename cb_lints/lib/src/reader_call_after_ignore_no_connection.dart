import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:cb_lints/src/package_paths.dart';
import 'package:cb_lints/src/reader_without_ignore_no_connection.dart';

/// Reports an operator or getter chained after `ignoreNoConnection()` in a
/// `yield*` of a `SyncEngine` reader, unless it is one of the sync engine's own
/// error handlers, `onNotFound` and `logBadResponses`. The chain is followed
/// through parentheses, casts and extension overrides.
///
/// `ignoreNoConnection()` only sees the errors of the stream it is called on.
/// An operator after it that reaches the network, as in
/// `local.ignoreNoConnection().asyncMap((_) => api.get(id))`, throws a
/// `SocketException` the guard never sees, and the read fails offline instead
/// of leaving the cached value on screen, while
/// `reader_without_ignore_no_connection` is satisfied by the call being there.
///
/// The rule allows what is known to be safe rather than looking for API calls,
/// because a call can reach the network without naming an API: through a
/// helper, a getter, or a closure passed in. Both allowed operators only handle
/// errors the stream already carries, so they add no new ones. Anything else,
/// even a harmless `map`, belongs before the guard, where it costs nothing to
/// put it. An allowed operator is resolved to the extension under
/// `lib/src/data/sync_engine/util/`, so a method that merely shares the name
/// does not pass.
class ReaderCallAfterIgnoreNoConnection extends AnalysisRule {
  static const LintCode code = LintCode(
    'reader_call_after_ignore_no_connection',
    "'{0}' runs after ignoreNoConnection(), which cannot see a connection error it raises.",
    correctionMessage: 'Try moving it before .ignoreNoConnection().',
    severity: DiagnosticSeverity.WARNING,
  );

  ReaderCallAfterIgnoreNoConnection()
    : super(
        name: 'reader_call_after_ignore_no_connection',
        description:
            'In a SyncEngine reader, only onNotFound and logBadResponses may '
            'follow ignoreNoConnection(); anything else could raise a '
            'connection error the guard does not see.',
      );

  /// The operators that may follow the guard, as they only handle errors.
  static const Set<String> safeAfterGuard = <String>{'onNotFound', 'logBadResponses'};

  /// Where the allowed operators are declared.
  static const String utilPath = 'lib/src/data/sync_engine/util/';

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    if (isSyncEngineLibrary(context)) {
      registry.addYieldStatement(this, _Visitor(this, context.package!.root));
    }
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.packageRoot);

  final AnalysisRule rule;
  final Folder packageRoot;

  @override
  void visitYieldStatement(YieldStatement node) {
    if (isReaderStreamYield(node)) {
      _check(node.expression);
    }
  }

  /// Walks the chain from the outermost call in, and reports the unsafe
  /// operator nearest to the last `ignoreNoConnection()`. A getter is never
  /// allowed, as it runs code too. A chain with no guard is
  /// `reader_without_ignore_no_connection`'s to report.
  void _check(Expression expression) {
    SimpleIdentifier? unsafe;
    Expression? current = expression;
    while (current != null) {
      switch (current) {
        case MethodInvocation():
          if (current.methodName.name == 'ignoreNoConnection') {
            if (unsafe != null) {
              _report(unsafe);
            }
            return;
          }
          if (!_isSafe(current)) {
            unsafe = current.methodName;
          }
          current = current.target;
        case PropertyAccess():
          unsafe = current.propertyName;
          current = current.target;
        case ParenthesizedExpression():
          current = current.expression;
        case AsExpression():
          current = current.expression;
        case ExtensionOverride():
          current = extendedExpression(current);
        case ConditionalExpression():
          // An operator after the whole conditional runs after the guard of
          // whichever branch has one.
          if (unsafe != null) {
            if (goesThroughIgnoreNoConnection(current.thenExpression) ||
                goesThroughIgnoreNoConnection(current.elseExpression)) {
              _report(unsafe);
            }
          } else {
            _check(current.thenExpression);
            _check(current.elseExpression);
          }
          return;
        default:
          return;
      }
    }
  }

  void _report(SimpleIdentifier operator) {
    rule.reportAtNode(operator, arguments: <Object>[operator.name]);
  }

  bool _isSafe(MethodInvocation node) {
    final Element? element = node.methodName.element;
    if (element == null || !ReaderCallAfterIgnoreNoConnection.safeAfterGuard.contains(element.name)) {
      return false;
    }
    return declaringPath(element, packageRoot)?.startsWith(ReaderCallAfterIgnoreNoConnection.utilPath) ?? false;
  }
}
