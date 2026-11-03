// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/memo_distinct_needs_identity_equality.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'stubs.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(MemoDistinctNeedsIdentityEqualityTest);
  });
}

/// A freezed view model named [name] under [annotation], with [fields] as
/// `type name` pairs, shaped like freezed's output.
String _viewModel(String name, String annotation, Map<String, String> fields) {
  final String parameters = fields.entries.map((e) => 'required ${e.value} ${e.key}').join(', ');
  final String getters = fields.entries.map((e) => '  ${e.value} get ${e.key};\n').join();
  final String initializers = fields.keys.map((String field) => 'required this.$field').join(', ');
  final String finals = fields.entries.map((e) => '  @override\n  final ${e.value} ${e.key};\n').join();
  return '''
$annotation
abstract class $name {
  factory $name({$parameters}) = $name\$;

$getters}

class $name\$ implements $name {
  $name\$({$initializers});

$finals}
''';
}

const String _imports = r'''
import 'package:flutter_redux/flutter_redux.dart';
import 'package:test/src/models/view_models.dart';
import 'package:test/src/util/memo.dart';

''';

const String _path = 'lib/src/presentation/containers/jobs.dart';

/// A connector for [viewModel] with [arguments] before its converter, whose
/// converter returns [body].
String _connector(String viewModel, String body, {String arguments = 'distinct: true, '}) {
  return '''
${_imports}final Memo<$viewModel> memo = Memo<$viewModel>();
final Memo<List<int>> listMemo = Memo<List<int>>();

Object build() {
  return StoreConnector<int, $viewModel>(
    ${arguments}converter: (Store<int> store) {
      return $body;
    },
  );
}
''';
}

@reflectiveTest
class MemoDistinctNeedsIdentityEqualityTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = MemoDistinctNeedsIdentityEquality();
    addFreezedAnnotationPackage(this);
    newPackage('flutter_redux').addFile('lib/flutter_redux.dart', r'''
class Store<S> {
  S get state => throw UnimplementedError();
}

class StoreConnector<S, ViewModel> {
  StoreConnector({required ViewModel Function(Store<S> store) converter, bool distinct = false});
}
''');
    super.setUp();
    _write(memoStubPath, memoStub);
    _write(
      'lib/src/models/view_models.dart',
      "import 'package:freezed_annotation/freezed_annotation.dart';\n\n"
          'const Freezed noCopyFreezed = Freezed(copyWith: false);\n\n'
          '${_viewModel('ListViewModel', '@Freezed(copyWith: false)', {'items': 'List<int>', 'isLoading': 'bool'})}\n'
          '${_viewModel('MapViewModel', '@freezed', {'users': 'Map<String, int>'})}\n'
          '${_viewModel('SetViewModel', '@noCopyFreezed', {'ids': 'Set<int>'})}\n'
          '${_viewModel('IdentityViewModel', '@Freezed(copyWith: false, equal: false)', {'items': 'List<int>'})}\n'
          '${_viewModel('CountersViewModel', '@noCopyFreezed', {'count': 'int', 'total': 'int'})}\n'
          '${_viewModel('PlainViewModel', '', {'items': 'List<int>'})}',
    );
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  Future<void> _assertLinted(String content) async {
    await assertDiagnosticsInFile(_write(_path, content), [
      lint(content.indexOf('distinct: true'), 'distinct: true'.length),
    ]);
  }

  String _memoOf(String viewModel, String construction) => 'memo(<Object?>[store.state], () => $construction)';

  Future<void> test_listField() async {
    await _assertLinted(
      _connector('ListViewModel', _memoOf('ListViewModel', 'ListViewModel(items: <int>[], isLoading: false)')),
    );
  }

  Future<void> test_mapFieldUnderFreezedConstant() async {
    await _assertLinted(_connector('MapViewModel', _memoOf('MapViewModel', 'MapViewModel(users: <String, int>{})')));
  }

  Future<void> test_setFieldUnderAppConstant() async {
    await _assertLinted(_connector('SetViewModel', _memoOf('SetViewModel', 'SetViewModel(ids: <int>{})')));
  }

  Future<void> test_memoNestedInConverter() async {
    const String body =
        'store.state > 0 ? memo(<Object?>[store.state], () => ListViewModel(items: <int>[], isLoading: false)) : ListViewModel(items: <int>[], isLoading: true)';
    await _assertLinted(_connector('ListViewModel', body));
  }

  Future<void> test_identityEquality() async {
    await assertNoDiagnosticsInFile(
      _write(_path, _connector('IdentityViewModel', _memoOf('IdentityViewModel', 'IdentityViewModel(items: <int>[])'))),
    );
  }

  /// Comparing a few ints is cheaper than a rebuild.
  Future<void> test_scalarsOnly() async {
    await assertNoDiagnosticsInFile(
      _write(
        _path,
        _connector('CountersViewModel', _memoOf('CountersViewModel', 'CountersViewModel(count: 1, total: 2)')),
      ),
    );
  }

  Future<void> test_notFreezed() async {
    await assertNoDiagnosticsInFile(
      _write(_path, _connector('PlainViewModel', _memoOf('PlainViewModel', 'PlainViewModel(items: <int>[])'))),
    );
  }

  /// Without a memo, value equality is what lets `distinct` skip a rebuild.
  Future<void> test_noMemo() async {
    await assertNoDiagnosticsInFile(
      _write(_path, _connector('ListViewModel', 'ListViewModel(items: <int>[], isLoading: false)')),
    );
  }

  /// A memo of something else, wrapped in a new view model on every call.
  Future<void> test_memoOfAnotherType() async {
    const String body = 'ListViewModel(items: listMemo(<Object?>[store.state], () => <int>[]), isLoading: false)';
    await assertNoDiagnosticsInFile(_write(_path, _connector('ListViewModel', body)));
  }

  Future<void> test_notDistinct() async {
    final String body = _memoOf('ListViewModel', 'ListViewModel(items: <int>[], isLoading: false)');
    await assertNoDiagnosticsInFile(_write(_path, _connector('ListViewModel', body, arguments: '')));
    await assertNoDiagnosticsInFile(_write(_path, _connector('ListViewModel', body, arguments: 'distinct: false, ')));
  }

  Future<void> test_inTest() async {
    await assertNoDiagnosticsInFile(
      _write(
        'test/src/presentation/jobs_test.dart',
        _connector('ListViewModel', _memoOf('ListViewModel', 'ListViewModel(items: <int>[], isLoading: false)')),
      ),
    );
  }
}
