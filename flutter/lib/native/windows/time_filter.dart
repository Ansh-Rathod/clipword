/// Port of `HistoryTimeFilter` (pure logic, same day-boundary semantics).
enum TimeFilterKind { any, today, yesterday, last7Days, thisMonth, days }

class HistoryTimeFilter {
  const HistoryTimeFilter._(this.kind, {this.from, this.to});

  final TimeFilterKind kind;
  final DateTime? from;
  final DateTime? to;

  static const any = HistoryTimeFilter._(TimeFilterKind.any);
  static const today = HistoryTimeFilter._(TimeFilterKind.today);
  static const yesterday = HistoryTimeFilter._(TimeFilterKind.yesterday);
  static const last7Days = HistoryTimeFilter._(TimeFilterKind.last7Days);
  static const thisMonth = HistoryTimeFilter._(TimeFilterKind.thisMonth);

  static HistoryTimeFilter spanning(DateTime from, DateTime to) {
    var start = DateTime(from.year, from.month, from.day);
    var end = DateTime(to.year, to.month, to.day);
    if (start.isAfter(end)) {
      final t = start;
      start = end;
      end = t;
    }
    return HistoryTimeFilter._(TimeFilterKind.days, from: start, to: end);
  }

  bool get isActive => kind != TimeFilterKind.any;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  bool contains(DateTime date, {DateTime? now}) {
    now ??= DateTime.now();
    switch (kind) {
      case TimeFilterKind.any:
        return true;
      case TimeFilterKind.today:
        return _day(date) == _day(now);
      case TimeFilterKind.yesterday:
        return _day(date) == _day(now).subtract(const Duration(days: 1));
      case TimeFilterKind.last7Days:
        return !date.isBefore(_day(now).subtract(const Duration(days: 6)));
      case TimeFilterKind.thisMonth:
        return date.year == now.year && date.month == now.month;
      case TimeFilterKind.days:
        final day = _day(date);
        return !day.isBefore(from!) && !day.isAfter(to!);
    }
  }

  /// Decode the args map sent by the Dart side (`TimeFilter.toArgs()`).
  static HistoryTimeFilter decode(Map<String, Object?> args) {
    switch (args['kind']) {
      case 'today':
        return today;
      case 'yesterday':
        return yesterday;
      case 'last7Days':
        return last7Days;
      case 'thisMonth':
        return thisMonth;
      case 'days':
        final from = (args['from'] as num?)?.toDouble() ?? 0;
        final to = (args['to'] as num?)?.toDouble() ?? 0;
        return spanning(
          DateTime.fromMillisecondsSinceEpoch((from * 1000).round()),
          DateTime.fromMillisecondsSinceEpoch((to * 1000).round()),
        );
      default:
        return any;
    }
  }

  /// Encode for the snapshot payload (mirrors `encodeTimeFilter`).
  Map<String, Object?> encode() => switch (kind) {
        TimeFilterKind.days => {
            'kind': 'days',
            'from': from!.millisecondsSinceEpoch / 1000.0,
            'to': to!.millisecondsSinceEpoch / 1000.0,
          },
        _ => {'kind': kind.name},
      };
}
