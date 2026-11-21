import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
