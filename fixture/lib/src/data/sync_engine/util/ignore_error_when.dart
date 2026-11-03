extension IgnoreErrorExtension<T> on Stream<T> {
  Stream<T> ignoreNoConnection() => this;
}
