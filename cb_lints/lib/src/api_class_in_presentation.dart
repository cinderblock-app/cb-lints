import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';

/// Reports a library under `lib/src/presentation/` referring to a class whose
/// name ends in `Api` and which is declared under `lib/src/data/`.
///
/// "Mutations are not direct API calls. They are `Operation`s enqueued through
/// `OperationsEngine`." The UI dispatches an operation and reads through the
/// `SyncEngine`; it never calls the API itself. A write that goes straight to
/// the API is not persisted to the operations queue, so it is lost on a cold
/// launch and never flushed when connectivity returns.
class ApiClassInPresentation extends AnalysisRule {
  static const LintCode code = LintCode(
    'api_class_in_presentation',
    "Presentation code must not reference the API class '{0}'; writes are "
        'Operations enqueued through OperationsEngine.',
    correctionMessage: 'Try dispatching an Operation, or reading through the SyncEngine.',
    severity: DiagnosticSeverity.WARNING,
  );

  ApiClassInPresentation()
    : super(
        name: 'api_class_in_presentation',
        description:
            'Libraries under lib/src/presentation must not reference the API '
            'classes under lib/src/data; writes go through the operations '
            'queue and reads through the SyncEngine.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final packageRoot = _presentationPackageRoot(context);
    if (packageRoot == null) {
      return;
    }
    final _Visitor visitor = _Visitor(this, packageRoot);
    // A type annotation, a constructor call and a type argument are all named
    // types; a static member access or a `show` combinator is an identifier.
    registry.addNamedType(this, visitor);
    registry.addSimpleIdentifier(this, visitor);
  }

  /// The package root, when the library being analyzed is presentation code,
  /// and `null` otherwise.
  ///
  /// The library's defining file decides, not the part a reference sits in:
  /// a part belongs to its library wherever the file lives.
  static Folder? _presentationPackageRoot(RuleContext context) {
    final package = context.package;
    if (package == null) {
      return null;
    }
    final file = context.definingUnit.file;
    final pathContext = file.provider.pathContext;
    final segments = pathContext.split(pathContext.relative(file.path, from: package.root.path));
    if (!segments.join('/').startsWith('lib/src/presentation/')) {
      return null;
    }
    return package.root;
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.packageRoot);

  final AnalysisRule rule;

  /// The root of the package being analyzed, which a declaring path is read
  /// against.
  final Folder packageRoot;

  @override
  void visitNamedType(NamedType node) {
    // The name token rather than the node: a `NamedType`'s source range takes
    // in a trailing `?`, and a nullable annotation is the same reference.
    _check(node.name, node.element);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _check(node.token, node.element);
  }

  void _check(Token name, Element? element) {
    if (element is! InterfaceElement || !(element.name ?? '').endsWith('Api')) {
      return;
    }
    // Resolve where the class is declared rather than match on its name, and
    // read that path against this package's root. A class from another package
    // lands outside the root, so its relative path climbs out with `..` and
    // cannot start with the data layer, whatever the class is called.
    final path = element.library.firstFragment.source.fullName;
    final pathContext = packageRoot.provider.pathContext;
    final segments = pathContext.split(pathContext.relative(path, from: packageRoot.path));
    if (segments.join('/').startsWith('lib/src/data/')) {
      rule.reportAtToken(name, arguments: <Object>[name.lexeme]);
    }
  }
}
