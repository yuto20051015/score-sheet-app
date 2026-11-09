import '../models/match_state.dart';

/// ルール判定・集計。すべて「状態を受け取って新しい状態（または値）を返す」純粋関数。
class TennisRule {
  static const int normalTarget = 4;
  static const int finalTarget = 7;

  static int target(bool isFinal) => isFinal ? finalTarget : normalTarget;

  /// デュース圏内（通常: 両者3点以上 / ファイナル: 両者6点以上）
  static bool inDeuceZone(int a, int b, bool isFinal) {
    final t = target(isFinal) - 1;
    return a >= t && b >= t;
  }

  /// ゲーム終了：目標点以上 かつ 2点差
  static bool isGameWon(int a, int b, bool isFinal) {
    final hi = a > b ? a : b;
    return hi >= target(isFinal) && (a - b).abs() >= 2;
  }

  static (String, String) pointLabel(int a, int b, bool isFinal) {
    if (inDeuceZone(a, b, isFinal)) {
      if (a == b) return ('D', 'D');
      return a > b ? ('A', 'D') : ('D', 'A');
    }
    return ('$a', '$b');
  }

  static Team? advantageTeam(MatchState s) {
    if (!inDeuceZone(s.pointsA, s.pointsB, s.isFinalGame)) return null;
    if (s.pointsA == s.pointsB) return null;
    return s.pointsA > s.pointsB ? Team.a : Team.b;
  }

  // ============================================================
  // サーバー（選手単位）
  // ============================================================

  /// 現在のサーバー選手。
  ///
  /// serveOrder[0] = 先攻ペアの1人目（例: A）
  /// serveOrder[1] = 後攻ペアの1人目（例: C）
  ///
  /// ■ 通常ゲーム
  ///   ゲームごとにサーブ権のあるペアが交代する（偶数ゲーム目=先攻ペア、奇数ゲーム目=後攻ペア）。
  ///   ゲームが切り替わるたびにペア内のサーブ順はリセットされ、
  ///   必ず「ペアの1人目（A または C）」から始まる。
  ///   ゲーム中は 2ポイントごとに同じペアの味方へ交代する。
  ///   例: 第1G  A,A,B,B,A,A,B,B ...
  ///       第2G  C,C,D,D,C,C,D,D ...
  ///       第3G  A,A,B,B ...（Aから再スタート）
  ///
  /// ■ ファイナルゲーム
  ///   2ポイントごとに相手ペアへ交代。ペア内の順番は通常ゲームと同じ。
  ///   例: A,A,C,C,B,B,D,D,A,A ...
  static Player currentServer(MatchState s) {
    final gameIndex = s.gamesA + s.gamesB; // 0始まりのゲーム番号
    final block = (s.pointsA + s.pointsB) ~/ 2; // 2ポイントごとの区間番号

    // このゲームで先にサーブを打つペアの1人目と、もう一方のペアの1人目
    final lead = gameIndex.isEven ? s.serveOrder[0] : s.serveOrder[1];
    final otherLead = gameIndex.isEven ? s.serveOrder[1] : s.serveOrder[0];

    if (s.isFinalGame) {
      // 相手ペアと交互に、各ペア内は 1人目 → 2人目 の順
      final seq = [lead, otherLead, lead.partner, otherLead.partner];
      return seq[block % 4];
    }

    // 通常ゲーム：1人目から始まり、2ポイントごとに味方へ交代
    return block.isOdd ? lead.partner : lead;
  }

  /// サーブ順の設定（試合開始前のみ）
  /// [firstServer]    : 最初にサーブを打つ選手
  /// [otherPairFirst] : 相手ペアで最初にサーブを打つ選手
  static MatchState setServeOrder(
    MatchState s, {
    required Player firstServer,
    required Player otherPairFirst,
  }) {
    if (!s.isPristine) return s;
    if (firstServer.team == otherPairFirst.team) return s;
    return s.copyWith(
      serveOrder: [
        firstServer,
        otherPairFirst,
        firstServer.partner,
        otherPairFirst.partner,
      ],
    );
  }

  // ============================================================
  // ポイント加算・1st記録
  // ============================================================

  /// 選手が関わったポイントを記録して進行させる。
  ///   kind = winner : [actor] が決めた得点 → actor のペアに +1
  ///   kind = error  : [actor] のミス       → 相手ペアに +1
  static MatchState addPoint(MatchState s, Player actor, PointKind kind) {
    if (s.isOver) return s;

    final isFinal = s.isFinalGame;
    final record = PointRecord(
      gameNumber: s.gamesA + s.gamesB + 1,
      server: currentServer(s),
      firstServe: s.pendingFirstServe,
      actor: actor,
      kind: kind,
    );

    final winner = record.winnerTeam;
    final pa = s.pointsA + (winner == Team.a ? 1 : 0);
    final pb = s.pointsB + (winner == Team.b ? 1 : 0);
    final newPoints = [...s.points, record];

    // ゲーム継続
    if (!isGameWon(pa, pb, isFinal)) {
      return s.copyWith(
        pointsA: pa,
        pointsB: pb,
        points: newPoints,
        clearPendingFirstServe: true,
      );
    }

    // ゲーム終了
    final result = GameResult(
      gameNumber: record.gameNumber,
      pointsA: pa,
      pointsB: pb,
      isFinal: isFinal,
    );
    return s.copyWith(
      gamesA: s.gamesA + (pa > pb ? 1 : 0),
      gamesB: s.gamesB + (pb > pa ? 1 : 0),
      pointsA: 0,
      pointsB: 0,
      points: newPoints,
      gameResults: [...s.gameResults, result],
      clearPendingFirstServe: true,
    );
  }

  /// 便利ラッパー
  static MatchState scoreBy(MatchState s, Player p) =>
      addPoint(s, p, PointKind.winner);

  static MatchState errorBy(MatchState s, Player p) =>
      addPoint(s, p, PointKind.error);

  /// 現在のサーバーの1stの結果を記録（1ポイントにつき1回）
  /// どの選手の1stかは currentServer が決まるので引数は結果のみ。
  static MatchState recordFirstServe(MatchState s, ServeResult r) {
    if (s.isOver || s.firstServeRecorded) return s;
    return s.copyWith(pendingFirstServe: r);
  }

  // ============================================================
  // 集計
  // ============================================================

  static PlayerStats statsOf(MatchState s, Player p) {
    var winners = 0, errors = 0;
    var servePoints = 0, servePointsWon = 0;
    var firstAttempts = 0, firstIns = 0;

    for (final r in s.points) {
      if (r.actor == p) {
        r.kind == PointKind.winner ? winners++ : errors++;
      }
      if (r.server == p) {
        servePoints++;
        if (r.winnerTeam == p.team) servePointsWon++;
        if (r.firstServe != null) {
          firstAttempts++;
          if (r.firstServe == ServeResult.firstIn) firstIns++;
        }
      }
    }
    return PlayerStats(
      winners: winners,
      errors: errors,
      servePoints: servePoints,
      servePointsWon: servePointsWon,
      firstAttempts: firstAttempts,
      firstIns: firstIns,
    );
  }

  /// ペア合計
  static PlayerStats statsOfTeam(MatchState s, Team t) =>
      Player.of(t).map((p) => statsOf(s, p)).reduce((x, y) => x + y);
}
