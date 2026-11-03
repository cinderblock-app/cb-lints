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
/// argument, or held in a final local that argument names; what the compute
/// function reads is not checked. An input reaches such a field through a final
/// local initialized with it, a conditional, a `!`, a cast, or `.keys`,
/// `.values`, `.entries`, `.toList()` or `.toSet()` on it, each of which is new
/// on every read too, and is reported where it sits in the list. A field counts
/// when the receiver's class carries `@Freezed` (or a constant of it) and the
/// class freezed generated for it declares that field as a getter rather than
/// storing it, which is exactly the wrapping case. A field stored as is (a
/// scalar, a nested state object, or any field with
/// `makeCollectionsUnmodifiable: false`) is identical while unchanged, and a
/// getter written by hand is not one freezed generated, so neither reports.
class MemoInputIsCollectionField extends AnalysisRule {
  static const LintCode code = LintCode(
    'memo_input_is_collection_field',
    "The Memo input reads '{0}', which freezed wraps anew on every read, so the memo never hits.",
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
    final Expression? argument = arguments.isEmpty ? null : arguments.first.argumentExpression.unParenthesized;
    final Expression? inputs = argument is SimpleIdentifier ? _finalLocalInitializer(argument) : argument;
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
    final (Expression, Expression)? read = _wrappedRead(input, <Element>{});
    if (read != null) {
      final (Expression field, Expression receiver) = read;
      rule.reportAtNode(input.unParenthesized, arguments: <Object>[field.toSource(), receiver.toSource()]);
    }
  }

  /// The wrapped field read [input] stands for, and its receiver, or `null`.
  (Expression, Expression)? _wrappedRead(Expression input, Set<Element> seen) {
    final Expression expression = input.unParenthesized;
    switch (expression) {
      case PostfixExpression() when expression.operator.lexeme == '!':
        return _wrappedRead(expression.operand, seen);
      case AsExpression():
        return _wrappedRead(expression.expression, seen);
      case ConditionalExpression():
        return _wrappedRead(expression.thenExpression, seen) ?? _wrappedRead(expression.elseExpression, seen);
      case SimpleIdentifier():
        final Element? element = expression.element;
        final Expression? initializer = element != null && seen.add(element)
            ? _finalLocalInitializer(expression)
            : null;
        return initializer == null ? null : _wrappedRead(initializer, seen);
      case PrefixedIdentifier():
        return _fieldRead(expression, expression.prefix, expression.identifier, seen);
      case PropertyAccess(:final Expression target?):
        return _fieldRead(expression, target, expression.propertyName, seen);
      case MethodInvocation(:final Expression target?)
          when _copies.contains(expression.methodName.name) && expression.argumentList.arguments.isEmpty:
        return _wrappedRead(target, seen);
      default:
        return null;
    }
  }

  /// Members that build a new object from a collection on every read.
  static const Set<String> _views = <String>{'keys', 'values', 'entries'};
  static const Set<String> _copies = <String>{'toList', 'toSet'};

  (Expression, Expression)? _fieldRead(
    Expression expression,
    Expression receiver,
    SimpleIdentifier property,
    Set<Element> seen,
  ) {
    if (property.element is! GetterElement) {
      return null;
    }
    final DartType? receiverType = receiver.staticType;
    if (receiverType is InterfaceType &&
        freezedAnnotation(receiverType.element) != null &&
        _wrapsOnRead(receiverType.element, property.name)) {
      return (expression, receiver);
    }
    return _views.contains(property.name) ? _wrappedRead(receiver, seen) : null;
  }

  /// The initializer of the final or const local [identifier] names, or `null`
  /// when it names anything else, which could hold another value by the call.
  Expression? _finalLocalInitializer(SimpleIdentifier identifier) {
    final Element? element = identifier.element;
    if (element is! LocalVariableElement || !(element.isFinal || element.isConst)) {
      return null;
    }
    final _DeclarationFinder finder = _DeclarationFinder(element);
    identifier.root.accept(finder);
    return finder.initializer;
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

/// Finds the declaration of a local variable, for its initializer.
class _DeclarationFinder extends RecursiveAstVisitor<void> {
  _DeclarationFinder(this.element);

  final LocalVariableElement element;
  Expression? initializer;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.declaredFragment?.element == element) {
      initializer = node.initializer;
      return;
    }
    super.visitVariableDeclaration(node);
  }
}
