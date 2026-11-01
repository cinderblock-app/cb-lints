// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/route_page_outside_pages.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(RoutePageOutsidePagesTest);
  });
}

const String _page = r'''
import 'package:auto_route/auto_route.dart';

@RoutePage()
class JobsPage {}
''';

@reflectiveTest
class RoutePageOutsidePagesTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = RoutePageOutsidePages();
    newPackage('auto_route')
      ..addFile('lib/auto_route.dart', r'''
export 'src/annotations.dart';
''')
      ..addFile('lib/src/annotations.dart', r'''
class RoutePage {
  const RoutePage({this.name});

  final String? name;
}

const RoutePage routePage = RoutePage();

class AutoRouterConfig {
  const AutoRouterConfig();
}
''');
    super.setUp();
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  Future<void> _assertLinted(String localPath, String content, {String annotation = '@RoutePage()'}) async {
    await assertDiagnosticsInFile(_write(localPath, content), [lint(content.indexOf(annotation), annotation.length)]);
  }

  Future<void> test_pageUnderPages() async {
    await assertNoDiagnosticsInFile(_write('lib/src/presentation/pages/jobs/jobs_page.dart', _page));
  }

  Future<void> test_pageUnderWidgets() async {
    await _assertLinted('lib/src/presentation/widgets/jobs/jobs_page.dart', _page);
  }

  Future<void> test_pageInFolderNamedLikePages() async {
    await _assertLinted('lib/src/presentation/pages_old/jobs_page.dart', _page);
  }

  Future<void> test_routePageConstant() async {
    const content = r'''
import 'package:auto_route/auto_route.dart';

@routePage
class JobsPage {}
''';
    await _assertLinted('lib/src/presentation/widgets/jobs_page.dart', content, annotation: '@routePage');
  }

  Future<void> test_namedPageUnderWidgets() async {
    const content = r'''
import 'package:auto_route/auto_route.dart';

@RoutePage(name: 'JobsRouter')
class JobsTabPage {}
''';
    await _assertLinted(
      'lib/src/presentation/widgets/jobs_tab_page.dart',
      content,
      annotation: "@RoutePage(name: 'JobsRouter')",
    );
  }

  Future<void> test_routerDart() async {
    await assertNoDiagnosticsInFile(_write('lib/src/util/router.dart', _page));
  }

  Future<void> test_otherFileUnderUtil() async {
    await _assertLinted('lib/src/util/routes.dart', _page);
  }

  Future<void> test_pageOutsideLib() async {
    await assertNoDiagnosticsInFile(_write('test/jobs_page_test.dart', _page));
  }

  Future<void> test_nonPageClass() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/jobs/job_tile.dart', r'''
@Deprecated('Use JobCard')
class JobTile {}
'''),
    );
  }

  Future<void> test_otherAutoRouteAnnotation() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/app_router.dart', r'''
import 'package:auto_route/auto_route.dart';

@AutoRouterConfig()
class AppRouter {}
'''),
    );
  }

  Future<void> test_routePageFromAnotherPackage() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/jobs/jobs_page.dart', r'''
class RoutePage {
  const RoutePage();
}

@RoutePage()
class JobsPage {}
'''),
    );
  }

  Future<void> test_partUnderWidgetsOfLibraryUnderPages() async {
    _write('lib/src/presentation/pages/jobs/jobs_page.dart', r'''
import 'package:auto_route/auto_route.dart';

part '../../widgets/jobs/jobs_page_part.dart';
''');
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/jobs/jobs_page_part.dart', r'''
part of '../../pages/jobs/jobs_page.dart';

@RoutePage()
class JobsPage {}
'''),
    );
  }
}
