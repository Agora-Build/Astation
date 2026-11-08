import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/gateway.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AstationApp(gateway: NativeGateway()));
}
