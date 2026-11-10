import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';
import 'match_repository.dart';

/// 一覧の1行ぶん
class ClubMatchItem {
  final String id; // 試合コード
  final MatchSnapshot data;
  final DateTime? updatedAt;
  const ClubMatchItem(this.id, this.data, this.updatedAt);
}

/// 一覧の1ページぶん
class ClubPage {
  final List<ClubMatchItem> items;
  final DocumentSnapshot<Map<String, dynamic>>? last; // 次ページの起点
  final bool hasMore;
  const ClubPage(this.items, this.last, this.hasMore);
}

/// 部活アカウント用。入力担当の匿名ログインとは別の「名前付きアプリ」で
/// 認証するため、ログイン・ログアウトしても試合の入力権限に影響しない。
class ClubRepository {
  static const _appName = 'club';
  static const _pageSize = 20;

  FirebaseApp? _app;

  Future<FirebaseApp> _ensureApp() async {
    final cached = _app;
    if (cached != null) return cached;
    FirebaseApp app;
    try {
      app = Firebase.app(_appName); // 初期化済み（ホットリスタート時など）
    } catch (_) {
      app = await Firebase.initializeApp(
        name: _appName,
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    return _app = app;
  }

  Future<FirebaseAuth> _auth() async =>
      FirebaseAuth.instanceFor(app: await _ensureApp());

  Future<FirebaseFirestore> _db() async =>
      FirebaseFirestore.instanceFor(app: await _ensureApp());

  /// ログイン済みならユーザー、未ログインなら null（保存済みの状態の復元を待つ）
  Future<User?> currentUser() async => (await _auth()).authStateChanges().first;

  Future<void> signIn(String email, String password) async {
    final auth = await _auth();
    await auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> signOut() async => (await _auth()).signOut();

  /// 更新が新しい順に20件。after に前ページの last を渡すと続きを取得。
  Future<ClubPage> fetchPage({
    DocumentSnapshot<Map<String, dynamic>>? after,
  }) async {
    final db = await _db();
    Query<Map<String, dynamic>> q = db
        .collection('matches')
        .orderBy('updatedAt', descending: true)
        .limit(_pageSize);
    if (after != null) q = q.startAfterDocument(after);

    final snap = await q.get();
    final items = <ClubMatchItem>[];
    for (final d in snap.docs) {
      final data = d.data();
      final parsed = parseMatchData(data);
      if (parsed == null) continue;
      final ts = data['updatedAt'];
      items.add(
        ClubMatchItem(d.id, parsed, ts is Timestamp ? ts.toDate() : null),
      );
    }
    return ClubPage(
      items,
      snap.docs.isEmpty ? after : snap.docs.last,
      snap.docs.length == _pageSize,
    );
  }
}
