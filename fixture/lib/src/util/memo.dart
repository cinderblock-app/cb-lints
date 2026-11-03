class Memo<R extends Object> {
  R call(List<Object?> inputs, R Function() compute) => compute();
}
