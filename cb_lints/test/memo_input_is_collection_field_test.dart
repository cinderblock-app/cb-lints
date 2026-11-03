// test_reflective_loader runs the methods whose names start with `test_`.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:cb_lints/src/memo_input_is_collection_field.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'stubs.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(MemoInputIsCollectionFieldTest);
  });
}

const String _imports = r'''
import 'package:test/src/models/state.dart';
import 'package:test/src/util/memo.dart';

''';

const String _path = 'lib/src/presentation/containers/jobs.dart';

/// A converter with [inputs] as the memo's inputs, given `state` and `memo`.
String _converter(String inputs) {
  return '''
${_imports}final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(AppState state, {bool flag = false}) {
  return memo(<Object?>[$inputs], () => <int>[]);
}
''';
}

@reflectiveTest
class MemoInputIsCollectionFieldTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = MemoInputIsCollectionField();
    addFreezedAnnotationPackage(this);
    super.setUp();
    _write(memoStubPath, memoStub);
    _write('lib/src/models/state.dart', r'''
import 'package:freezed_annotation/freezed_annotation.dart';

/// Shaped like freezed's output: the generated class stores a scalar, a nested
/// state object and a collection kept as is, and wraps the other collection
/// in a getter.
@freezed
abstract class AppointmentsState {
  const factory AppointmentsState({
    required Map<String, int> allAppointments,
    required List<int> kept,
    required int count,
  }) = AppointmentsState$;

  const AppointmentsState._();

  Map<String, int> get allAppointments;

  List<int> get kept;

  int get count;

  /// Written by hand, so not one freezed generated.
  List<int> get sorted => kept.toList()..sort();
}

class AppointmentsState$ extends AppointmentsState {
  const AppointmentsState$({required Map<String, int> allAppointments, required this.kept, required this.count})
    : _allAppointments = allAppointments,
      super._();

  final Map<String, int> _allAppointments;

  @override
  Map<String, int> get allAppointments => Map<String, int>.unmodifiable(_allAppointments);

  @override
  final List<int> kept;

  @override
  final int count;
}

@freezed
abstract class AppState {
  const factory AppState({required AppointmentsState appointments}) = AppState$;

  AppointmentsState get appointments;
}

class AppState$ implements AppState {
  const AppState$({required this.appointments});

  @override
  final AppointmentsState appointments;
}

/// Not freezed, though its getter wraps the same way.
class Cache {
  Cache(this._items);

  final List<int> _items;

  List<int> get items => List<int>.unmodifiable(_items);
}
''');
  }

  String _write(String localPath, String content) {
    final path = convertPath('$testPackageRootPath/$localPath');
    newFile(path, content);
    return path;
  }

  Future<void> _assertLinted(String content, String reported, {String path = _path}) async {
    await assertDiagnosticsInFile(_write(path, content), [lint(content.indexOf(reported), reported.length)]);
  }

  Future<void> test_propertyAccess() async {
    await _assertLinted(_converter('state.appointments.allAppointments'), 'state.appointments.allAppointments');
  }

  Future<void> test_prefixedIdentifier() async {
    const String content =
        '''
${_imports}final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(AppointmentsState appointments) {
  return memo(<Object?>[appointments.allAppointments], () => <int>[]);
}
''';
    await assertDiagnosticsInFile(_write(_path, content), [
      lint(content.indexOf('appointments.allAppointments]'), 'appointments.allAppointments'.length),
    ]);
  }

  Future<void> test_memoField() async {
    const String content =
        '''
${_imports}class Container {
  final Memo<List<int>> _memo = Memo<List<int>>();

  List<int> convert(AppState state) {
    return _memo(<Object?>[(state.appointments.allAppointments), 1], () => <int>[]);
  }
}
''';
    await _assertLinted(content, 'state.appointments.allAppointments');
  }

  Future<void> test_memoInList() async {
    const String content =
        '''
${_imports}final List<Memo<List<int>>> memos = <Memo<List<int>>>[Memo<List<int>>()];

List<int> convert(AppState state) {
  return memos[0](<Object?>[state.appointments.allAppointments], () => <int>[]);
}
''';
    await _assertLinted(content, 'state.appointments.allAppointments');
  }

  Future<void> test_explicitCall() async {
    const String content =
        '''
${_imports}final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(AppState state) {
  return memo.call(<Object?>[state.appointments.allAppointments], () => <int>[]);
}
''';
    await _assertLinted(content, 'state.appointments.allAppointments');
  }

  Future<void> test_inIfElement() async {
    await _assertLinted(
      _converter('if (state.appointments.count > 0) state.appointments.allAppointments'),
      'state.appointments.allAppointments',
    );
  }

  /// A memo body over [statements] whose inputs are [inputs].
  String _hoisted(String statements, String inputs) {
    return '''
${_imports}final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(AppState state, AppState? maybe, bool flag) {
$statements
  return memo($inputs, () => <int>[]);
}
''';
  }

  Future<void> _assertLintedAt(String content, String reported) async {
    await assertDiagnosticsInFile(_write(_path, content), [lint(content.lastIndexOf(reported), reported.length)]);
  }

  Future<void> test_finalLocal() async {
    await _assertLintedAt(
      _hoisted('  final Map<String, int> all = state.appointments.allAppointments;', '<Object?>[all]'),
      'all',
    );
  }

  Future<void> test_finalLocalOfFinalLocal() async {
    await _assertLintedAt(
      _hoisted(
        '  final AppointmentsState appointments = state.appointments;\n'
            '  final Map<String, int> all = appointments.allAppointments;',
        '<Object?>[all]',
      ),
      'all',
    );
  }

  Future<void> test_inputsInFinalLocal() async {
    final String content = _hoisted(
      '  final List<Object?> inputs = <Object?>[state.appointments.allAppointments];',
      'inputs',
    );
    await _assertLintedAt(content, 'state.appointments.allAppointments');
  }

  Future<void> test_conditionalBranch() async {
    await _assertLintedAt(
      _converter('flag ? state.appointments : state.appointments.allAppointments'),
      'flag ? state.appointments : state.appointments.allAppointments',
    );
  }

  Future<void> test_nullCheck() async {
    await _assertLintedAt(
      _hoisted('', '<Object?>[(maybe?.appointments.allAppointments)!]'),
      '(maybe?.appointments.allAppointments)!',
    );
  }

  Future<void> test_valuesOfField() async {
    await _assertLintedAt(
      _converter('state.appointments.allAppointments.values'),
      'state.appointments.allAppointments.values',
    );
  }

  Future<void> test_copyOfField() async {
    await _assertLintedAt(
      _hoisted('  final Map<String, int> all = state.appointments.allAppointments;', '<Object?>[all.keys.toList()]'),
      'all.keys.toList()',
    );
  }

  /// A local that is not final could hold something else by the call.
  Future<void> test_nonFinalLocal() async {
    await assertNoDiagnosticsInFile(
      _write(
        _path,
        _hoisted(
          '  Object? all = state.appointments.allAppointments;\n'
              '  all = state.appointments;',
          '<Object?>[all]',
        ),
      ),
    );
  }

  Future<void> test_finalLocalOfStateObject() async {
    await assertNoDiagnosticsInFile(
      _write(
        _path,
        _hoisted('  final AppointmentsState appointments = state.appointments;', '<Object?>[appointments]'),
      ),
    );
  }

  Future<void> test_conditionalOfStoredFields() async {
    await assertNoDiagnosticsInFile(
      _write(_path, _converter('flag ? state.appointments.kept : state.appointments.count')),
    );
  }

  Future<void> test_valuesOfStoredField() async {
    await assertNoDiagnosticsInFile(_write(_path, _converter('state.appointments.kept.toList()')));
  }

  Future<void> test_stateObject() async {
    await assertNoDiagnosticsInFile(_write(_path, _converter('state.appointments, state')));
  }

  Future<void> test_scalarField() async {
    await assertNoDiagnosticsInFile(_write(_path, _converter('state.appointments.count')));
  }

  /// With `makeCollectionsUnmodifiable: false` freezed stores the collection.
  Future<void> test_collectionStoredAsIs() async {
    await assertNoDiagnosticsInFile(_write(_path, _converter('state.appointments.kept')));
  }

  Future<void> test_handWrittenGetter() async {
    await assertNoDiagnosticsInFile(_write(_path, _converter('state.appointments.sorted')));
  }

  Future<void> test_notFreezed() async {
    const String content =
        '''
${_imports}final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(Cache cache) {
  return memo(<Object?>[cache.items], () => <int>[]);
}
''';
    await assertNoDiagnosticsInFile(_write(_path, content));
  }

  /// Only the inputs are checked: the compute function may read anything.
  Future<void> test_readInCompute() async {
    const String content =
        '''
${_imports}final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(AppState state) {
  return memo(<Object?>[state.appointments], () => state.appointments.allAppointments.values.toList());
}
''';
    await assertNoDiagnosticsInFile(_write(_path, content));
  }

  Future<void> test_otherMemoClass() async {
    _write('lib/src/other/memo.dart', memoStub);
    const String content = r'''
import 'package:test/src/models/state.dart';
import 'package:test/src/other/memo.dart';

final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(AppState state) {
  return memo(<Object?>[state.appointments.allAppointments], () => <int>[]);
}
''';
    await assertNoDiagnosticsInFile(_write(_path, content));
  }

  Future<void> test_inTest() async {
    await assertNoDiagnosticsInFile(
      _write('test/src/presentation/jobs_test.dart', _converter('state.appointments.allAppointments')),
    );
  }
}
