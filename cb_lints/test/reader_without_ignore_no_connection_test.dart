// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/reader_without_ignore_no_connection.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ReaderWithoutIgnoreNoConnectionTest);
  });
}

const String _prelude = r'''
extension on Stream<int> {
  Stream<int> ignoreNoConnection() => this;
  Stream<int> notEquals(int value) => this;
  Stream<int> guarded(Stream<int> Function() body) => this;
}

''';

String _reader(String body, {String name = 'TagsReader'}) {
  return '$_prelude'
      'class $name {\n'
      '  Stream<int> api() async* {}\n'
      '  Stream<int> read(bool flag) async* {\n'
      '    yield 1;\n'
      '$body\n'
      '  }\n'
      '}\n';
}

const String _syncEnginePath = 'lib/src/data/sync_engine/tags.dart';

@reflectiveTest
class ReaderWithoutIgnoreNoConnectionTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = ReaderWithoutIgnoreNoConnection();
    super.setUp();
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  Future<void> _assertLinted(String content, {String path = _syncEnginePath}) async {
    await assertDiagnosticsInFile(_write(path, content), [lint(content.indexOf('yield*'), 'yield'.length)]);
  }

  Future<void> test_chainEndingInIgnoreNoConnection() async {
    await assertNoDiagnosticsInFile(
      _write(_syncEnginePath, _reader('    yield* api().notEquals(1).ignoreNoConnection();')),
    );
  }

  Future<void> test_chainContinuingAfterIgnoreNoConnection() async {
    await assertNoDiagnosticsInFile(
      _write(_syncEnginePath, _reader('    yield* api().ignoreNoConnection().notEquals(1);')),
    );
  }

  Future<void> test_chainWithoutIgnoreNoConnection() async {
    await _assertLinted(_reader('    yield* api().notEquals(1);'));
  }

  Future<void> test_bareStream() async {
    await _assertLinted(_reader('    yield* api();'));
  }

  Future<void> test_ignoreNoConnectionOnlyInsideClosure() async {
    await _assertLinted(_reader('    yield* api().guarded(() => api().ignoreNoConnection());'));
  }

  Future<void> test_parenthesized() async {
    await assertNoDiagnosticsInFile(
      _write(_syncEnginePath, _reader('    yield* (api().notEquals(1)).ignoreNoConnection();')),
    );
  }

  Future<void> test_conditionalBothGuarded() async {
    await assertNoDiagnosticsInFile(
      _write(_syncEnginePath, _reader('    yield* flag ? api().ignoreNoConnection() : api().ignoreNoConnection();')),
    );
  }

  Future<void> test_conditionalOneUnguarded() async {
    await _assertLinted(_reader('    yield* flag ? api().ignoreNoConnection() : api();'));
  }

  Future<void> test_plainYield() async {
    await assertNoDiagnosticsInFile(_write(_syncEnginePath, _reader('    yield 2;')));
  }

  Future<void> test_classNotAReader() async {
    await assertNoDiagnosticsInFile(_write(_syncEnginePath, _reader('    yield* api();', name: 'TagsCache')));
  }

  Future<void> test_readerOutsideSyncEngine() async {
    await assertNoDiagnosticsInFile(_write('lib/src/data/services/tags.dart', _reader('    yield* api();')));
  }

  Future<void> test_partOfSyncEngineLibrary() async {
    _write('lib/src/data/sync_engine/index.dart', r'''
part 'tags.dart';
''');
    final String content = "part of 'index.dart';\n\n${_reader('    yield* api();')}";
    await _assertLinted(content);
  }
}
