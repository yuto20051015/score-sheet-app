import 'match_state.dart';

/// 4選手の名前と、各ペアの所属。イミュータブル。
/// MatchState とは別管理（Undo の対象外）。
class PlayerNames {
  static const int maxLength = 10; // 選手名
  static const int maxAffiliation = 20; // 所属

  final Map<Player, String> _names;
  final Map<Team, String> _affiliations;
  const PlayerNames._(this._names, this._affiliations);

  factory PlayerNames.defaults() => PlayerNames._(
    {for (final p in Player.values) p: _default(p)},
    const {Team.a: '', Team.b: ''},
  );

  static String _default(Player p) => '${p.label}選手';

  /// 選手の表示名
  String of(Player p) => _names[p] ?? _default(p);

  /// 未入力（デフォルト名のまま）か
  bool isDefault(Player p) => of(p) == _default(p);

  /// ペアの所属（未入力なら空文字）
  String affiliation(Team t) => _affiliations[t] ?? '';

  /// 選手名だけ（例: 東・高橋）
  String playersText(Team t) => Player.of(t).map(of).join('・');

  /// 所属つき（例: [大阪大学]東・高橋）。所属が空なら選手名だけ。
  String pair(Team t) {
    final aff = affiliation(t);
    return aff.isEmpty ? playersText(t) : '[$aff]${playersText(t)}';
  }

  // ---------- 変更（新しいオブジェクトを返す） ----------
  PlayerNames rename(Player p, String raw) {
    var v = raw.trim();
    if (v.isEmpty) v = _default(p); // 空欄はデフォルト名に戻す
    if (v.length > maxLength) v = v.substring(0, maxLength);
    return PlayerNames._({..._names, p: v}, _affiliations);
  }

  PlayerNames renameAll(Map<Player, String> raw) {
    var r = this;
    raw.forEach((p, v) => r = r.rename(p, v));
    return r;
  }

  PlayerNames setAffiliation(Team t, String raw) {
    var v = raw.trim();
    if (v.length > maxAffiliation) v = v.substring(0, maxAffiliation);
    return PlayerNames._(_names, {..._affiliations, t: v});
  }

  // ---------- Firestore 用 ----------
  static const _keyAffA = 'affA';
  static const _keyAffB = 'affB';

  Map<String, String> toMap() => {
    for (final e in _names.entries) e.key.name: e.value,
    _keyAffA: affiliation(Team.a),
    _keyAffB: affiliation(Team.b),
  };

  factory PlayerNames.fromMap(Map<String, dynamic>? m) {
    var n = PlayerNames.defaults();
    if (m == null) return n;
    for (final p in Player.values) {
      final v = m[p.name];
      if (v is String) n = n.rename(p, v);
    }
    final a = m[_keyAffA];
    final b = m[_keyAffB];
    if (a is String) n = n.setAffiliation(Team.a, a);
    if (b is String) n = n.setAffiliation(Team.b, b);
    return n;
  }
}
