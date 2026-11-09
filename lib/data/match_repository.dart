import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/match_info.dart';
import '../models/match_state.dart';
import '../models/player_names.dart';
import 'match_codec.dart';

/// クラウドから読み取った試合1件ぶん
class MatchSnapshot {
  final MatchState state;
  final PlayerNames names;
  final MatchInfo info;
  final String ownerUid;
  const MatchSnapshot({
    required this.state,
    required this.names,
    required this.info,
    required this.ownerUid,
  });
}

class FirestoreMatchRepository {
  FirestoreMatchRepository({FirebaseFirestore? db, FirebaseAuth? auth})
    : _db = db ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  static const _collection = 'matches';
  // 紛らわしい文字（0/O, 1/I）を除いたコード用文字
  static const _codeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  DocumentReference<Map<String, dynamic>> _doc(String id) =>
      _db.collection(_collection).doc(id);

  /// 現在の端末の uid（未ログインなら null）
  String? get uid => _auth.currentUser?.uid;

  /// 匿名ログイン（すでにログイン済みなら何もしない）
  Future<String> ensureSignedIn() async {
    final user = _auth.currentUser ?? (await _auth.signInAnonymously()).user;
    return user!.uid;
  }

  Map<String, dynamic> _toDoc(
    String ownerUid,
    MatchState s,
    PlayerNames n,
    MatchInfo info,
  ) => {
    'schema': MatchCodec.schemaVersion,
    'ownerUid': ownerUid,
    'names': n.toMap(),
    'info': info.toMap(),
    'state': MatchCodec.encodeState(s),
    'updatedAt': FieldValue.serverTimestamp(),
  };

  MatchSnapshot? _parse(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    if (data == null) return null;
    final st = data['state'];
    if (st is! Map) return null;
    final names = data['names'];
    final info = data['info'];
    return MatchSnapshot(
      state: MatchCodec.decodeState(Map<String, dynamic>.from(st)),
      names: PlayerNames.fromMap(
        names is Map ? Map<String, dynamic>.from(names) : null,
      ),
      info: MatchInfo.fromMap(
        info is Map ? Map<String, dynamic>.from(info) : null,
      ),
      ownerUid: data['ownerUid'] as String? ?? '',
    );
  }

  /// 新しい試合を作成し、試合コードを返す（初回のみ通信が必要）
  Future<String> createMatch(
    MatchState s,
    PlayerNames n,
    MatchInfo info,
  ) async {
    final me = await ensureSignedIn();
    final rnd = Random.secure();
    for (var i = 0; i < 5; i++) {
      final code = List.generate(
        6,
        (_) => _codeChars[rnd.nextInt(_codeChars.length)],
      ).join();
      final ref = _doc(code);
      if ((await ref.get()).exists) continue; // コード衝突 → 再抽選
      await ref.set(_toDoc(me, s, n, info));
      return code;
    }
    throw StateError('試合コードを発行できませんでした。もう一度お試しください。');
  }

  /// 状態を保存（オーナーのみ成功）。
  /// 圏外でもローカルにキューされるため、呼び出し側は await しなくてよい。
  Future<void> save(
    String matchId,
    MatchState s,
    PlayerNames n,
    MatchInfo info,
  ) {
    final me = uid;
    if (me == null) throw StateError('未ログインです');
    return _doc(matchId).set(_toDoc(me, s, n, info));
  }

  /// 1回だけ取得（参加時の初期読み込み用）
  Future<MatchSnapshot?> fetch(String matchId) async {
    await ensureSignedIn();
    return _parse(await _doc(matchId).get());
  }

  /// リアルタイム購読（閲覧側用）
  Stream<MatchSnapshot?> watch(String matchId) =>
      _doc(matchId).snapshots().map(_parse);
}
