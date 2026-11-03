import 'package:mobile/src/models/jobs_state.dart';
import 'package:mobile/src/util/memo.dart';

final Memo<List<int>> memo = Memo<List<int>>();

List<int> convert(JobsState state) => memo(<Object?>[state.items], () => state.items.toList());
