import 'package:cloud_firestore/cloud_firestore.dart' show DocumentSnapshot;
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/material.dart';

import '../data/club_repository.dart';
import '../models/match_state.dart';

/// 部活アカウント専用：保存済み試合の一覧。
/// 行をタップすると、その試合コードを返して閉じる（Navigator.pop）。
class ClubListScreen extends StatefulWidget {
  const ClubListScreen({super.key});

  @override
  State<ClubListScreen> createState() => _ClubListScreenState();
}

class _ClubListScreenState extends State<ClubListScreen> {
  final _repo = ClubRepository();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _checking = true; // ログイン状態の確認中
  bool _signedIn = false;
  bool _busy = false;
  String? _error;

  final List<ClubMatchItem> _items = [];
  DocumentSnapshot<Map<String, dynamic>>? _last;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  // ---------- 処理 ----------
  Future<void> _init() async {
    try {
      final u = await _repo.currentUser();
      if (!mounted) return;
      setState(() {
        _signedIn = u != null;
        _checking = false;
      });
      if (u != null) await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = '接続に失敗しました: $e';
      });
    }
  }

  String _authMessage(String code) {
    switch (code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
      case 'invalid-email':
        return 'メールアドレスまたはパスワードが違います';
      case 'too-many-requests':
        return '試行回数が多すぎます。しばらく待ってからやり直してください';
      case 'operation-not-allowed':
        return 'Firebase コンソールで「メール/パスワード」認証を有効にしてください';
      default:
        return 'ログインに失敗しました（$code）';
    }
  }

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repo.signIn(_email.text, _password.text);
      if (!mounted) return;
      setState(() {
        _signedIn = true;
        _busy = false;
      });
      _password.clear();
      await _load(reset: true);
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = _authMessage(e.code));
    } catch (e) {
      if (mounted) setState(() => _error = 'ログインに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await _repo.signOut();
    if (!mounted) return;
    setState(() {
      _signedIn = false;
      _items.clear();
      _last = null;
      _hasMore = false;
      _error = null;
    });
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy && !reset) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await _repo.fetchPage(after: reset ? null : _last);
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page.items);
        _last = page.last;
        _hasMore = page.hasMore;
      });
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == 'permission-denied'
            ? 'このアカウントには一覧を見る権限がありません。ルールの UID を確認してください。'
            : '読み込みに失敗しました（${e.code}）';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '読み込みに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 画面 ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('試合一覧'),
        actions: [
          if (_signedIn) ...[
            IconButton(
              tooltip: '更新',
              icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : () => _load(reset: true),
            ),
            IconButton(
              tooltip: 'ログアウト',
              icon: const Icon(Icons.logout),
              onPressed: _signOut,
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: _checking
            ? const Center(child: CircularProgressIndicator())
            : (_signedIn ? _buildList() : _buildLogin()),
      ),
    );
  }

  Widget _errorBox() => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.red.shade50,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      _error!,
      style: TextStyle(fontSize: 13, color: Colors.red.shade800),
    ),
  );

  Widget _buildLogin() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '部活アカウントでログイン',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'ログインすると、保存済みの試合一覧を見られます。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'メールアドレス',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _signIn(),
                decoration: const InputDecoration(
                  labelText: 'パスワード',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null) _errorBox(),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: _busy ? null : _signIn,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('ログイン'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_error != null) _errorBox(),
        if (_items.isEmpty && !_busy && _error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                '保存済みの試合はまだありません',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          ),
        for (final it in _items) _tile(it),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_hasMore)
          OutlinedButton(onPressed: () => _load(), child: const Text('もっと見る')),
      ],
    );
  }

  String _fmt(DateTime? t) {
    if (t == null) return '-';
    String two(int n) => n.toString().padLeft(2, '0');
    final l = t.toLocal();
    return '${l.month}/${l.day} ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _tile(ClubMatchItem it) {
    final s = it.data.state;
    final n = it.data.names;
    final i = it.data.info;

    final title = i.title.isEmpty ? '（大会名なし）' : i.title;
    final where = [
      if (i.dateText.isNotEmpty) i.dateText,
      if (i.venue.isNotEmpty) i.venue,
    ].join('　');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => Navigator.pop(context, it.id),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (where.isNotEmpty)
              Text(where, style: const TextStyle(fontSize: 12)),
            Text(
              '${n.pair(Team.a)}  ${s.gamesA} - ${s.gamesB}  ${n.pair(Team.b)}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              'コード ${it.id}　${s.isOver ? '終了' : '進行中'}　更新 ${_fmt(it.updatedAt)}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
