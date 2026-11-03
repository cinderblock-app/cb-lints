abstract class ListenForConnectivity {
  const factory ListenForConnectivity.event({required bool isConnected}) = OnConnectivityEvent;
}

class OnConnectivityEvent implements ListenForConnectivity {
  const OnConnectivityEvent({required this.isConnected});

  final bool isConnected;
}
