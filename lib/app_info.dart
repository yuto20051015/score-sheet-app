const String appName = 'スコアシート';
const String appVersion = 'ver1.1';
const String appDescription = 'ソフトテニス リアルタイム スコア管理＆スタッツ集計';
const String appPublisher = '大阪大学ソフトテニス部';

class ReleaseNote {
  final String version;
  final List<String> items;
  const ReleaseNote(this.version, this.items);
}

/// 新しい版を先頭に追加していく
const List<ReleaseNote> releaseNotes = [
  ReleaseNote('ver1.1', [
    '「次の試合へ」ボタンを追加（大会名・日付・会場・所属を引き継ぐ）',
    '入力画面とスタッツ・履歴をタブに分割',
    '「画面を消さない」設定を追加（メニューで切り替え）',
    'ポイントの流れ（履歴）を追加',
    'サーブ順の設定をメニューに移動',
    'ホーム画面用のアイコンと名称を整備',
    '「このアプリについて」（版情報・更新履歴）を追加',
  ]),
  ReleaseNote('ver1.0', ['初版リリース']),
];
