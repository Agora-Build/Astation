import 'package:flutter/material.dart';

import 'preview/preview_gateway.dart';
import 'src/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AstationApp(gateway: PreviewGateway()));
}
