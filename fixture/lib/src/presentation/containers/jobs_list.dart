import 'package:flutter_redux/flutter_redux.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:mobile/src/models/jobs_state.dart';
import 'package:mobile/src/util/memo.dart';

final Memo<JobsViewModel> memo = Memo<JobsViewModel>();

Object build() {
  return StoreConnector<JobsState, JobsViewModel>(
    distinct: true,
    converter: (Store<JobsState> store) => memo(<Object?>[store.state], () => JobsViewModel(ids: <int>[])),
  );
}

@freezed
abstract class JobsViewModel {
  factory JobsViewModel({required List<int> ids}) = JobsViewModel$;

  List<int> get ids;
}

class JobsViewModel$ implements JobsViewModel {
  JobsViewModel$({required this.ids});

  @override
  final List<int> ids;
}
