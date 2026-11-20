import 'package:flutter/widgets.dart';

import 'app/clipword_app.dart';
import 'app/controller.dart';
import 'native/channel.dart';

Future<void> main() async {
  await boot(settingsWindow: false);
}

/// macOS-only second-engine entrypoint; Windows renders settings in the
/// same window via `windowMode == 'settings'` and never uses this.
@pragma('vm:entry-point')
Future<void> settingsMain() async {
  await boot(settingsWindow: true);
}

Future<void> boot({required bool settingsWindow}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await ClipwordChannel.instance.init();
  final controller = ClipwordController(ClipwordChannel.instance);
  await controller.start();
  runApp(ClipwordApp(controller: controller, settingsWindow: settingsWindow));
}
