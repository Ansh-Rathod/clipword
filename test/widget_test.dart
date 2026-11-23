import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Palette rows pair Listener.onPointerDown (select) with
  // GestureDetector.onDoubleTap (activate). onTapDown can't be used: beside
  // onDoubleTap, a quick click stalls ~300ms waiting out the double-tap
  // arena, and even alone it defers behind kPressTimeout (100ms).
  testWidgets('pointer-down selects instantly next to onDoubleTap', (
    tester,
  ) async {
    var selects = 0;
    var activates = 0;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => Center(
          child: Listener(
            onPointerDown: (event) {
              if (event.buttons & kPrimaryButton != 0) selects++;
            },
            child: GestureDetector(
              onDoubleTap: () => activates++,
              child: const ColoredBox(
                color: Color(0xFF111111),
                child: SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ),
    );

    final target = find.byType(GestureDetector);
    final center = tester.getCenter(target);

    // Quick click: selection lands on the down frame, not after the
    // double-tap timeout.
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(selects, 1);
    await gesture.up();
    await tester.pump(kDoubleTapTimeout);
    expect(activates, 0);

    // Right-click does not select.
    final secondary = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await secondary.up();
    await tester.pump();
    expect(selects, 1);

    // A second tap inside the window still activates via onDoubleTap.
    // (> kDoubleTapMinTime so it isn't rejected as a too-fast repeat.)
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(target);
    // Flush the recognizer's 40ms min-time tracker so no timer is pending.
    await tester.pump(const Duration(milliseconds: 100));
    expect(activates, 1);
    expect(selects, 3);
  });
  // The app uses WidgetsApp with a builder that ignores the Navigator child,
  // so no Overlay exists unless one is added. EditableText requires an Overlay
  // ancestor for its selection overlay — this test guards the regression.
  testWidgets('EditableText inside app shell finds an Overlay', (tester) async {
    final controller = TextEditingController(text: 'hello');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder: (context, _) => Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) => Center(
                child: SizedBox(
                  width: 200,
                  child: EditableText(
                    controller: controller,
                    focusNode: focusNode,
                    style: const TextStyle(fontSize: 14),
                    cursorColor: const Color(0xFF000000),
                    backgroundCursorColor: const Color(0xFF888888),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);

    // A second tap at the same spot on the unfocused field produces an
    // unchanged TextEditingValue, which triggers _createSelectionOverlay —
    // the code path that asserts an Overlay ancestor exists.
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    focusNode.unfocus();
    await tester.pump();
    await tester.tap(find.byType(EditableText));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
