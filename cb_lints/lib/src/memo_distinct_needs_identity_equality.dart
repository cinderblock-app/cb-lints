import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:cb_lints/src/memo_calls.dart';
import 'package:cb_lints/src/package_paths.dart';

/// Reports a `StoreConnector` with `distinct: true`, in a library under
/// `lib/`, whose converter takes its view model from a `Memo`, when that view
/// model is a freezed class with a collection field and without
/// `@Freezed(equal: false)`.
///
/// A memoized converter hands back the same instance while nothing it reads
/// changed and a new one only when an input did, so identity is all `distinct`
/// needs. Freezed's `==` compares every field deeply instead, and the new
/// instance after a change is never identical to the old one, so each change
/// walks every item of every list in the view model a second time, which is
/// the work the memo was there to save (#4027). `equal: false` makes `==`
/// identity.
///
/// `Memo` has no `distinct` of its own: the flag is the connector's. The view
/// model is the connector's second type argument, inferred or written, and the
/// rule needs a `Memo` call in the converter whose type is that view model,
/// since a converter that builds a new view model each time relies on value
/// equality for `distinct` to work at all. A view model of scalars only is left
/// alone: comparing a few ints is cheaper than a rebuild, and can skip one.
class MemoDistinctNeedsIdentityEquality extends AnalysisRule {
  static const LintCode code = LintCode(
    'memo_distinct_needs_identity_equality',
    "The memoized view model '{0}' compares its collections deeply on every change; distinct "
        'only needs identity.',
    correctionMessage: "Try annotating '{0}' with @Freezed(equal: false).",
    severity: DiagnosticSeverity.WARNING,
  );

  MemoDistinctNeedsIdentityEquality()
    : super(
        name: 'memo_distinct_needs_identity_equality',
        description:
            'A distinct StoreConnector whose converter returns a Memo value '
            'needs a view model with @Freezed(equal: false).',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final path = libraryPath(context);
    if (path == null || !path.startsWith('lib/')) {
      return;
    }
    registry.addInstanceCreationExpression(this, _Visitor(this, context.package!.root));
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.packageRoot);

  final AnalysisRule rule;
  final Folder packageRoot;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final DartType? type = node.staticType;
    if (type is! InterfaceType || !_isStoreConnector(type.element) || type.typeArguments.length != 2) {
      return;
    }
    NamedArgument? distinct;
    Expression? converter;
    for (final Argument argument in node.argumentList.arguments) {
      if (argument is NamedArgument) {
        switch (argument.name.lexeme) {
          case 'distinct':
            distinct = argument;
          case 'converter':
            converter = argument.argumentExpression;
        }
      }
    }
    final Expression? distinctValue = distinct?.argumentExpression.unParenthesized;
    if (distinct == null || distinctValue is! BooleanLiteral || !distinctValue.value || converter == null) {
      return;
    }
    final DartType viewModelType = type.typeArguments[1];
    if (viewModelType is! InterfaceType) {
      return;
    }
    final InterfaceElement viewModel = viewModelType.element;
    final DartObject? freezed = freezedAnnotation(viewModel);
    if (freezed == null || freezed.getField('equal')?.toBoolValue() == false || !_hasCollectionField(viewModel)) {
      return;
    }
    final _MemoFinder finder = _MemoFinder(packageRoot, viewModel);
    converter.accept(finder);
    if (finder.found) {
      rule.reportAtNode(distinct, arguments: <Object>[viewModel.name ?? viewModelType.getDisplayString()]);
    }
  }

  bool _isStoreConnector(InterfaceElement element) {
    return element.name == 'StoreConnector' && element.library.uri.toString().startsWith('package:flutter_redux/');
  }

  /// Whether a factory constructor of [viewModel] takes a list, map, set or
  /// other iterable, which is what freezed's `==` walks item by item.
  bool _hasCollectionField(InterfaceElement viewModel) {
    for (final ConstructorElement constructor in viewModel.constructors) {
      if (!constructor.isFactory) {
        continue;
      }
      for (final FormalParameterElement parameter in constructor.formalParameters) {
        final DartType parameterType = parameter.type;
        if (parameterType is InterfaceType &&
            (parameterType.isDartCoreMap ||
                parameterType.isDartCoreIterable ||
                parameterType.element.allSupertypes.any((InterfaceType supertype) => supertype.isDartCoreIterable))) {
          return true;
        }
      }
    }
    return false;
  }
}

/// Finds a `Memo` call whose value is the view model.
class _MemoFinder extends RecursiveAstVisitor<void> {
  _MemoFinder(this.packageRoot, this.viewModel);

  final Folder packageRoot;
  final InterfaceElement viewModel;
  bool found = false;

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _check(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _check(node);
    super.visitMethodInvocation(node);
  }

  void _check(Expression node) {
    final DartType? type = node.staticType;
    if (type is InterfaceType && type.element == viewModel && isMemoCall(node, packageRoot)) {
      found = true;
    }
  }
}
