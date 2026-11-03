import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:cb_lints/src/package_paths.dart';

/// The library that declares the app's `Memo`.
const String memoPath = 'lib/src/util/memo.dart';

/// Whether [node] calls a `Memo`, as `memo(inputs, compute)`,
/// `memos[i](inputs, compute)` or `memo.call(inputs, compute)`.
///
/// The `call` method is resolved, so only the app's own `Memo` counts.
bool isMemoCall(Expression node, Folder packageRoot) {
  final Element? element = switch (node) {
    FunctionExpressionInvocation() => node.element,
    MethodInvocation() => node.methodName.element,
    _ => null,
  };
  if (element is! MethodElement || element.name != 'call') {
    return false;
  }
  final enclosing = element.enclosingElement;
  return enclosing is ClassElement && enclosing.name == 'Memo' && declaringPath(enclosing, packageRoot) == memoPath;
}

/// The arguments of [node], a call [isMemoCall] accepted.
NodeList<Argument> memoArguments(Expression node) {
  return switch (node) {
    FunctionExpressionInvocation() => node.argumentList.arguments,
    MethodInvocation() => node.argumentList.arguments,
    _ => throw ArgumentError.value(node, 'node', 'is not an invocation'),
  };
}

/// The value of the `@Freezed`/`@freezed` annotation on [element], or `null`
/// when it has none. App constants such as `@noCopyFreezed` resolve to one.
DartObject? freezedAnnotation(InterfaceElement element) {
  for (final ElementAnnotation annotation in element.metadata.annotations) {
    final DartObject? value = annotation.computeConstantValue();
    final typeElement = value?.type?.element;
    if (typeElement is ClassElement &&
        typeElement.name == 'Freezed' &&
        typeElement.library.uri.toString().startsWith('package:freezed_annotation/')) {
      return value;
    }
  }
  return null;
}

/// The classes that implement [element]'s factory constructors, which freezed
/// generates: `X$` or `_X` for `factory X(...) = X$;`.
Iterable<InterfaceElement> freezedImplementations(InterfaceElement element) sync* {
  for (final ConstructorElement constructor in element.constructors) {
    final ConstructorElement? redirected = constructor.redirectedConstructor?.baseElement;
    if (constructor.isFactory && redirected != null) {
      yield redirected.enclosingElement;
    }
  }
}
