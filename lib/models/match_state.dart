/// ペア（チーム）
enum Team { a, b }

extension TeamX on Team {
  Team get other => this == Team.a ? Team.b : Team.a;
  String get label => this == Team.a ? '自ペア' : '相手ペア';
}

/// 選手：自ペア = A, B / 相手ペア = C, D
enum Player {
  a(Team.a, 'A'),
  b(Team.a, 'B'),
  c(Team.b, 'C'),
  d(Team.b, 'D');

  final Team team;
  final String label;
  const Player(this.team, this.label);

  Player get partner => switch (this) {
    Player.a => Player.b,
    Player.b => Player.a,
    Player.c => Player.d,
    Player.d => Player.c,
  };

  /// ペアに所属する選手
  static List<Player> of(Team t) =>
      t == Team.a ? const [Player.a, Player.b] : const [Player.c, Player.d];
}

/// 1stサーブの結果
enum ServeResult { firstIn, firstFault }

/// ボタンを押した選手の関与の種類
enum PointKind {
  winner, // その選手が決めた得点 → 選手のペアに +1
  error, // その選手のミス（失点） → 相手ペアに +1
}

/// 1ポイントぶんの記録
class PointRecord {
  final int gameNumber; // 1始まり
  final Player server; // このポイントのサーバー（選手単位）
  final ServeResult? firstServe; // 1stの結果。未入力なら null
  final Player actor; // 得点 or 失点に関わった選手
  final PointKind kind;

  const PointRecord({
    required this.gameNumber,
    required this.server,
    required this.firstServe,
    required this.actor,
    required this.kind,
  });

  /// ポイントを取ったペア
  Team get winnerTeam =>
      kind == PointKind.winner ? actor.team : actor.team.other;

  /// 得点した選手（失点入力のときは null）
  Player? get scorer => kind == PointKind.winner ? actor : null;

  /// 失点した選手（得点入力のときは null）
  Player? get errorBy => kind == PointKind.error ? actor : null;
}

/// 終了したゲームの記録
class GameResult {
  final int gameNumber;
  final int pointsA;
  final int pointsB;
  final bool isFinal;

  const GameResult({
    required this.gameNumber,
    required this.pointsA,
    required this.pointsB,
    required this.isFinal,
  });

  Team get winner => pointsA > pointsB ? Team.a : Team.b;
}

/// 選手別スタッツ（集計結果）
class PlayerStats {
  final int winners; // 得点（決めたポイント）
  final int errors; // 失点（自分のミス）
  final int servePoints; // サーバーとして打ったポイント数
  final int servePointsWon; // うち、ポイントを取れた数
  final int firstAttempts; // 1stを記録した本数
  final int firstIns; // うちイン

  const PlayerStats({
    this.winners = 0,
    this.errors = 0,
    this.servePoints = 0,
    this.servePointsWon = 0,
    this.firstAttempts = 0,
    this.firstIns = 0,
  });

  /// 1st成功率（0.0〜1.0）。未記録なら null
  double? get firstServeRate =>
      firstAttempts == 0 ? null : firstIns / firstAttempts;

  /// サービスポイント獲得率。サーブ機会がなければ null
  double? get servePointRate =>
      servePoints == 0 ? null : servePointsWon / servePoints;

  /// ペア合計を出すための加算
  PlayerStats operator +(PlayerStats o) => PlayerStats(
    winners: winners + o.winners,
    errors: errors + o.errors,
    servePoints: servePoints + o.servePoints,
    servePointsWon: servePointsWon + o.servePointsWon,
    firstAttempts: firstAttempts + o.firstAttempts,
    firstIns: firstIns + o.firstIns,
  );
}

/// 試合の状態（イミュータブル）
class MatchState {
  static const int gamesToWin = 4; // 7ゲームマッチ

  /// サーブ順：[先攻ペア1人目, 後攻ペア1人目, 先攻ペア2人目, 後攻ペア2人目]
  /// ゲームが1つ進むごとに1つ次の選手へ移る（4ゲームで一巡）
  final List<Player> serveOrder;

  final int gamesA;
  final int gamesB;
  final int pointsA;
  final int pointsB;

  /// 現在のポイントで入力済みの1stの結果（ポイント確定で null に戻る）
  final ServeResult? pendingFirstServe;

  final List<PointRecord> points; // 全ポイントの履歴
  final List<GameResult> gameResults;

  const MatchState({
    this.serveOrder = const [Player.a, Player.c, Player.b, Player.d],
    this.gamesA = 0,
    this.gamesB = 0,
    this.pointsA = 0,
    this.pointsB = 0,
    this.pendingFirstServe,
    this.points = const [],
    this.gameResults = const [],
  });

  // ---- 派生情報 ----

  bool get isFinalGame => gamesA == gamesToWin - 1 && gamesB == gamesToWin - 1;

  Team? get winner {
    if (gamesA >= gamesToWin) return Team.a;
    if (gamesB >= gamesToWin) return Team.b;
    return null;
  }

  bool get isOver => winner != null;

  bool get firstServeRecorded => pendingFirstServe != null;

  bool get isPristine =>
      gamesA == 0 &&
      gamesB == 0 &&
      pointsA == 0 &&
      pointsB == 0 &&
      pendingFirstServe == null &&
      points.isEmpty;

  int gamesOf(Team t) => t == Team.a ? gamesA : gamesB;
  int pointsOf(Team t) => t == Team.a ? pointsA : pointsB;

  MatchState copyWith({
    List<Player>? serveOrder,
    int? gamesA,
    int? gamesB,
    int? pointsA,
    int? pointsB,
    ServeResult? pendingFirstServe,
    bool clearPendingFirstServe = false, // null に戻したいときに true
    List<PointRecord>? points,
    List<GameResult>? gameResults,
  }) {
    return MatchState(
      serveOrder: serveOrder ?? this.serveOrder,
      gamesA: gamesA ?? this.gamesA,
      gamesB: gamesB ?? this.gamesB,
      pointsA: pointsA ?? this.pointsA,
      pointsB: pointsB ?? this.pointsB,
      pendingFirstServe: clearPendingFirstServe
          ? null
          : (pendingFirstServe ?? this.pendingFirstServe),
      points: points ?? this.points,
      gameResults: gameResults ?? this.gameResults,
    );
  }
}
