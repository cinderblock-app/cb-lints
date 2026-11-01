// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/api_class_in_presentation.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ApiClassInPresentationTest);
  });
}

const String _reference = r'''
import 'package:test/src/data/jobs_api.dart';

class JobsScreen {
  JobsApi? api;
}
''';

@reflectiveTest
class ApiClassInPresentationTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = ApiClassInPresentation();
    // A third-party class whose name also ends in `Api`, to prove the rule
    // resolves where a class is declared rather than matching on its name.
    newPackage('stripe')
      ..addFile('lib/stripe.dart', r'''
export 'src/api.dart';
''')
      ..addFile('lib/src/api.dart', r'''
class StripeApi {
  static const String version = '1';
}
''');
    super.setUp();
    _write('lib/src/data/jobs_api.dart', r'''
class JobsApi {
  const JobsApi();

  static const String path = '/jobs';

  Future<void> rename(String id, String name) async {}
}

class JobsRepository {}
''');
    _write('lib/src/util/analytics_api.dart', r'''
class AnalyticsApi {}
''');
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  Future<void> _assertLinted(String localPath, String content, {String reference = 'JobsApi'}) async {
    await assertDiagnosticsInFile(_write(localPath, content), [lint(content.indexOf(reference), reference.length)]);
  }

  Future<void> test_typeAnnotationInPresentation() async {
    await _assertLinted('lib/src/presentation/pages/jobs/jobs_page.dart', _reference);
  }

  Future<void> test_constructorCallInPresentation() async {
    const content = r'''
import 'package:test/src/data/jobs_api.dart';

void rename() {
  const JobsApi().rename('1', 'Roof');
}
''';
    await _assertLinted('lib/src/presentation/pages/jobs/jobs_page.dart', content);
  }

  Future<void> test_staticMemberAccessInPresentation() async {
    const content = r'''
import 'package:test/src/data/jobs_api.dart';

const String path = JobsApi.path;
''';
    await _assertLinted('lib/src/presentation/pages/jobs/jobs_page.dart', content);
  }

  Future<void> test_typeArgumentInPresentation() async {
    const content = r'''
import 'package:test/src/data/jobs_api.dart';

final List<JobsApi> apis = <JobsApi>[];
''';
    await assertDiagnosticsInFile(_write('lib/src/presentation/pages/jobs/jobs_page.dart', content), [
      lint(content.indexOf('List<JobsApi>') + 'List<'.length, 'JobsApi'.length),
      lint(content.lastIndexOf('<JobsApi>') + 1, 'JobsApi'.length),
    ]);
  }

  Future<void> test_showCombinatorInPresentation() async {
    const content = r'''
import 'package:test/src/data/jobs_api.dart' show JobsApi;

JobsApi? api;
''';
    await assertDiagnosticsInFile(_write('lib/src/presentation/pages/jobs/jobs_page.dart', content), [
      lint(content.indexOf('show JobsApi') + 'show '.length, 'JobsApi'.length),
      lint(content.lastIndexOf('JobsApi'), 'JobsApi'.length),
    ]);
  }

  Future<void> test_apiInDataLayer() async {
    await assertNoDiagnosticsInFile(_write('lib/src/data/sync_engine/jobs.dart', _reference));
  }

  Future<void> test_apiInMiddleware() async {
    await assertNoDiagnosticsInFile(_write('lib/src/middleware/jobs_middleware.dart', _reference));
  }

  Future<void> test_apiInTest() async {
    await assertNoDiagnosticsInFile(_write('test/src/presentation/pages/jobs_page_test.dart', _reference));
  }

  Future<void> test_thirdPartyApiInPresentation() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/pages/jobs/jobs_page.dart', r'''
import 'package:stripe/stripe.dart';

StripeApi? api;
'''),
    );
  }

  /// Only `lib/src/data/` is the data layer; a class named the same way
  /// elsewhere in the app is not what the operations queue stands in front of.
  Future<void> test_apiOutsideDataLayer() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/pages/jobs/jobs_page.dart', r'''
import 'package:test/src/util/analytics_api.dart';

AnalyticsApi? analytics;
'''),
    );
  }

  Future<void> test_classNotEndingInApi() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/pages/jobs/jobs_page.dart', r'''
import 'package:test/src/data/jobs_api.dart';

JobsRepository? jobs;
'''),
    );
  }

  Future<void> test_partUnderDataOfPresentationLibrary() async {
    _write('lib/src/presentation/pages/jobs/jobs_page.dart', r'''
import 'package:test/src/data/jobs_api.dart';

part '../../../data/jobs_page_part.dart';
''');
    const content = r'''
part of '../presentation/pages/jobs/jobs_page.dart';

JobsApi? api;
''';
    await _assertLinted('lib/src/data/jobs_page_part.dart', content);
  }
}
