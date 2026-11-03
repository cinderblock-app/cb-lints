// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/connectivity_event_outside_app_epics.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ConnectivityEventOutsideAppEpicsTest);
  });
}

const String _action = r'''
abstract class AppAction {}

abstract class ListenForConnectivity implements AppAction {
  const factory ListenForConnectivity.start() = ListenForConnectivityStart;

  const factory ListenForConnectivity.event({required bool isConnected}) = OnConnectivityEvent;

  const factory ListenForConnectivity.connected({required bool isConnected}) = ListenForConnectivity.event;
}

class ListenForConnectivityStart implements ListenForConnectivity {
  const ListenForConnectivityStart();
}

class OnConnectivityEvent implements ListenForConnectivity {
  const OnConnectivityEvent({required this.isConnected});

  final bool isConnected;
}

const AppAction initial = ListenForConnectivity.event(isConnected: true);
''';

const String _import = "import 'package:test/src/actions/app/listen_for_connectivity.dart';\n\n";

const String _otherPath = 'lib/src/epics/platform_epics.dart';

@reflectiveTest
class ConnectivityEventOutsideAppEpicsTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = ConnectivityEventOutsideAppEpics();
    super.setUp();
    _write('lib/src/actions/app/listen_for_connectivity.dart', _action);
    _write('lib/src/util/lookalike.dart', r'''
class OnConnectivityEvent {
  const OnConnectivityEvent({required this.isConnected});

  final bool isConnected;
}
''');
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  Future<void> _assertLinted(String body, String reported, {String path = _otherPath}) async {
    final String content = '$_import$body';
    await assertDiagnosticsInFile(_write(path, content), [lint(content.indexOf(reported), reported.length)]);
  }

  Future<void> test_unionFactory() async {
    await _assertLinted(
      'AppAction event(bool value) => ListenForConnectivity.event(isConnected: value);\n',
      'ListenForConnectivity.event(isConnected: value)',
    );
  }

  Future<void> test_constUnionFactory() async {
    await _assertLinted(
      'const AppAction event = ListenForConnectivity.event(isConnected: false);\n',
      'ListenForConnectivity.event(isConnected: false)',
    );
  }

  Future<void> test_eventClassConstructor() async {
    await _assertLinted(
      'AppAction event() => const OnConnectivityEvent(isConnected: false);\n',
      'const OnConnectivityEvent(isConnected: false)',
    );
  }

  /// A factory that redirects to the event factory, which redirects again.
  Future<void> test_redirectChain() async {
    await _assertLinted(
      'AppAction event() => const ListenForConnectivity.connected(isConnected: true);\n',
      'const ListenForConnectivity.connected(isConnected: true)',
    );
  }

  Future<void> test_tearOff() async {
    await _assertLinted(
      'final AppAction Function({required bool isConnected}) make = ListenForConnectivity.event;\n',
      'ListenForConnectivity.event',
    );
  }

  Future<void> test_inAppEpics() async {
    await assertNoDiagnosticsInFile(
      _write(
        'lib/src/epics/app_epics.dart',
        '${_import}AppAction event(bool value) => ListenForConnectivity.event(isConnected: value);\n',
      ),
    );
  }

  Future<void> test_partOfAppEpics() async {
    _write('lib/src/epics/app_epics.dart', "${_import}part 'app_epics_connectivity.dart';\n");
    await assertNoDiagnosticsInFile(
      _write(
        'lib/src/epics/app_epics_connectivity.dart',
        "part of 'app_epics.dart';\n\nAppAction event(bool value) => ListenForConnectivity.event(isConnected: value);\n",
      ),
    );
  }

  Future<void> test_inDeclaringLibrary() async {
    await assertNoDiagnosticsInFile(
      convertPath('$testPackageRootPath/lib/src/actions/app/listen_for_connectivity.dart'),
    );
  }

  Future<void> test_inTest() async {
    await assertNoDiagnosticsInFile(
      _write(
        'test/src/epics/app_epics_test.dart',
        '${_import}AppAction event() => const OnConnectivityEvent(isConnected: false);\n',
      ),
    );
  }

  Future<void> test_otherCase() async {
    await assertNoDiagnosticsInFile(
      _write(_otherPath, '${_import}AppAction start() => const ListenForConnectivity.start();\n'),
    );
  }

  Future<void> test_matchingTheEvent() async {
    await assertNoDiagnosticsInFile(
      _write(_otherPath, '''
${_import}bool isOnline(Object action) {
  return switch (action) {
    OnConnectivityEvent(:final bool isConnected) => isConnected,
    _ => action is OnConnectivityEvent,
  };
}
'''),
    );
  }

  Future<void> test_lookalikeClass() async {
    await assertNoDiagnosticsInFile(
      _write(_otherPath, r'''
import 'package:test/src/util/lookalike.dart';

const Object event = OnConnectivityEvent(isConnected: true);
'''),
    );
  }

  Future<void> test_subclass() async {
    await _assertLinted('''
class FakeOnline extends OnConnectivityEvent {
  const FakeOnline() : super(isConnected: true);
}
''', 'OnConnectivityEvent');
  }

  Future<void> test_implementation() async {
    await _assertLinted('''
class FakeOnline implements OnConnectivityEvent {
  @override
  bool get isConnected => true;
}
''', 'OnConnectivityEvent');
  }

  /// A subclass of a subclass, declared elsewhere under `lib/`.
  Future<void> test_indirectSubclass() async {
    _write('lib/src/util/fake_online.dart', '''
${_import}class FakeOnline extends OnConnectivityEvent {
  const FakeOnline() : super(isConnected: true);
}
''');
    const String content = r'''
import 'package:test/src/util/fake_online.dart';

class FakerOnline extends FakeOnline {
  const FakerOnline();
}
''';
    await assertDiagnosticsInFile(_write(_otherPath, content), [
      lint(content.indexOf('FakeOnline {'), 'FakeOnline'.length),
    ]);
  }

  Future<void> test_classAlias() async {
    await _assertLinted('''
mixin Quiet {}

class FakeOnline = OnConnectivityEvent with Quiet;
''', 'OnConnectivityEvent');
  }

  Future<void> test_subclassInTest() async {
    await assertNoDiagnosticsInFile(
      _write('test/src/fakes.dart', '''
${_import}class FakeOnline extends OnConnectivityEvent {
  const FakeOnline() : super(isConnected: true);
}
'''),
    );
  }

  Future<void> test_otherCaseSubclass() async {
    await assertNoDiagnosticsInFile(
      _write(_otherPath, '''
${_import}class Starting extends ListenForConnectivityStart {
  const Starting();
}
'''),
    );
  }
}
