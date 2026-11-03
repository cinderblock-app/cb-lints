import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart';

/// The path of the library being analyzed, relative to its package root and
/// joined with `/`, or `null` when it is not in a package.
///
/// The library's defining file decides, not the part being visited: a part
/// belongs to its library wherever the file lives.
String? libraryPath(RuleContext context) {
  final package = context.package;
  if (package == null) {
    return null;
  }
  final file = context.definingUnit.file;
  final pathContext = file.provider.pathContext;
  return pathContext.split(pathContext.relative(file.path, from: package.root.path)).join('/');
}

/// The path of the library that declares [element], relative to [packageRoot]
/// and joined with `/`, or `null` when the element has no library.
///
/// A declaration from another package lands outside the root, so its path
/// climbs out with `..` and cannot name one of this package's files, whatever
/// it is called.
String? declaringPath(Element element, Folder packageRoot) {
  final library = element.library;
  if (library == null) {
    return null;
  }
  final pathContext = packageRoot.provider.pathContext;
  final path = library.firstFragment.source.fullName;
  return pathContext.split(pathContext.relative(path, from: packageRoot.path)).join('/');
}
