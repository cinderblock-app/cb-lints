import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:cb_lints/src/memo_calls.dart';
import 'package:cb_lints/src/package_paths.dart';

/// Reports an input of a `Memo` call, in a library under `lib/`, that reads a
/// field off a freezed object whose generated class builds a new value on every
/// read, such as `store.state.appointments.allAppointments`.
///
/// `Memo` (`lib/src/util/memo.dart`) skips its computation while each input is
/// [identical] to last time. Freezed wraps a collection field in a new
/// `EqualUnmodifiableMapView` (or list or set view) on every read unless the
/// stored value already is one, so such an input differs every time, the memo
/// never hits, and the converter walks the whole collection on every action
/// again, with nothing to show for it but a passing test. Pass the object that
/// holds it (`store.state.appointments`), which a reducer replaces whenever any
/// of its fields change.
///
/// "Input" means an element of the list literal given as the call's first
/// argument; what the compute function reads is not checked. A field counts
/// when the receiver's class carries `@Freezed` (or a constant of it) and the
/// class freezed generated for it declares that field as a getter rather than
/// storing it, which is exactly the wrapping case. A field stored as is (a
/// scalar, a nested state object, or any field with
/// `makeCollectionsUnmodifiable: false`) is identical while unchanged, and a
/// getter written by hand is not one freezed generated, so neither reports.
class MemoInputIsCollectionField extends AnalysisRule {
  static const LintCode code = LintCode(
    'memo_input_is_collection_field',
    "The Memo input '{0}' is wrapped anew on every read, so the memo never hits.",
    correctionMessage: "Try passing the object that holds it, '{1}', instead.",
    severity: DiagnosticSeverity.WARNING,
  );

  MemoInputIsCollectionField()
    : super(
        name: 'memo_input_is_collection_field',
        description:
            'A Memo input must not be a collection field read off a freezed '
            'object, which is never identical to itself; pass the object.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final path = libraryPath(context);
    if (path == null || !path.startsWith('lib/')) {
      return;
    }
    final _Visitor visitor = _Visitor(this, context.package!.root);
    // `memo(...)` on a field resolves to a function expression invocation;
    // `memo.call(...)` stays a method invocation.
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addMethodInvocation(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.packageRoot);

  final AnalysisRule rule;
  final Folder packageRoot;

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) => _checkCall(node);

  @override
  void visitMethodInvocation(MethodInvocation node) => _checkCall(node);

  void _checkCall(Expression node) {
    if (!isMemoCall(node, packageRoot)) {
      return;
    }
    final arguments = memoArguments(node);
    final Expression? inputs = arguments.isEmpty ? null : arguments.first.argumentExpression.unParenthesized;
    if (inputs is ListLiteral) {
      inputs.elements.forEach(_checkElement);
    }
  }

  void _checkElement(CollectionElement element) {
    switch (element) {
      case Expression():
        _checkInput(element);
      case IfElement():
        _checkElement(element.thenElement);
        final CollectionElement? elseElement = element.elseElement;
        if (elseElement != null) {
          _checkElement(elseElement);
        }
      default:
        break;
    }
  }

  void _checkInput(Expression input) {
    final Expression expression = input.unParenthesized;
    final Expression receiver;
    final SimpleIdentifier property;
    switch (expression) {
      case PrefixedIdentifier():
        receiver = expression.prefix;
        property = expression.identifier;
      case PropertyAccess(:final Expression target?):
        receiver = target;
        property = expression.propertyName;
      default:
        return;
    }
    if (property.element is! GetterElement) {
      return;
    }
    final DartType? receiverType = receiver.staticType;
    if (receiverType is! InterfaceType) {
      return;
    }
    final InterfaceElement owner = receiverType.element;
    if (freezedAnnotation(owner) == null || !_wrapsOnRead(owner, property.name)) {
      return;
    }
    rule.reportAtNode(expression, arguments: <Object>[expression.toSource(), receiver.toSource()]);
  }

  /// Whether a class freezed generated for [owner] computes [name] in a
  /// getter, which it does only to wrap a collection in an unmodifiable view.
  bool _wrapsOnRead(InterfaceElement owner, String name) {
    for (final InterfaceElement implementation in freezedImplementations(owner)) {
      final GetterElement? getter = implementation.getGetter(name);
      if (getter != null && getter.isOriginDeclaration) {
        return true;
      }
    }
    return false;
  }
}
