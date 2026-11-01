import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:mobile/src/data/auth_api.dart';

@RoutePage()
class ProbePage {
  AuthApi? api;

  bool get mac => Platform.isMacOS;
}
