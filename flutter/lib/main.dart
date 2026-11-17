import 'package:flutter/widgets.dart';

import 'app/clipword_app.dart';
import 'app/controller.dart';
import 'native/channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = ClipwordController(ClipwordChannel.instance);
  await controller.start();
  runApp(ClipwordApp(controller: controller));
}
