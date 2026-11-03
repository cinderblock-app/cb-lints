import 'package:mobile/src/data/sync_engine/util/ignore_error_when.dart';

class TagsReader {
  Stream<int> api() async* {}

  Stream<int> read() async* {
    yield* api();
  }

  Stream<int> readAfterGuard() async* {
    yield* api().ignoreNoConnection().asyncMap((int id) async => id);
  }
}
