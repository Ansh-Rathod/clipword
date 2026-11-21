import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
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
  final isolateId = (vm['result']['isolates'] as List).first['id'] as String;
  final iso = await call('getIsolate', {'isolateId': isolateId});
  final backend = (iso['result']['libraries'] as List).firstWhere(
    (l) =>
        (l['uri'] as String).endsWith('native/method_channel_backend.dart'),
  )['id'] as String;

  Future<void> eval(String label, String expr) async {
    final r = await call('evaluate', {
      'isolateId': isolateId,
      'targetId': backend,
      'expression': expr,
      'disableBreakpoints': true,
    });
    final res = r['result'];
    print('$label: ${res is Map ? (res['valueAsString'] ?? res) : res}');
  }

  await eval('primaryFocus', 'FocusManager.instance.primaryFocus?.toString()');
  await eval('rootScope.hasFocus',
      'FocusManager.instance.rootScope.hasFocus.toString()');
  await eval('appLifecycleState',
      'ServicesBinding.instance.lifecycleState.toString()');
  await ws.close();
}
