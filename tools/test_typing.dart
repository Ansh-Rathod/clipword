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
  String libId(String suffix) => (iso['result']['libraries'] as List)
      .firstWhere((l) => (l['uri'] as String).endsWith(suffix))['id'] as String;
  final appLib = libId('app/clipword_app.dart');
  final paletteLib = libId('palette/palette_page.dart');

  Future<dynamic> evalAt(String target, String expr) async {
    final r = await call('evaluate', {
      'isolateId': isolateId,
      'targetId': target,
      'expression': expr,
      'disableBreakpoints': true,
    });
    if (r['error'] != null) return 'ERR ${r['error']['message']}';
    final res = r['result'];
    if (res is Map && res.containsKey('valueAsString')) {
      return res['valueAsString'];
    }
    return res;
  }

  Future<String> eval(String expr) async => '${await evalAt(appLib, expr)}';
  Future<String> evalK(String expr) async =>
      '${await evalAt(paletteLib, expr)}';

  const findCtrl = '(() { ClipwordApp? app; void visit(Element e) { '
      'final w = e.widget; if (w is ClipwordApp) app ??= w; '
      'e.visitChildren(visit); } '
      'final root = WidgetsBinding.instance.rootElement; '
      'if (root != null) visit(root); '
      'return app?.controller; })()';

  final ctrl = await evalAt(appLib, findCtrl);
  print('ctrl: ${ctrl is Map ? ctrl['id'] : ctrl}');
  final ctrlId = (ctrl as Map)['id'] as String;

  Future<String> state() async =>
      'mode=${await evalAt(ctrlId, 'windowMode')} '
      'search="${await evalAt(ctrlId, 'snapshot.searchQuery')}" '
      'focus=${await eval('FocusManager.instance.primaryFocus')}';

  print('before: ${await state()}');
  await evalAt(ctrlId, 'channel.showWindow()');
  await Future.delayed(const Duration(seconds: 1));
  print('after showWindow: ${await state()}');

  Future<void> inject(String expr, String label) async {
    final handled = await evalK(
        'HardwareKeyboard.instance.handleKeyEvent($expr)');
    await Future.delayed(const Duration(milliseconds: 80));
    print('$label handled=$handled  ${await state()}');
  }

  Future<void> typeChar(String ch, String logical) => inject(
      'KeyDownEvent(physicalKey: PhysicalKeyboardKey.$logical, '
      'logicalKey: LogicalKeyboardKey.$logical, character: \'$ch\', '
      'timeStamp: Duration.zero, synthesized: false)',
      'type "$ch"');

  Future<void> key(String logical) => inject(
      'KeyDownEvent(physicalKey: PhysicalKeyboardKey.$logical, '
      'logicalKey: LogicalKeyboardKey.$logical, character: null, '
      'timeStamp: Duration.zero, synthesized: false)',
      'key $logical');

  print('\n== typing test ==');
  await typeChar('h', 'keyH');
  await typeChar('i', 'keyI');
  await key('arrowDown');
  await typeChar('x', 'keyX');
  await key('backspace');
  await inject(
      'KeyDownEvent(physicalKey: PhysicalKeyboardKey.metaLeft, '
      'logicalKey: LogicalKeyboardKey.metaLeft, character: null, '
      'timeStamp: Duration.zero, synthesized: false)',
      'meta down');
  await inject(
      'KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, '
      'logicalKey: LogicalKeyboardKey.keyA, character: null, '
      'timeStamp: Duration.zero, synthesized: false)',
      'cmd+a');
  await inject(
      'KeyUpEvent(physicalKey: PhysicalKeyboardKey.metaLeft, '
      'logicalKey: LogicalKeyboardKey.metaLeft, character: null, '
      'timeStamp: Duration.zero, synthesized: false)',
      'meta up');
  await typeChar('y', 'keyY');
  await key('escape');

  await ws.close();
}
