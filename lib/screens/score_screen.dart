import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_info.dart';
import '../data/match_repository.dart';
import '../logic/tennis_rule.dart';
import '../models/match_info.dart';
import '../models/match_state.dart';
import '../models/player_names.dart';
import 'club_list_screen.dart';
import 'names_dialog.dart';

class ScoreScreen extends StatefulWidget {
  const ScoreScreen({super.key});

  @override
  State<ScoreScreen> createState() => _ScoreScreenState();
}

class _ScoreScreenState extends State<ScoreScreen> with WidgetsBindingObserver {
  static const Color _colorA = Color(0xFF1565C0);
  static const Color _colorB = Color(0xFFC62828);

  final _repo = FirestoreMatchRepository();

  MatchState _state = const MatchState();
  final List<MatchState> _undoStack = [];
  PlayerNames _names = PlayerNames.defaults();
  MatchInfo _info = const MatchInfo();

  String? _matchId; // null = ローカルのみ
  bool _readOnly = false; // true = 閲覧専用
  StreamSubscription<MatchSnapshot?>? _sub;

  bool _keepAwake = true; // 画面を消さない
  bool _wakeHeld = false;

  Color _teamColor(Team t) => t == Team.a ? _colorA : _colorB;
  bool get _locked => _state.isOver || _readOnly;

  // ============================================================
  // ライフサイクル・画面スリープ防止
  // ============================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyWakelock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ブラウザは、画面を離れるとロックを自動で解除するので、戻ったら取り直す
    if (state == AppLifecycleState.resumed) {
      _wakeHeld = false;
      _applyWakelock();
    }
  }

  Future<void> _applyWakelock() async {
    try {
      if (_keepAwake) {
        await WakelockPlus.enable();
        _wakeHeld = true;
      } else {
        await WakelockPlus.disable();
        _wakeHeld = false;
      }
    } catch (_) {
      _wakeHeld = false; // 非対応の環境では何もしない
    }
  }

  void _toggleKeepAwake() {
    setState(() => _keepAwake = !_keepAwake);
    _applyWakelock();
    _toast(_keepAwake ? '画面を消さない：オン' : '画面を消さない：オフ');
  }

  /// 操作のたびに、ロックが外れていれば取り直す（ブラウザは操作時の要求を通しやすい）
  void _ensureWakelock() {
    if (_keepAwake && !_wakeHeld) _applyWakelock();
  }

  // ============================================================
  // 共通
  // ============================================================

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// クラウドへ書き込み（await しない。圏外でも端末内にキューされる）
  void _push() {
    final id = _matchId;
    if (id == null || _readOnly) return;
    _repo.save(id, _state, _names, _info).catchError((Object e) {
      _toast('クラウド保存に失敗しました: $e');
    });
  }

  // ============================================================
  // 試合の操作
  // ============================================================

  void _apply(MatchState next) {
    if (_readOnly || identical(next, _state)) return;
    _ensureWakelock();
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
    _ensureWakelock();
    setState(() => _state = _undoStack.removeLast());
    _push();
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('試合リセット'),
        content: Text(
          _matchId == null
              ? 'スコアをすべて消去して、最初からやり直しますか？'
              : 'スコアをすべて消去します。クラウド上のこの試合も初期化されます。\n\n'
                    '次の試合に進むときは、「次の試合へ」を使うと、この試合の記録を残せます。',
        ),
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

  /// 次の試合へ：今の試合は（クラウド接続中なら）そのまま残し、新しい試合を始める
  Future<void> _nextMatch() async {
    if (_readOnly) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('次の試合へ'),
        content: Text(
          [
            if (!_state.isOver) '※この試合はまだ終了していません。\n',
            if (_matchId == null)
              'この試合の記録は消えます（クラウドに保存していません）。'
            else
              '今の試合（コード: $_matchId）はクラウドに残ります。新しい試合コードを発行します。',
            '\n大会名・日付・会場・所属は引き継ぎます。選手名とスコアは初期化されます。',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('次の試合へ'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    const fresh = MatchState();
    final nextInfo = MatchInfo(
      title: _info.title,
      date: _info.date,
      venue: _info.venue,
    );
    final nextNames = PlayerNames.defaults()
        .setAffiliation(Team.a, _names.affiliation(Team.a))
        .setAffiliation(Team.b, _names.affiliation(Team.b));

    String? newId;
    if (_matchId != null) {
      try {
        newId = await _repo.createMatch(fresh, nextNames, nextInfo);
      } catch (e) {
        _toast('新しい試合の作成に失敗しました: $e');
        return; // 失敗したときは、今の試合をそのまま残す
      }
    }
    if (!mounted) return;

    setState(() {
      _state = fresh;
      _undoStack.clear();
      _names = nextNames;
      _info = nextInfo;
      if (newId != null) _matchId = newId;
    });
    if (newId != null) _toast('新しい試合コード: $newId');

    await _editSetup(); // 続けて、ペア名などを入力
  }

  // ============================================================
  // 試合情報・ペア名・サーブ順
  // ============================================================

  Future<void> _editSetup() async {
    if (_readOnly || !mounted) return;
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

  Future<void> _editServeOrder() async {
    var first = _state.serveOrder[0];
    var other = _state.serveOrder[1];

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
  // クラウド
  // ============================================================

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
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('試合一覧（部活アカウント）'),
              subtitle: const Text('ログインした人だけが一覧を見られます'),
              onTap: () => Navigator.pop(ctx, 'club'),
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
      case 'club':
        await _openClubList();
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
    await _joinWithCode(code);
  }

  Future<void> _openClubList() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ClubListScreen()),
    );
    if (code == null || !mounted) return;
    await _joinWithCode(code);
  }

  Future<void> _joinWithCode(String code) async {
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

  // ============================================================
  // このアプリについて
  // ============================================================

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('このアプリについて'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$appName $appVersion',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  appDescription,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 2),
                Text(
                  '開発：$appPublisher',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const Divider(height: 24),
                const Text(
                  '更新履歴',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                for (final r in releaseNotes) ...[
                  const SizedBox(height: 10),
                  Text(
                    r.version,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (final line in r.items)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '・$line',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 画面全体
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            '$appName $appVersion',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18),
          ),
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
            PopupMenuButton<String>(
              tooltip: 'メニュー',
              onSelected: (v) {
                switch (v) {
                  case 'serve':
                    _editServeOrder();
                  case 'awake':
                    _toggleKeepAwake();
                  case 'about':
                    _showAbout();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  value: 'serve',
                  enabled: _state.isPristine && !_readOnly,
                  child: const Text('サーブ順を設定（試合開始前のみ）'),
                ),
                CheckedPopupMenuItem<String>(
                  value: 'awake',
                  checked: _keepAwake,
                  child: const Text('画面を消さない'),
                ),
                const PopupMenuItem<String>(
                  value: 'about',
                  child: Text('このアプリについて'),
                ),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '入力'),
              Tab(text: 'スタッツ・履歴'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            // 入力中の横スワイプで、タブが切り替わらないようにする
            physics: const NeverScrollableScrollPhysics(),
            children: [_buildInputTab(), _buildStatsTab()],
          ),
        ),
      ),
    );
  }

  // ---------- タブ1：入力 ----------
  Widget _buildInputTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(
        children: [
          _buildCloudBanner(),
          _buildInfoHeader(),
          _buildGameCount(),
          _buildGameHistory(),
          _buildPoints(),
          const SizedBox(height: 6),
          _buildServeButtons(),
          const SizedBox(height: 6),
          _buildPlayerButtons(),
          const SizedBox(height: 6),
          _buildUtilButtons(),
        ],
      ),
    );
  }

  // ---------- タブ2：スタッツ・履歴 ----------
  Widget _buildStatsTab() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildInfoCard(),
        const SizedBox(height: 10),
        _buildStatsTable(),
        const SizedBox(height: 10),
        _buildPointLog(),
      ],
    );
  }

  // ============================================================
  // 入力タブの部品
  // ============================================================

  Widget _buildCloudBanner() {
    if (_matchId == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
      decoration: BoxDecoration(
        color: _readOnly ? Colors.amber.shade100 : Colors.green.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _readOnly ? '閲覧中（読み取り専用）　コード: $_matchId' : '入力中（クラウド同期）　コード: $_matchId',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// 1行の試合情報（タップで編集）
  Widget _buildInfoHeader() {
    final i = _info;
    if (i.isEmpty && _readOnly) return const SizedBox.shrink();

    final text = [
      if (i.title.isNotEmpty) i.title,
      if (i.dateText.isNotEmpty) i.dateText,
      if (i.venue.isNotEmpty) i.venue,
    ].join('　');

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _readOnly ? null : _editSetup,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!_readOnly)
                Icon(Icons.edit_note, size: 16, color: Colors.grey.shade600),
              if (!_readOnly) const SizedBox(width: 4),
              Flexible(
                child: Text(
                  text.isEmpty ? '試合情報・ペア名を入力' : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: text.isEmpty
                        ? FontWeight.normal
                        : FontWeight.bold,
                    color: text.isEmpty ? Colors.grey.shade600 : Colors.black87,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
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
              style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w900),
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
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameHistory() {
    final list = _state.gameResults;
    if (list.isEmpty) return const SizedBox(height: 2);

    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final g in list)
            Container(
              margin: const EdgeInsets.only(right: 6, top: 2, bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text.rich(
                TextSpan(
                  style: const TextStyle(fontSize: 12),
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
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isServerSide ? _teamColor(t) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                isServerSide ? '● ${_names.of(server)}' : '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            FittedBox(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 72,
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
          children: [
            side(Team.a, la),
            const Text(
              '-',
              style: TextStyle(fontSize: 44, color: Colors.black45),
            ),
            side(Team.b, lb),
          ],
        ),
        SizedBox(
          height: 22,
          child: note == null
              ? null
              : Text(
                  note,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade800,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildServeButtons() {
    final s = _state;
    final server = TennisRule.currentServer(s);
    final enabled = !_locked && !s.firstServeRecorded;

    Widget btn(String label, Color color, ServeResult r) {
      return Expanded(
        child: SizedBox(
          height: 52,
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
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
      caption = '${_names.of(server)}の1st：$r → 得点を入力してください';
    } else {
      caption = '${_names.of(server)}の1stサーブは？（任意）';
    }

    return Column(
      children: [
        SizedBox(
          height: 18,
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
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withAlpha(100)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < players.length; i++) ...[
            _playerCard(players[i]),
            if (i != players.length - 1) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _playerCard(Player p) {
    final color = _teamColor(p.team);
    final oppColor = _teamColor(p.team.other);
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _names.of(p),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isServer ? color : Colors.black87,
                  ),
                ),
              ),
              if (isServer)
                Text(
                  ' ● サーブ',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: color,
                      disabledBackgroundColor: Colors.grey.shade400,
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: disabled ? null : () => _score(p),
                    child: const Text(
                      '得点+1',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: oppColor,
                      side: BorderSide(color: oppColor.withAlpha(180)),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: disabled ? null : () => _miss(p),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'ミス',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text('相手+1', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUtilButtons() {
    const pad = EdgeInsets.symmetric(horizontal: 6);
    const size = Size.fromHeight(44);
    const label = TextStyle(fontSize: 13);
    final highlightNext = _state.isOver && !_readOnly; // 試合終了後は目立たせる

    final nextLabel = const Text('次の試合へ', style: label);
    const nextIcon = Icon(Icons.skip_next, size: 18);
    final VoidCallback? nextTap = _readOnly ? null : _nextMatch;

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: size, padding: pad),
            onPressed: (_readOnly || _undoStack.isEmpty) ? null : _undo,
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('1つ戻す', style: label),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: highlightNext
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: size,
                    padding: pad,
                  ),
                  onPressed: nextTap,
                  icon: nextIcon,
                  label: nextLabel,
                )
              : OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: size,
                    padding: pad,
                  ),
                  onPressed: nextTap,
                  icon: nextIcon,
                  label: nextLabel,
                ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: size,
              padding: pad,
              foregroundColor: Colors.red.shade700,
            ),
            onPressed: _readOnly ? null : _confirmReset,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('リセット', style: label),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // スタッツタブの部品
  // ============================================================

  Widget _buildInfoCard() {
    final i = _info;
    final where = [
      if (i.dateText.isNotEmpty) i.dateText,
      if (i.venue.isNotEmpty) i.venue,
    ].join('　');

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (i.title.isNotEmpty)
              Text(
                i.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            if (where.isNotEmpty)
              Text(where, style: const TextStyle(fontSize: 12)),
            if (i.note.isNotEmpty)
              Text(
                'メモ：${i.note}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            if (!i.isEmpty) const SizedBox(height: 6),
            Text(
              '${_names.pair(Team.a)}  vs  ${_names.pair(Team.b)}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              'ゲームカウント ${_state.gamesA} - ${_state.gamesB}'
              '${_state.isOver ? '（試合終了）' : ''}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
    );
  }

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

  Widget _buildPointLog() {
    final pts = _state.points;
    const maxShown = 60;
    final shown = pts.reversed.take(maxShown).toList();

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'ポイントの流れ',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  '${pts.length}ポイント（新しい順）',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (pts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    'まだポイントがありません',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              )
            else ...[
              for (final r in shown) _logTile(r),
              if (pts.length > maxShown)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '…ほか${pts.length - maxShown}ポイント',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _logTile(PointRecord r) {
    final first = switch (r.firstServe) {
      ServeResult.firstIn => '1stイン',
      ServeResult.firstFault => '1stフォルト',
      null => '1st未入力',
    };
    final isWin = r.kind == PointKind.winner;
    // 7ゲーム目は、必ずファイナルゲーム
    final gameLabel = r.gameNumber == 7 ? 'F' : 'G${r.gameNumber}';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(
              gameLabel,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ),
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 6, top: 4),
            decoration: BoxDecoration(
              color: _teamColor(r.winnerTeam), // ポイントを取った側の色
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _names.of(r.actor),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _teamColor(r.actor.team),
                        ),
                      ),
                      TextSpan(
                        text: isWin ? ' 得点' : ' ミス',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isWin
                              ? Colors.green.shade800
                              : Colors.red.shade700,
                        ),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
                Text(
                  'サーブ：${_names.of(r.server)}（$first）',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
