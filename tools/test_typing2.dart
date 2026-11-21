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

  // Find controller + palette state via element tree.
  const findObjs = '(() { ClipwordApp? app; dynamic st; void visit(Element e) { '
      'final w = e.widget; if (w is ClipwordApp) app ??= w; '
      'if (e is StatefulElement && w.runtimeType.toString() == "PalettePage") '
      'st ??= e.state; e.visitChildren(visit); } '
      'final root = WidgetsBinding.instance.rootElement; '
      'if (root != null) visit(root); '
      'return [app?.controller, st]; })()';
  final objs = await evalAt(appLib, findObjs);
  final listId = (objs as Map)['id'] as String;
  final items = await call('getObject',
      {'isolateId': isolateId, 'objectId': listId, 'count': 4});
  final elems = items['result']['elements'] as List;
  final ctrlId = elems[0]['id'] as String;
  final stateId = elems[1]['id'] as String;
  print('ctrlId=$ctrlId stateId=$stateId');

  Future<String> state() async =>
      'mode=${await evalAt(ctrlId, 'windowMode')} '
      'search="${await evalAt(ctrlId, 'snapshot.searchQuery')}" '
      'listFocused=${await evalAt(ctrlId, 'listFocused')} '
      'searchHasFocus=${await evalAt(stateId, '_searchFocus.hasFocus')} '
      'pageHasFocus=${await evalAt(stateId, '_pageFocus.hasFocus')} '
      'sel=${await evalAt(stateId, '_search.selection.toString()')}';

  await evalAt(ctrlId, 'channel.showWindow()');
  await Future.delayed(const Duration(milliseconds: 800));
  print('shown: ${await state()}');

  Future<void> inject(String expr, String label) async {
    final handled =
        await evalAt(paletteLib, 'HardwareKeyboard.instance.handleKeyEvent($expr)');
    await Future.delayed(const Duration(milliseconds: 80));
    print('$label handled=$handled  ${await state()}');
  }

  Future<void> typeChar(String ch, String logical) => inject(
      'KeyDownEvent(physicalKey: PhysicalKeyboardKey.$logical, '
      'logicalKey: LogicalKeyboardKey.$logical, character: \'$ch\', '
      'timeStamp: Duration.zero, synthesized: false)',
      'type "$ch"');

  Future<void> keyEv(String kind, String logical, {String? ch}) => inject(
      '${kind}Event(physicalKey: PhysicalKeyboardKey.$logical, '
      'logicalKey: LogicalKeyboardKey.$logical${kind == 'KeyUp' ? '' : ', ${ch == null ? 'character: null' : 'character: \'$ch\''}'}, '
      'timeStamp: Duration.zero, synthesized: false)',
      '$kind $logical');

  print('pressedKeys: ${await evalAt(paletteLib, 'HardwareKeyboard.instance.physicalKeysPressed.toString()')}');

  print('\n== field-focused typing (normal path, should NOT double) ==');
  await typeChar('h', 'keyH');
  await typeChar('i', 'keyI');

  print('\n== move to list focus, then type ==');
  await evalAt(stateId, '_focusList()');
  await Future.delayed(const Duration(milliseconds: 120));
  print('after _focusList: ${await state()}');
  await typeChar('x', 'keyX');
  await typeChar('y', 'keyY');
  await keyEv('KeyDown', 'backspace');

  print('\n== cmd+a (list-focused) ==');
  await evalAt(stateId, '_focusList()');
  await Future.delayed(const Duration(milliseconds: 100));
  await keyEv('KeyDown', 'metaLeft');
  await keyEv('KeyDown', 'keyA');
  await keyEv('KeyUp', 'metaLeft');
  print('after cmd+a: ${await state()}');

  print('\n== cmd+a while SEARCH focused ==');
  await evalAt(stateId, '_focusSearch()');
  await Future.delayed(const Duration(milliseconds: 100));
  await keyEv('KeyDown', 'metaLeft');
  await keyEv('KeyDown', 'keyA');
  await keyEv('KeyUp', 'metaLeft');
  print('after cmd+a: ${await state()}');

  await ws.close();
}
