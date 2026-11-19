import 'package:flutter/widgets.dart';

import 'app/clipword_app.dart';
import 'app/controller.dart';
import 'native/channel.dart';

Future<void> main() async {
  await boot(settingsWindow: false);
}

@pragma('vm:entry-point')
Future<void> settingsMain() async {
  await boot(settingsWindow: true);
}

Future<void> boot({required bool settingsWindow}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = ClipwordController(ClipwordChannel.instance);
  await controller.start();
  runApp(ClipwordApp(controller: controller, settingsWindow: settingsWindow));
}
