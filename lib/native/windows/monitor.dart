import 'dart:async';

import 'clipboard.dart';

/// Port of `ClipboardMonitor` — polls `GetClipboardSequenceNumber` on a timer.
class ClipboardMonitor {
  ClipboardMonitor({this.interval = const Duration(milliseconds: 500)});

  final Duration interval;
  Timer? _timer;
  int? _lastSequence;
  void Function()? onChanged;

  void start() {
    stop();
    _lastSequence = WinClipboard.sequenceNumber();
    _timer = Timer.periodic(interval, (_) {
      final seq = WinClipboard.sequenceNumber();
      if (seq != _lastSequence) {
        _lastSequence = seq;
        onChanged?.call();
      }
    });
  }

  void stop() => _timer?.cancel();
}
