/// 試合の付加情報（大会名・日付・会場・メモ）。イミュータブル。
class MatchInfo {
  static const int maxTitle = 30;
  static const int maxVenue = 30;
  static const int maxNote = 100;

  final String title;
  final DateTime? date; // 日付のみ（時刻は使わない）
  final String venue;
  final String note;

  const MatchInfo({
    this.title = '',
    this.date,
    this.venue = '',
    this.note = '',
  });

  bool get isEmpty =>
      title.isEmpty && date == null && venue.isEmpty && note.isEmpty;

  /// 表示用の日付（例: 2026/11/10）
  String get dateText => date == null
      ? ''
      : '${date!.year}/${_two(date!.month)}/${_two(date!.day)}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  // ---- Firestore 用 ----
  Map<String, dynamic> toMap() => {
    'title': title,
    'date': date == null
        ? null
        : '${date!.year.toString().padLeft(4, '0')}-${_two(date!.month)}-${_two(date!.day)}',
    'venue': venue,
    'note': note,
  };

  factory MatchInfo.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const MatchInfo();
    final d = m['date'];
    return MatchInfo(
      title: (m['title'] as String?) ?? '',
      date: d is String ? DateTime.tryParse(d) : null,
      venue: (m['venue'] as String?) ?? '',
      note: (m['note'] as String?) ?? '',
    );
  }
}
