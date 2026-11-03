import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:cb_lints/src/package_paths.dart';

/// Reports a library under `lib/` other than `lib/src/epics/app_epics.dart`
/// building an `OnConnectivityEvent`, whether through
/// `ListenForConnectivity.event(...)` or the class's own constructor.
///
/// `OnConnectivityEvent` is what sets `AppState.isConnected` and
/// `wasConnected`, and `AppEpics._listenForConnectivityStart` is the one place
/// that may dispatch it: it maps `ConnectivityService`'s stream, the single
/// source of truth that also gates `OperationsEngine`'s flush. A second path
/// that writes `isConnected` is what once left the offline banner stuck after
/// the first reconnect, and the store would then disagree with the operations
/// queue about whether the device is online.
///
/// The constructor is resolved rather than its text matched, so an alias or
/// a redirecting factory still counts, and a `switch` that matches the event
/// does not. The library that declares the action is exempt too, as freezed's
/// generated part may build it.
class ConnectivityEventOutsideAppEpics extends AnalysisRule {
  static const LintCode code = LintCode(
    'connectivity_event_outside_app_epics',
    'Only AppEpics may build OnConnectivityEvent; ConnectivityService is the single source of '
        'isConnected.',
    correctionMessage: 'Try feeding ConnectivityService instead, which AppEpics maps to this event.',
    severity: DiagnosticSeverity.WARNING,
  );

  ConnectivityEventOutsideAppEpics()
    : super(
        name: 'connectivity_event_outside_app_epics',
        description:
            'OnConnectivityEvent, which sets AppState.isConnected, may only be '
            'built in lib/src/epics/app_epics.dart, from ConnectivityService.',
      );

  /// The library that maps `ConnectivityService` to the event.
  static const String appEpicsPath = 'lib/src/epics/app_epics.dart';

  /// The library that declares the action and its freezed part.
  static const String actionPath = 'lib/src/actions/app/listen_for_connectivity.dart';

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    final path = libraryPath(context);
    if (path == null || !path.startsWith('lib/') || path == appEpicsPath || path == actionPath) {
      return;
    }
    final _Visitor visitor = _Visitor(this, context.package!.root);
    // `ListenForConnectivity.event(...)` is a creation; a tear-off of it, such
    // as `.map(ListenForConnectivity.event)`, is a constructor reference.
    registry.addInstanceCreationExpression(this, visitor);
    registry.addConstructorReference(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.packageRoot);

  final AnalysisRule rule;
  final Folder packageRoot;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _check(node, node.constructorName.element);
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    _check(node, node.constructorName.element);
  }

  void _check(AstNode node, ConstructorElement? constructor) {
    // Follow redirecting factories: `ListenForConnectivity.event` is declared
    // on the union and redirects to `OnConnectivityEvent`.
    final Set<ConstructorElement> seen = <ConstructorElement>{};
    ConstructorElement? current = constructor?.baseElement;
    while (current != null && seen.add(current)) {
      if (_isConnectivityEvent(current.enclosingElement)) {
        rule.reportAtNode(node);
        return;
      }
      current = current.redirectedConstructor?.baseElement;
    }
  }

  bool _isConnectivityEvent(InterfaceElement element) {
    return element.name == 'OnConnectivityEvent' &&
        declaringPath(element, packageRoot) == ConnectivityEventOutsideAppEpics.actionPath;
  }
}
