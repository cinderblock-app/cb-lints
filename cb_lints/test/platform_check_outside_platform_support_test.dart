// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/platform_check_outside_platform_support.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PlatformCheckOutsidePlatformSupportTest);
  });
}

const String _check = r'''
import 'dart:io';

bool get onMac => Platform.isMacOS;
''';

@reflectiveTest
class PlatformCheckOutsidePlatformSupportTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = PlatformCheckOutsidePlatformSupport();
    newPackage('universal_platform')
      ..addFile('lib/universal_platform.dart', r'''
export 'src/platform.dart';
''')
      ..addFile('lib/src/platform.dart', r'''
abstract final class Platform {
  static bool get isMacOS => false;
}
''');
    super.setUp();
    // The mock SDK's `dart:io` declares only a deprecated `Platform.isAndroid`
    // and none of the other five getters, so replace that library with the
    // ones the rule is about. It has to be `dart:io`'s own `Platform`: the
    // rule resolves the owning class rather than matching on the name.
    newFile(resourceProvider.pathContext.join(sdkRoot.path, 'lib', 'io', 'io.dart'), r'''
library dart.io;

abstract final class Platform {
  static final bool isAndroid = true;
  static final bool isIOS = false;
  static final bool isMacOS = false;
  static final bool isWindows = false;
  static final bool isLinux = false;
  static final bool isFuchsia = false;
  static final String operatingSystem = 'android';
}
''');
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  Future<void> _assertLinted(String localPath, String content, {String check = 'Platform.isMacOS'}) async {
    await assertDiagnosticsInFile(_write(localPath, content), [lint(content.indexOf(check), check.length)]);
  }

  Future<void> test_checkUnderWidgets() async {
    await _assertLinted('lib/src/presentation/widgets/jobs/job_tile.dart', _check);
  }

  Future<void> test_platformSupport() async {
    await assertNoDiagnosticsInFile(_write('lib/src/util/platform_support.dart', _check));
  }

  Future<void> test_otherFileUnderUtil() async {
    await _assertLinted('lib/src/util/capabilities.dart', _check);
  }

  Future<void> test_checkOutsideLib() async {
    await assertNoDiagnosticsInFile(_write('test/src/util/platform_test.dart', _check));
  }

  /// Every getter the rule names, so the set cannot quietly lose one.
  Future<void> test_everyOperatingSystemGetter() async {
    const content = r'''
import 'dart:io';

final List<bool> all = <bool>[
  Platform.isAndroid,
  Platform.isIOS,
  Platform.isMacOS,
  Platform.isWindows,
  Platform.isLinux,
  Platform.isFuchsia,
];
''';
    const List<String> checks = <String>[
      'Platform.isAndroid',
      'Platform.isIOS',
      'Platform.isMacOS',
      'Platform.isWindows',
      'Platform.isLinux',
      'Platform.isFuchsia',
    ];
    await assertDiagnosticsInFile(_write('lib/src/presentation/widgets/all.dart', content), [
      for (final String check in checks) lint(content.indexOf(check), check.length),
    ]);
  }

  Future<void> test_behindImportPrefix() async {
    const content = r'''
import 'dart:io' as io;

bool get onWindows => io.Platform.isWindows;
''';
    await _assertLinted('lib/src/presentation/widgets/shell.dart', content, check: 'io.Platform.isWindows');
  }

  Future<void> test_otherPlatformMember() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/shell.dart', r'''
import 'dart:io';

String get os => Platform.operatingSystem;
'''),
    );
  }

  Future<void> test_platformFromAnotherPackage() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/shell.dart', r'''
import 'package:universal_platform/universal_platform.dart';

bool get onMac => Platform.isMacOS;
'''),
    );
  }

  Future<void> test_platformDeclaredLocally() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/shell.dart', r'''
abstract final class Platform {
  static bool get isMacOS => false;
}

bool get onMac => Platform.isMacOS;
'''),
    );
  }

  /// A doc comment that names a getter resolves like code but checks nothing.
  Future<void> test_docCommentReference() async {
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/shell.dart', r'''
import 'dart:io';

/// Mirrors [Platform.isMacOS], which only PlatformSupport may read.
const bool onMac = false;
'''),
    );
  }

  Future<void> test_partUnderWidgetsOfPlatformSupport() async {
    _write('lib/src/util/platform_support.dart', r'''
import 'dart:io';

part '../presentation/widgets/platform_support_part.dart';
''');
    await assertNoDiagnosticsInFile(
      _write('lib/src/presentation/widgets/platform_support_part.dart', r'''
part of '../../util/platform_support.dart';

bool get onMac => Platform.isMacOS;
'''),
    );
  }
}
