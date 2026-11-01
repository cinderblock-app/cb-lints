import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

/// Reports a raw `dart:io` `Platform.isX` check in a library under `lib/`
/// other than `lib/src/util/platform_support.dart`.
///
/// About a dozen plugins declare only `android`/`ios`. A missing platform does
/// not break the build — the tool just does not register the plugin — so calls
/// into one throw `MissingPluginException` at runtime instead. Every affected
/// capability is therefore declared in `lib/src/util/platform_support.dart`
/// and the UI that needs it is hidden rather than left to fail.
///
/// "Do not add a raw `Platform.isMacOS`/`isWindows` check at a call site; add
/// or reuse a named capability, so the reason a widget disappears stays
/// legible and one getter flips when a plugin gains support."
class PlatformCheckOutsidePlatformSupport extends AnalysisRule {
  static const LintCode code = LintCode(
    'platform_check_outside_platform_support',
    'Platform checks belong in lib/src/util/platform_support.dart; a raw '
        "'Platform.{0}' at a call site hides why a widget disappears.",
    correctionMessage: 'Try adding or reusing a named capability on PlatformSupport.',
    severity: DiagnosticSeverity.WARNING,
  );

  PlatformCheckOutsidePlatformSupport()
    : super(
        name: 'platform_check_outside_platform_support',
        description:
            'Host platform checks must be named as capabilities in '
            'lib/src/util/platform_support.dart, not written as raw '
            'dart:io Platform checks at a call site.',
      );

  @override
  LintCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(RuleVisitorRegistry registry, RuleContext context) {
    if (_mayCheckPlatform(context)) {
      return;
    }
    final _Visitor visitor = _Visitor(this);
    // `Platform.isAndroid` is a prefixed identifier; `io.Platform.isAndroid`,
    // behind an import prefix, is a property access on one.
    registry.addPrefixedIdentifier(this, visitor);
    registry.addPropertyAccess(this, visitor);
  }

  /// Whether the library being analyzed is the one that declares the app's
  /// capabilities, or is outside `lib/`, where no shipped code lives.
  ///
  /// The library's defining file decides, not the part the check sits in: a
  /// part belongs to its library, and `platform_support.dart` has none.
  static bool _mayCheckPlatform(RuleContext context) {
    final package = context.package;
    if (package == null) {
      return true;
    }
    final file = context.definingUnit.file;
    final pathContext = file.provider.pathContext;
    final segments = pathContext.split(pathContext.relative(file.path, from: package.root.path));
    final path = segments.join('/');
    return segments.first != 'lib' || path == 'lib/src/util/platform_support.dart';
  }
}

/// The `dart:io` `Platform` getters that name the host operating system.
const Set<String> _platformGetters = <String>{'isAndroid', 'isIOS', 'isMacOS', 'isWindows', 'isLinux', 'isFuchsia'};

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _check(node, node.identifier);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _check(node, node.propertyName);
  }

  void _check(AstNode node, SimpleIdentifier member) {
    if (!_platformGetters.contains(member.name)) {
      return;
    }
    // A doc comment that names `[Platform.isMacOS]` resolves like code but
    // checks nothing; the capabilities file's own docs do exactly that.
    if (node.thisOrAncestorOfType<CommentReference>() != null) {
      return;
    }
    // Resolve the owner rather than match on the text: a `Platform` class from
    // somewhere else is not the one this rule is about.
    final element = member.element?.enclosingElement;
    if (element is InterfaceElement && element.name == 'Platform' && element.library.uri.toString() == 'dart:io') {
      rule.reportAtNode(node, arguments: <Object>[member.name]);
    }
  }
}
