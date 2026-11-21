// Typing-latency driver: talks to the running app's VM service over WebSocket.
// Usage: dart tools/measure_typing.dart <vm-service-ws-url>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

int _now() => DateTime.now().microsecondsSinceEpoch;

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart measure_typing.dart <ws-url>');
    exit(1);
  }
  final ws = await WebSocket.connect(args[0]);
  var id = 0;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  ws.listen((data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    pending.remove(msg['id'])?.complete(msg);
  });

  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic>? params]) {
    final rid = ++id;
    final c = Completer<Map<String, dynamic>>();
    pending[rid] = c;
    ws.add(jsonEncode(
        {'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params ?? {}}));
    return c.future;
  }

  final vm = await call('getVM');
  final isolateId =
      (vm['result']['isolates'] as List).first['id'] as String;
  final iso = await call('getIsolate', {'isolateId': isolateId});
  final libs = iso['result']['libraries'] as List;
  final backend = libs.firstWhere(
    (l) => (l['uri'] as String).endsWith('native/method_channel_backend.dart'),
    orElse: () => iso['result']['rootLib'],
  )['id'] as String;
  print('isolate=$isolateId targetLib=$backend');

  Future<Map<String, dynamic>> eval(String expr) {
    final t = _now();
    return call('evaluate', {
      'isolateId': isolateId,
      'targetId': backend,
      'expression': expr,
      'disableBreakpoints': true,
    }).then((r) => {...r, '_wallUs': _now() - t});
  }

  String brief(Map<String, dynamic> r) {
    final res = r['result'];
    if (res is Map && res.containsKey('error')) return 'ERR ${res['error']}';
    if (res is Map && res['result'] is Map) {
      final i = res['result'];
      return '${i['kind']} ${i['valueAsString'] ?? i['text'] ?? i['id'] ?? ''}';
    }
    return '$res';
  }

  String keyExpr(String logical, String physical, String ch) =>
      "HardwareKeyboard.instance.handleKeyEvent(const KeyDownEvent("
      "physicalKey: PhysicalKeyboardKey.$physical, "
      "logicalKey: LogicalKeyboardKey.$logical, "
      "${ch.isEmpty ? '' : "character: '$ch', "}"
      "timeStamp: Duration.zero))";

  String logicalFor(String c) => 'key${c.toUpperCase()}';
  String physicalFor(String c) => 'key${c.toUpperCase()}';

  // 1) show the palette window so windowMode becomes 'palette'
  var r = await eval(
      "const MethodChannel('clipword').invokeMethod('showWindow', {'source': 'history'})");
  print('showWindow ${brief(r)} wall=${r['_wallUs']}us');
  await Future.delayed(const Duration(milliseconds: 900));

  // 2) arrow down -> list takes focus (exercises the unfocused-typing path)
  r = await eval(keyExpr('arrowDown', 'arrowDown', ''));
  print('arrowDown ${brief(r)} wall=${r['_wallUs']}us');
  await Future.delayed(const Duration(milliseconds: 250));

  // PHASE A: injected keystrokes — first char goes through the new routing,
  // subsequent chars land in the now-focused EditableText (same native path).
  print('=== PHASE A: injected keystrokes ===');
  for (final ch in 'clipboardx'.split('')) {
    final t = _now();
    final res = await eval(keyExpr(logicalFor(ch), physicalFor(ch), ch));
    print(
        '[MEAS] keysend c=$ch t=$t evalWall=${res['_wallUs']}us ${brief(res)}');
    await Future.delayed(const Duration(milliseconds: 140));
  }
  await Future.delayed(const Duration(milliseconds: 700));

  // PHASE B: direct setSearch calls — isolates channel+native+snapshot with
  // zero Dart-side key handling (baseline for the shared path).
  print('=== PHASE B: direct invokeMethod setSearch ===');
  for (var i = 0; i < 8; i++) {
    final q = 'bench$i';
    final t = _now();
    final res = await eval(
        "const MethodChannel('clipword').invokeMethod('setSearch', {'query': '$q'})");
    print(
        '[MEAS] invsend q=$q t=$t evalWall=${res['_wallUs']}us ${brief(res)}');
    await Future.delayed(const Duration(milliseconds: 140));
  }
  await Future.delayed(const Duration(milliseconds: 700));

  // restore empty query
  await eval(
      "const MethodChannel('clipword').invokeMethod('setSearch', {'query': ''})");
  print('done');
  await ws.close();
}
