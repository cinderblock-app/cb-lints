import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';

/// Where the app declares `Memo`.
const String memoStubPath = 'lib/src/util/memo.dart';

/// The app's `Memo`, with its API and none of its logic.
const String memoStub = r'''
class Memo<R extends Object> {
  R call(List<Object?> inputs, R Function() compute) => compute();
}
''';

/// Adds a `freezed_annotation` package with the annotation's fields the rules
/// read. Call before `super.setUp()`.
void addFreezedAnnotationPackage(AnalysisRuleTest test) {
  test.newPackage('freezed_annotation').addFile('lib/freezed_annotation.dart', r'''
class Freezed {
  const Freezed({this.copyWith, this.equal});

  final bool? copyWith;
  final bool? equal;
}

const Freezed freezed = Freezed();
''');
}
