import 'dart:typed_data';

import 'package:clipword_flutter/native/windows/classifier.dart';
import 'package:clipword_flutter/native/windows/hotkeys.dart';
import 'package:clipword_flutter/native/windows/snapshot_codec.dart';
import 'package:clipword_flutter/native/windows/time_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClipSnapshotData codec', () {
    test('text round-trip', () {
      final snap = ClipSnapshotData(
        plainText: 'hello world',
        contentType: ClipContentType.text,
        pasteboardTypes: const ['CF_UNICODETEXT'],
      );
      final decoded = ClipSnapshotData.decode(snap.encode())!;
      expect(decoded.plainText, 'hello world');
      expect(decoded.contentType, ClipContentType.text);
      expect(decoded.pasteboardTypes, ['CF_UNICODETEXT']);
    });

    test('binary blobs round-trip', () {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D]);
      final snap = ClipSnapshotData(
        contentType: ClipContentType.image,
        imageData: png,
      );
      final decoded = ClipSnapshotData.decode(snap.encode())!;
      expect(decoded.imageData, png);
      expect(decoded.contentType, ClipContentType.image);
    });

    test('decode tolerates garbage', () {
      expect(ClipSnapshotData.decode(Uint8List.fromList([1, 2, 3])), isNull);
      // An empty JSON object decodes to a default text snapshot.
      final empty = ClipSnapshotData.decode(Uint8List.fromList('{}'.codeUnits));
      expect(empty?.contentType, ClipContentType.text);
    });
  });

  group('ContentClassifier', () {
    ClipSnapshotData text(String t) =>
        ClipSnapshotData(plainText: t, contentType: ClipContentType.text);

    test('plain text', () {
      expect(ContentClassifier.classify(text('just some words')),
          ClipboardCategory.plainText);
    });

    test('https URL → link', () {
      expect(ContentClassifier.classify(text('https://example.com/x?y=1')),
          ClipboardCategory.link);
    });

    test('URL inside quotes → link', () {
      expect(ContentClassifier.classify(text('"https://example.com"')),
          ClipboardCategory.link);
    });

    test('non-previewable scheme still link-ish', () {
      expect(ContentClassifier.isLinkText('mailto:a@b.c'), isTrue);
      expect(ContentClassifier.linkPreviewURL('mailto:a@b.c'), isNull);
    });

    test('hex color → color', () {
      expect(ContentClassifier.classify(text('#FF8800')),
          ClipboardCategory.color);
      expect(ContentClassifier.classify(text('#fa3')),
          ClipboardCategory.color);
      expect(ContentClassifier.classify(text('rgb(1, 2, 3)')),
          ClipboardCategory.color);
    });

    test('code heuristics → code', () {
      const dart = 'import "dart:io";\nvoid main() {\n  print("hi");\n}\n';
      expect(ContentClassifier.classify(text(dart)), ClipboardCategory.code);
    });

    test('file type → file, image type → image', () {
      expect(
          ContentClassifier.classify(ClipSnapshotData(
              contentType: ClipContentType.file,
              fileURLs: const ['C:/a.txt'])),
          ClipboardCategory.file);
      expect(
          ContentClassifier.classify(
              ClipSnapshotData(contentType: ClipContentType.image)),
          ClipboardCategory.image);
    });
  });

  group('HistoryTimeFilter', () {
    final now = DateTime(2026, 11, 20, 15, 30);

    test('any contains everything', () {
      expect(HistoryTimeFilter.any.contains(DateTime(2000), now: now), isTrue);
    });

    test('today matches same calendar day only', () {
      expect(
          HistoryTimeFilter.today.contains(DateTime(2026, 11, 20, 0, 1),
              now: now),
          isTrue);
      expect(
          HistoryTimeFilter.today.contains(DateTime(2026, 11, 19, 23, 59),
              now: now),
          isFalse);
    });

    test('yesterday', () {
      expect(
          HistoryTimeFilter.yesterday.contains(DateTime(2026, 11, 19, 12),
              now: now),
          isTrue);
      expect(
          HistoryTimeFilter.yesterday.contains(DateTime(2026, 11, 20, 12),
              now: now),
          isFalse);
    });

    test('last7Days covers today and six days back', () {
      expect(
          HistoryTimeFilter.last7Days.contains(DateTime(2026, 11, 14),
              now: now),
          isTrue);
      expect(
          HistoryTimeFilter.last7Days.contains(DateTime(2026, 11, 13, 23, 59),
              now: now),
          isFalse);
    });

    test('spanning normalizes reversed range', () {
      final f = HistoryTimeFilter.spanning(
          DateTime(2026, 11, 10), DateTime(2026, 11, 5));
      expect(f.contains(DateTime(2026, 11, 7), now: now), isTrue);
      expect(f.contains(DateTime(2026, 11, 4), now: now), isFalse);
    });

    test('days encode/decode round-trip', () {
      final f = HistoryTimeFilter.spanning(
          DateTime(2026, 11, 1), DateTime(2026, 11, 10));
      final back = HistoryTimeFilter.decode(f.encode());
      expect(back.kind, TimeFilterKind.days);
      expect(back.contains(DateTime(2026, 11, 5), now: now), isTrue);
      expect(back.contains(DateTime(2026, 11, 12), now: now), isFalse);
    });
  });

  group('WinHotkeys', () {
    test('vkFor maps letters/digits/named keys', () {
      expect(WinHotkeys.vkFor('v'), 0x56);
      expect(WinHotkeys.vkFor('a'), 0x41);
      expect(WinHotkeys.vkFor('5'), 0x35);
      expect(WinHotkeys.vkFor('f5'), 0x74);
      expect(WinHotkeys.vkFor('space'), 0x20);
      expect(WinHotkeys.vkFor('comma'), 0xBC);
      expect(WinHotkeys.vkFor('nonsense'), isNull);
    });

    test('labelFor renders modifier order', () {
      expect(WinHotkeys.labelFor(null), 'Ctrl+Shift+Alt+V');
      expect(
          WinHotkeys.labelFor({
            'key': 'f4',
            'modifiers': ['ctrl', 'win']
          }),
          'Ctrl+Win+F4');
      expect(
          WinHotkeys.labelFor({
            'key': 'v',
            'modifiers': ['ctrl', 'alt', 'shift']
          }),
          'Ctrl+Shift+Alt+V');
    });
  });
}
