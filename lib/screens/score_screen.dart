import 'dart:async';

import '../models/match_info.dart';
import '../data/match_repository.dart';
import '../models/player_names.dart';
import 'names_dialog.dart';

import 'package:flutter/material.dart';

import '../logic/tennis_rule.dart';
import '../models/match_state.dart';

class ScoreScreen extends StatefulWidget {
  const ScoreScreen({super.key});

  @override
  State<ScoreScreen> createState() => _ScoreScreenState();
}

class _ScoreScreenState extends State<ScoreScreen> {
  static const Color _colorA = Color(0xFF1565C0);
  static const Color _colorB = Color(0xFFC62828);

  MatchState _state = const MatchState();
  final List<MatchState> _undoStack = [];

  final _repo = FirestoreMatchRepository();
  PlayerNames _names = PlayerNames.defaults();
  MatchInfo _info = const MatchInfo();
  String? _matchId; // null = ローカルのみ
  bool _readOnly = false; // true = 閲覧専用（オーナーではない）
  StreamSubscription<MatchSnapshot?>? _sub;

  bool get _locked => _state.isOver || _readOnly;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// クラウドへ書き込み（await しない。圏外でも端末内にキューされる）
  void _push() {
    final id = _matchId;
    if (id == null || _readOnly) return;
    _repo.save(id, _state, _names, _info).catchError((Object e) {
      _toast('クラウド保存に失敗しました: $e');
    });
  }

  // ---------- 試合情報・ペア名 ----------
  Future<void> _editSetup() async {
    if (_readOnly) return;
    final r = await showDialog<MatchSetup>(
      context: context,
      builder: (_) => MatchSetupDialog(info: _info, names: _names),
    );
    if (r == null) return;
    setState(() {
      _info = r.info;
      _names = r.names;
    });
    _push();
  }

  Widget _buildInfoHeader() {
    final i = _info;
    if (i.isEmpty && _readOnly) return const SizedBox.shrink();

    final line2 = [
      if (i.dateText.isNotEmpty) i.dateText,
      if (i.venue.isNotEmpty) i.venue,
    ].join('　');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _readOnly ? null : _editSetup,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: i.isEmpty
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.edit_note,
                      size: 18,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '試合情報・ペア名を入力（大会名・所属・選手名など）',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    if (i.title.isNotEmpty)
                      Text(
                        i.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    if (line2.isNotEmpty)
                      Text(
                        line2,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    if (i.note.isNotEmpty)
                      Text(
                        i.note,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  // ---------- クラウド ----------
  Future<void> _openCloudMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_matchId != null)
              ListTile(
                leading: const Icon(Icons.vpn_key),
                title: Text('試合コード: $_matchId'),
                subtitle: Text(_readOnly ? '閲覧中（読み取り専用）' : '入力中（この端末が書き込み）'),
              ),
            ListTile(
              leading: const Icon(Icons.cloud_upload),
              title: const Text('この試合をクラウドに保存（新規）'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('試合コードで参加'),
              subtitle: const Text('他人の試合は閲覧のみ／自分の試合は入力を再開'),
              onTap: () => Navigator.pop(ctx, 'join'),
            ),
            if (_matchId != null)
              ListTile(
                leading: const Icon(Icons.cloud_off),
                title: const Text('同期を終了（ローカルに戻る）'),
                onTap: () => Navigator.pop(ctx, 'leave'),
              ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'new':
        await _createCloudMatch();
      case 'join':
        await _joinCloudMatch();
      case 'leave':
        _disconnect();
    }
  }

  Future<void> _createCloudMatch() async {
    try {
      final id = await _repo.createMatch(_state, _names, _info);
      if (!mounted) return;
      _sub?.cancel();
      _sub = null;
      setState(() {
        _matchId = id;
        _readOnly = false;
      });
      _toast('試合コード: $id（応援席や本部に共有してください）');
    } catch (e) {
      _toast('作成に失敗しました: $e');
    }
  }

  Future<void> _joinCloudMatch() async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const JoinCodeDialog(),
    );
    if (code == null || code.isEmpty) return;

    try {
      final snap = await _repo.fetch(code);
      if (!mounted) return;
      if (snap == null) {
        _toast('その試合コードは見つかりません');
        return;
      }
      _sub?.cancel();
      final isOwner = snap.ownerUid == _repo.uid;
      setState(() {
        _matchId = code;
        _state = snap.state;
        _names = snap.names;
        _info = snap.info;
        _undoStack.clear();
        _readOnly = !isOwner;
      });
      if (!isOwner) {
        _sub = _repo.watch(code).listen((s) {
          if (s == null || !mounted) return;
          setState(() {
            _state = s.state;
            _names = s.names;
            _info = s.info;
          });
        }, onError: (Object e) => _toast('同期エラー: $e'));
      }
    } catch (e) {
      _toast('参加に失敗しました: $e');
    }
  }

  void _disconnect() {
    _sub?.cancel();
    _sub = null;
    setState(() {
      _matchId = null;
      _readOnly = false;
    });
  }

  Widget _buildCloudBanner() {
    if (_matchId == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: _readOnly ? Colors.amber.shade100 : Colors.green.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _readOnly ? '閲覧中（読み取り専用）　コード: $_matchId' : '入力中（クラウド同期）　コード: $_matchId',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  Color _teamColor(Team t) => t == Team.a ? _colorA : _colorB;

  // ============================================================
  // 操作
  // ============================================================

  /// 新しい状態に更新する。変化がなければ何もしない（Undoにも積まない）。
  void _apply(MatchState next) {
    if (_readOnly || identical(next, _state)) return;
    setState(() {
      _undoStack.add(_state);
      _state = next;
    });
    _push();
  }

  void _score(Player p) => _apply(TennisRule.scoreBy(_state, p));
  void _miss(Player p) => _apply(TennisRule.errorBy(_state, p));
  void _serve(ServeResult r) => _apply(TennisRule.recordFirstServe(_state, r));

  void _undo() {
    if (_readOnly || _undoStack.isEmpty) return;
    setState(() => _state = _undoStack.removeLast());
    _push();
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('試合リセット'),
        content: const Text('すべて消去して最初からやり直しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('リセット'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _state = const MatchState();
        _undoStack.clear();
      });
      _push();
    }
  }

  /// サーブ順の設定（試合開始前のみ）
  Future<void> _editServeOrder() async {
    var first = _state.serveOrder[0]; // 最初にサーブを打つ選手
    var other = _state.serveOrder[1]; // 相手ペアで最初に打つ選手

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget chips(
            List<Player> options,
            Player selected,
            ValueChanged<Player> onSelect,
          ) {
            return Wrap(
              spacing: 8,
              children: [
                for (final p in options)
                  ChoiceChip(
                    label: Text(_names.of(p)),
                    selected: p == selected,
                    onSelected: (_) => setLocal(() => onSelect(p)),
                  ),
              ],
            );
          }

          return AlertDialog(
            title: const Text('サーブ順の設定'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '最初にサーブを打つ選手',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                chips(Player.values, first, (p) {
                  first = p;
                  // 相手ペアの選手が first と同じペアにならないよう調整
                  if (other.team == first.team) {
                    other = Player.of(first.team.other).first;
                  }
                }),
                const SizedBox(height: 16),
                const Text(
                  '相手ペアで最初に打つ選手',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                chips(Player.of(first.team.other), other, (p) => other = p),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('決定'),
              ),
            ],
          );
        },
      ),
    );

    if (ok == true) {
      // 試合開始前の設定なので Undo には積まない
      setState(() {
        _state = TennisRule.setServeOrder(
          _state,
          firstServer: first,
          otherPairFirst: other,
        );
      });
      _push();
    }
  }

  // ============================================================
  // 画面全体
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('スコアシート ver1.0'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '試合情報・ペア名',
            icon: const Icon(Icons.edit_note),
            onPressed: _readOnly ? null : _editSetup,
          ),
          IconButton(
            tooltip: 'クラウド同期',
            icon: Icon(_matchId == null ? Icons.cloud_off : Icons.cloud_done),
            onPressed: _openCloudMenu,
          ),
          if (_state.isPristine && !_readOnly)
            IconButton(
              tooltip: 'サーブ順',
              icon: const Icon(Icons.swap_horiz),
              onPressed: _editServeOrder,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            children: [
              _buildCloudBanner(),
              _buildInfoHeader(),
              _buildGameCount(),
              _buildGameHistory(),
              const SizedBox(height: 4),
              _buildPoints(),
              const SizedBox(height: 8),
              _buildServeButtons(),
              const SizedBox(height: 8),
              _buildPlayerButtons(),
              const SizedBox(height: 8),
              _buildUtilButtons(),
              const SizedBox(height: 12),
              _buildStatsTable(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- ゲームカウント ----------
  Widget _buildGameCount() {
    final s = _state;
    final String caption = s.isOver
        ? '試合終了　${_names.pair(s.winner!)}の勝利'
        : (s.isFinalGame
              ? 'ファイナルゲーム（7ポイント先取）'
              : '第${s.gamesA + s.gamesB + 1}ゲーム');

    return Column(
      children: [
        Text(
          caption,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: s.isOver || s.isFinalGame
                ? Colors.orange.shade800
                : Colors.grey.shade700,
          ),
        ),
        Row(
          children: [
            _teamHead(Team.a, _colorA),
            Text(
              '${s.gamesA} - ${s.gamesB}',
              style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900),
            ),
            _teamHead(Team.b, _colorB),
          ],
        ),
      ],
    );
  }

  /// ペアの見出し：所属（小さく）＋ 選手名
  Widget _teamHead(Team t, Color color) {
    final aff = _names.affiliation(t);
    return Expanded(
      child: Column(
        children: [
          if (aff.isNotEmpty)
            Text(
              aff,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: color.withAlpha(200)),
            ),
          Text(
            _names.playersText(t),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 終了済みゲームの一覧 ----------
  Widget _buildGameHistory() {
    final list = _state.gameResults;
    if (list.isEmpty) return const SizedBox(height: 4);

    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final g in list)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text.rich(
                TextSpan(
                  style: const TextStyle(fontSize: 13),
                  children: [
                    TextSpan(text: g.isFinal ? 'F ' : 'G${g.gameNumber} '),
                    TextSpan(
                      text: '${g.pointsA}',
                      style: TextStyle(
                        fontWeight: g.winner == Team.a
                            ? FontWeight.w900
                            : FontWeight.normal,
                        color: g.winner == Team.a ? _colorA : Colors.black54,
                      ),
                    ),
                    const TextSpan(text: ' - '),
                    TextSpan(
                      text: '${g.pointsB}',
                      style: TextStyle(
                        fontWeight: g.winner == Team.b
                            ? FontWeight.w900
                            : FontWeight.normal,
                        color: g.winner == Team.b ? _colorB : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 現在のポイント＋サーバー表示 ----------
  Widget _buildPoints() {
    final s = _state;
    final (la, lb) = TennisRule.pointLabel(s.pointsA, s.pointsB, s.isFinalGame);
    final server = TennisRule.currentServer(s);
    final adv = TennisRule.advantageTeam(s);

    String? note;
    if (!s.isOver &&
        TennisRule.inDeuceZone(s.pointsA, s.pointsB, s.isFinalGame)) {
      note = adv == null ? 'デュース' : '${adv.label} アドバンテージ';
    }

    Widget side(Team t, String label) {
      final isServerSide = !s.isOver && server.team == t;
      return Expanded(
        child: Column(
          children: [
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isServerSide ? _teamColor(t) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                isServerSide ? '● ${_names.of(server)}' : '',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            FittedBox(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 88,
                  fontWeight: FontWeight.w900,
                  color: _teamColor(t),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            side(Team.a, la),
            const Text(
              '-',
              style: TextStyle(fontSize: 52, color: Colors.black45),
            ),
            side(Team.b, lb),
          ],
        ),
        SizedBox(
          height: 26,
          child: note == null
              ? null
              : Text(
                  note,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade800,
                  ),
                ),
        ),
      ],
    );
  }

  // ---------- 1stサーブ イン / フォルト ----------
  Widget _buildServeButtons() {
    final s = _state;
    final server = TennisRule.currentServer(s);
    final enabled = !_locked && !s.firstServeRecorded;

    Widget btn(String label, Color color, ServeResult r) {
      return Expanded(
        child: SizedBox(
          height: 60,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: color,
              disabledBackgroundColor: Colors.grey.shade300,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: enabled ? () => _serve(r) : null,
            child: Text(
              label,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      );
    }

    String caption;
    if (s.isOver) {
      caption = '';
    } else if (s.firstServeRecorded) {
      final r = s.pendingFirstServe == ServeResult.firstIn ? 'イン' : 'フォルト';
      caption = '${_names.of(server)}の1st：$r（記録済み）→ 得点を入力してください';
    } else {
      caption = '${_names.of(server)}の1stサーブは？（任意）';
    }

    return Column(
      children: [
        SizedBox(
          height: 20,
          child: Text(
            caption,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ),
        Row(
          children: [
            btn('1st イン', Colors.green.shade700, ServeResult.firstIn),
            const SizedBox(width: 10),
            btn('1st フォルト', Colors.orange.shade800, ServeResult.firstFault),
          ],
        ),
      ],
    );
  }

  // ---------- 4選手の 得点 / ミス ボタン ----------
  Widget _buildPlayerButtons() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _teamPanel(Team.a)),
        const SizedBox(width: 10),
        Expanded(child: _teamPanel(Team.b)),
      ],
    );
  }

  Widget _teamPanel(Team t) {
    final color = _teamColor(t);
    final players = Player.of(t);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withAlpha(100)),
      ),
      child: Column(
        children: [
          Text(
            _names.pair(t),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < players.length; i++) ...[
            _playerCard(players[i]),
            if (i != players.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _playerCard(Player p) {
    final color = _teamColor(p.team);
    final disabled = _locked;
    final isServer = !_state.isOver && TennisRule.currentServer(_state) == p;

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isServer ? color : Colors.transparent,
          width: 2,
        ),
      ),
      child: Column(
        children: [
          Text(
            '${p.label}選手${isServer ? '  ● サーブ' : ''}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: isServer ? color : Colors.black87,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            height: 64,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: color,
                disabledBackgroundColor: Colors.grey.shade400,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: disabled ? null : () => _score(p),
              child: const Text(
                '得点 +1',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: _teamColor(p.team.other),
                side: BorderSide(
                  color: _teamColor(p.team.other).withAlpha(180),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: disabled ? null : () => _miss(p),
              child: const Text(
                'ミス（相手に+1）',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Undo / リセット ----------
  Widget _buildUtilButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: (_readOnly || _undoStack.isEmpty) ? null : _undo,
            icon: const Icon(Icons.undo),
            label: const Text('1つ戻す'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: Colors.red.shade700,
            ),
            onPressed: _readOnly ? null : _confirmReset,
            icon: const Icon(Icons.restart_alt),
            label: const Text('リセット'),
          ),
        ),
      ],
    );
  }

  // ---------- 選手別スタッツ ----------
  Widget _buildStatsTable() {
    Widget cell(
      String t, {
      Color? color,
      bool bold = false,
      TextAlign align = TextAlign.center,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        t,
        textAlign: align,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );

    String pct(double? v) => v == null ? '--%' : '${(v * 100).round()}%';

    // 得点 − 失点 の表示（プラスは + を付ける）
    String diffText(PlayerStats st) {
      final d = st.winners - st.errors;
      return d > 0 ? '+$d' : '$d';
    }

    Color? diffColor(PlayerStats st) {
      final d = st.winners - st.errors;
      if (d > 0) return Colors.green.shade800;
      if (d < 0) return Colors.red.shade700;
      return null;
    }

    TableRow header() => TableRow(
      decoration: BoxDecoration(color: Colors.grey.shade200),
      children: [
        for (final t in ['選手', '1st成功率', '得点', '失点', '得点−失点'])
          cell(t, bold: true),
      ],
    );

    TableRow row(Player p) {
      final st = TennisRule.statsOf(_state, p);
      return TableRow(
        children: [
          cell(
            _names.of(p),
            color: _teamColor(p.team),
            bold: true,
            align: TextAlign.left,
          ),
          cell(
            '${pct(st.firstServeRate)}\n${st.firstIns}/${st.firstAttempts}本',
          ),
          cell('${st.winners}', color: Colors.green.shade800),
          cell('${st.errors}', color: Colors.red.shade700),
          cell(diffText(st), color: diffColor(st), bold: true),
        ],
      );
    }

    TableRow teamRow(Team t) {
      final st = TennisRule.statsOfTeam(_state, t);
      return TableRow(
        decoration: BoxDecoration(color: _teamColor(t).withAlpha(18)),
        children: [
          cell(
            '${t.label} 計',
            color: _teamColor(t),
            bold: true,
            align: TextAlign.left,
          ),
          cell(
            '${pct(st.firstServeRate)}\n${st.firstIns}/${st.firstAttempts}本',
            bold: true,
          ),
          cell('${st.winners}', bold: true),
          cell('${st.errors}', bold: true),
          cell(diffText(st), color: diffColor(st), bold: true),
        ],
      );
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '選手別スタッツ',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.6),
                1: FlexColumnWidth(1.7),
                2: FlexColumnWidth(1),
                3: FlexColumnWidth(1),
                4: FlexColumnWidth(1.4),
              },
              border: TableBorder(
                horizontalInside: BorderSide(color: Colors.grey.shade300),
              ),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                header(),
                for (final p in Player.of(Team.a)) row(p),
                teamRow(Team.a),
                for (final p in Player.of(Team.b)) row(p),
                teamRow(Team.b),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '1st成功率 = 1st記録のうちイン ÷ 記録本数\n'
              '得点−失点 = 自分が決めた得点数 − 自分のミス数',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
