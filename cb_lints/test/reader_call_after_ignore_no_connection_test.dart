// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/reader_call_after_ignore_no_connection.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ReaderCallAfterIgnoreNoConnectionTest);
  });
}

const String _prelude = r'''
// ignore_for_file: unused_import
import 'package:test/src/data/rx.dart';
import 'package:test/src/data/sync_engine/util/guards.dart';

''';

String _reader(String body, {String name = 'TagsReader', String prelude = _prelude}) {
  return '$prelude'
      'class $name {\n'
      '  Stream<int> api() async* {}\n'
      '  Future<int> fetch(int id) async => id;\n'
      '  Stream<int> read(bool flag) async* {\n'
      '    yield 1;\n'
      '$body\n'
      '  }\n'
      '}\n';
}

const String _syncEnginePath = 'lib/src/data/sync_engine/tags.dart';

@reflectiveTest
class ReaderCallAfterIgnoreNoConnectionTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = ReaderCallAfterIgnoreNoConnection();
    super.setUp();
    // The test SDK's Stream has none of these.
    _write('lib/src/data/rx.dart', r'''
extension Operators on Stream<int> {
  Stream<int> asyncMap(Future<int> Function(int) convert) => this;
  Stream<int> asyncExpand(Stream<int> Function(int) convert) => this;
  Stream<int> map(int Function(int) convert) => this;
  Stream<int> where(bool Function(int) test) => this;
  Stream<int> get refreshed => this;
}
''');
    _write('lib/src/data/sync_engine/util/guards.dart', r'''
extension Guards<T> on Stream<T> {
  Stream<T> ignoreNoConnection() => this;

  Stream<T> onNotFound(void Function() onNotFound, {bool passOn = false}) => this;
}

extension LogBadResponses<T> on Stream<T> {
  Stream<T> logBadResponses({String? context}) => this;
}
''');
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  /// Expects one report, on the last occurrence of [operator] in the reader.
  Future<void> _assertLinted(String body, String operator, {String path = _syncEnginePath}) async {
    final String content = _reader(body);
    final int offset = content.lastIndexOf('.$operator(') + 1;
    await assertDiagnosticsInFile(_write(path, content), [lint(offset, operator.length)]);
  }

  Future<void> test_apiCallAfterGuard() async {
    await _assertLinted('    yield* api().ignoreNoConnection().asyncMap((int id) => fetch(id));', 'asyncMap');
  }

  /// Not every operator after the guard reaches the network, but each could,
  /// and each costs nothing to move in front of it.
  Future<void> test_harmlessOperatorAfterGuard() async {
    await _assertLinted('    yield* api().ignoreNoConnection().where((int id) => id > 0);', 'where');
  }

  Future<void> test_operatorAfterAllowedOperator() async {
    await _assertLinted(
      '    yield* api().ignoreNoConnection().onNotFound(() {}).asyncMap((int id) => fetch(id));',
      'asyncMap',
    );
  }

  /// Reports the operator nearest the guard, once.
  Future<void> test_severalOperatorsAfterGuard() async {
    await _assertLinted(
      '    yield* api().ignoreNoConnection().asyncMap((int id) => fetch(id)).map((int id) => id);',
      'asyncMap',
    );
  }

  Future<void> test_lookalikeAllowedOperator() async {
    const String prelude = r'''
import 'package:test/src/data/sync_engine/util/guards.dart' hide LogBadResponses;

extension on Stream<int> {
  /// Shares a name with the allowed operator, but is not it.
  Stream<int> logBadResponses() => this;
}

''';
    final String content = _reader('    yield* api().ignoreNoConnection().logBadResponses();', prelude: prelude);
    await assertDiagnosticsInFile(_write(_syncEnginePath, content), [
      lint(content.lastIndexOf('logBadResponses'), 'logBadResponses'.length),
    ]);
  }

  Future<void> test_afterConditionalOfGuards() async {
    await _assertLinted(
      '    yield* (flag ? api().ignoreNoConnection() : api().ignoreNoConnection()).asyncMap((int id) => fetch(id));',
      'asyncMap',
    );
  }

  Future<void> test_inConditionalBranch() async {
    await _assertLinted(
      '    yield* flag ? api().ignoreNoConnection().asyncMap((int id) => fetch(id)) : api().ignoreNoConnection();',
      'asyncMap',
    );
  }

  /// A getter runs code too.
  Future<void> test_getterAfterGuard() async {
    final String content = _reader('    yield* api().ignoreNoConnection().refreshed;');
    await assertDiagnosticsInFile(_write(_syncEnginePath, content), [
      lint(content.indexOf('refreshed;'), 'refreshed'.length),
    ]);
  }

  Future<void> test_afterCastOfGuard() async {
    await _assertLinted(
      '    // ignore: unnecessary_cast\n    yield* (api().ignoreNoConnection() as Stream<int>).asyncMap((int id) => fetch(id));',
      'asyncMap',
    );
  }

  Future<void> test_guardThroughExtensionOverride() async {
    await _assertLinted('    yield* Guards(api()).ignoreNoConnection().asyncMap((int id) => fetch(id));', 'asyncMap');
  }

  Future<void> test_operatorThroughExtensionOverride() async {
    final String content = _reader('    yield* Operators(api().ignoreNoConnection()).asyncMap((int id) => fetch(id));');
    await assertDiagnosticsInFile(_write(_syncEnginePath, content), [
      lint(content.indexOf('asyncMap((int id) => fetch'), 'asyncMap'.length),
    ]);
  }

  Future<void> test_getterBeforeGuard() async {
    await assertNoDiagnosticsInFile(
      _write(_syncEnginePath, _reader('    yield* api().refreshed.ignoreNoConnection();')),
    );
  }

  Future<void> test_operatorsBeforeGuard() async {
    await assertNoDiagnosticsInFile(
      _write(
        _syncEnginePath,
        _reader('    yield* api().asyncMap((int id) => fetch(id)).where((int id) => id > 0).ignoreNoConnection();'),
      ),
    );
  }

  Future<void> test_allowedOperatorsAfterGuard() async {
    await assertNoDiagnosticsInFile(
      _write(
        _syncEnginePath,
        _reader(
          '    yield* api().ignoreNoConnection().onNotFound(() {}, passOn: true);\n'
          "    yield* api().ignoreNoConnection().logBadResponses(context: 'tags');",
        ),
      ),
    );
  }

  /// A second guard covers what runs before it.
  Future<void> test_operatorBetweenGuards() async {
    await assertNoDiagnosticsInFile(
      _write(
        _syncEnginePath,
        _reader('    yield* api().ignoreNoConnection().asyncMap((int id) => fetch(id)).ignoreNoConnection();'),
      ),
    );
  }

  /// A chain without a guard is `reader_without_ignore_no_connection`'s.
  Future<void> test_noGuard() async {
    await assertNoDiagnosticsInFile(
      _write(_syncEnginePath, _reader('    yield* api().asyncMap((int id) => fetch(id));')),
    );
  }

  Future<void> test_guardInsideClosure() async {
    await assertNoDiagnosticsInFile(
      _write(
        _syncEnginePath,
        _reader('    yield* api().asyncExpand((int id) => api().ignoreNoConnection().map((int id) => id));'),
      ),
    );
  }

  Future<void> test_classNotAReader() async {
    final String content = _reader(
      '    yield* api().ignoreNoConnection().asyncMap((int id) => fetch(id));',
      name: 'TagsCache',
    );
    await assertNoDiagnosticsInFile(_write(_syncEnginePath, content));
  }

  Future<void> test_readerOutsideSyncEngine() async {
    await assertNoDiagnosticsInFile(
      _write(
        'lib/src/data/services/tags.dart',
        _reader('    yield* api().ignoreNoConnection().asyncMap((int id) => fetch(id));'),
      ),
    );
  }

  Future<void> test_partOfSyncEngineLibrary() async {
    _write('lib/src/data/sync_engine/index.dart', r'''
import 'package:test/src/data/rx.dart';
import 'package:test/src/data/sync_engine/util/guards.dart';

part 'tags.dart';
''');
    const String body = '''
class TagsReader {
  Stream<int> api() async* {}

  Stream<int> read() async* {
    yield* api().ignoreNoConnection().map((int id) => id);
  }
}
''';
    const String content = "part of 'index.dart';\n\n$body";
    await assertDiagnosticsInFile(_write(_syncEnginePath, content), [lint(content.indexOf('map('), 'map'.length)]);
  }
}
