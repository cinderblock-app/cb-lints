class TagsReader {
  Stream<int> api() async* {}

  Stream<int> read() async* {
    yield* api();
  }
}
