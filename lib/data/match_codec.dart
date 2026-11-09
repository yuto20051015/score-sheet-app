import '../models/match_state.dart';

/// MatchState ⇔ Firestore 用 Map の変換
class MatchCodec {
  static const int schemaVersion = 1;

  static Map<String, dynamic> encodeState(MatchState s) => {
    'serveOrder': s.serveOrder.map((p) => p.name).toList(),
    'gamesA': s.gamesA,
    'gamesB': s.gamesB,
    'pointsA': s.pointsA,
    'pointsB': s.pointsB,
    'pendingFirstServe': s.pendingFirstServe?.name,
    'points': [for (final r in s.points) _pointToMap(r)],
    'gameResults': [
      for (final g in s.gameResults)
        {'n': g.gameNumber, 'a': g.pointsA, 'b': g.pointsB, 'f': g.isFinal},
    ],
  };

  static MatchState decodeState(Map<String, dynamic> m) {
    final order = (m['serveOrder'] as List?)
        ?.map((e) => Player.values.byName(e as String))
        .toList();

    return MatchState(
      serveOrder: (order == null || order.length != 4)
          ? const MatchState().serveOrder
          : order,
      gamesA: _int(m['gamesA']),
      gamesB: _int(m['gamesB']),
      pointsA: _int(m['pointsA']),
      pointsB: _int(m['pointsB']),
      pendingFirstServe: _serve(m['pendingFirstServe']),
      points: [
        for (final e in (m['points'] as List? ?? const []))
          _pointFromMap(Map<String, dynamic>.from(e as Map)),
      ],
      gameResults: [
        for (final e in (m['gameResults'] as List? ?? const []))
          _gameFromMap(Map<String, dynamic>.from(e as Map)),
      ],
    );
  }

  // ---------- 内部 ----------
  static Map<String, dynamic> _pointToMap(PointRecord r) => {
    'game': r.gameNumber,
    'server': r.server.name,
    'first': r.firstServe?.name,
    'actor': r.actor.name,
    'kind': r.kind.name,
  };

  static PointRecord _pointFromMap(Map<String, dynamic> m) => PointRecord(
    gameNumber: _int(m['game']),
    server: Player.values.byName(m['server'] as String),
    firstServe: _serve(m['first']),
    actor: Player.values.byName(m['actor'] as String),
    kind: PointKind.values.byName(m['kind'] as String),
  );

  static GameResult _gameFromMap(Map<String, dynamic> m) => GameResult(
    gameNumber: _int(m['n']),
    pointsA: _int(m['a']),
    pointsB: _int(m['b']),
    isFinal: m['f'] == true,
  );

  static int _int(Object? v) => (v as num?)?.toInt() ?? 0;

  static ServeResult? _serve(Object? v) =>
      v is String ? ServeResult.values.byName(v) : null;
}
