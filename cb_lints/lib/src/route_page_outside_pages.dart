import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

/// Reports `@RoutePage()` in a library outside `lib/src/presentation/pages/`.
///
/// build.yaml runs auto_route's per-file builder only over that folder and
/// `lib/src/util/router.dart`, which declares the tab shell pages, because the
/// builder is slow on every library it is given. A page anywhere else silently
/// gets no route.
class RoutePageOutsidePages extends AnalysisRule {
  static const LintCode code = LintCode(
    'route_page_outside_pages',
    'Route pages live in lib/src/presentation/pages; build.yaml generates '
        'routes only from there.',
    correctionMessage: 'Try moving this file under lib/src/presentation/pages.',
    severity: DiagnosticSeverity.WARNING,
  );

  RoutePageOutsidePages()
    : super(
        name: 'route_page_outside_pages',
        description:
            'Route pages must be declared under lib/src/presentation/pages, '
            'the only folder build.yaml generates routes from.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    if (_mayDeclarePages(context)) {
      return;
    }
    registry.addAnnotation(this, _Visitor(this));
  }

  /// Whether the library being analyzed is one build.yaml generates routes
  /// from, or is outside `lib/`, where the app's router never looks.
  ///
  /// The library's defining file decides, not the part an annotation sits in:
  /// build_runner runs builders on libraries, and a library's parts come along.
  static bool _mayDeclarePages(RuleContext context) {
    final package = context.package;
    if (package == null) {
      return true;
    }
    final file = context.definingUnit.file;
    final pathContext = file.provider.pathContext;
    final segments = pathContext.split(pathContext.relative(file.path, from: package.root.path));
    final path = segments.join('/');
    return segments.first != 'lib' ||
        path.startsWith('lib/src/presentation/pages/') ||
        path == 'lib/src/util/router.dart';
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitAnnotation(Annotation node) {
    // Covers both `@RoutePage()` and auto_route's `@routePage` constant.
    final type = node.elementAnnotation?.computeConstantValue()?.type;
    final element = type?.element;
    if (element is InterfaceElement &&
        element.name == 'RoutePage' &&
        element.library.uri.toString().startsWith('package:auto_route/')) {
      rule.reportAtNode(node);
    }
  }
}
