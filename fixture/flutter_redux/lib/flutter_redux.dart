class Store<S> {
  S get state => throw UnimplementedError();
}

class StoreConnector<S, ViewModel> {
  StoreConnector({required ViewModel Function(Store<S> store) converter, bool distinct = false});
}
