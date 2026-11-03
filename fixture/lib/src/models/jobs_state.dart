import 'package:freezed_annotation/freezed_annotation.dart';

@freezed
abstract class JobsState {
  factory JobsState({required List<int> items}) = JobsState$;

  List<int> get items;
}

/// What freezed generates: the list is wrapped on every read.
class JobsState$ implements JobsState {
  JobsState$({required List<int> items}) : _items = items;

  final List<int> _items;

  @override
  List<int> get items => List<int>.unmodifiable(_items);
}
