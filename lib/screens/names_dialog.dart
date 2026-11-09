import 'package:flutter/material.dart';

import '../models/match_info.dart';
import '../models/match_state.dart';
import '../models/player_names.dart';

/// ダイアログの入力結果
class MatchSetup {
  final MatchInfo info;
  final PlayerNames names;
  const MatchSetup(this.info, this.names);
}

/// 大会名・自ペア・相手ペア・日付・会場・メモ を入力するダイアログ
class MatchSetupDialog extends StatefulWidget {
  final MatchInfo info;
  final PlayerNames names;
  const MatchSetupDialog({super.key, required this.info, required this.names});

  @override
  State<MatchSetupDialog> createState() => _MatchSetupDialogState();
}

class _MatchSetupDialogState extends State<MatchSetupDialog> {
  static const Color _colorA = Color(0xFF1565C0);
  static const Color _colorB = Color(0xFFC62828);

  late final _title = TextEditingController(text: widget.info.title);
  late final _venue = TextEditingController(text: widget.info.venue);
  late final _note = TextEditingController(text: widget.info.note);
  late DateTime? _date = widget.info.date;

  // 所属（ペアごと）
  late final Map<Team, TextEditingController> _aff = {
    for (final t in Team.values)
      t: TextEditingController(text: widget.names.affiliation(t)),
  };

  // 選手名（デフォルト名のままの人は空欄にして、ヒントとして表示）
  late final Map<Player, TextEditingController> _player = {
    for (final p in Player.values)
      p: TextEditingController(
        text: widget.names.isDefault(p) ? '' : widget.names.of(p),
      ),
  };

  @override
  void dispose() {
    _title.dispose();
    _venue.dispose();
    _note.dispose();
    for (final c in _aff.values) {
      c.dispose();
    }
    for (final c in _player.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  String get _dateLabel =>
      _date == null ? '日付を選ぶ' : MatchInfo(date: _date).dateText;

  void _submit() {
    var names = widget.names;
    for (final t in Team.values) {
      names = names.setAffiliation(t, _aff[t]!.text);
    }
    names = names.renameAll({
      for (final e in _player.entries) e.key: e.value.text,
    });

    Navigator.pop(
      context,
      MatchSetup(
        MatchInfo(
          title: _title.text.trim(),
          date: _date,
          venue: _venue.text.trim(),
          note: _note.text.trim(),
        ),
        names,
      ),
    );
  }

  // ---------- 部品 ----------
  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    int maxLength = 30,
    int maxLines = 1,
  }) {
    return TextField(
      controller: c,
      maxLength: maxLength,
      maxLines: maxLines,
      textInputAction: maxLines == 1
          ? TextInputAction.next
          : TextInputAction.newline,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: '',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _pairSection(Team t, Color color) {
    final players = Player.of(t);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withAlpha(14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.label,
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 8),
          _field(
            _aff[t]!,
            '所属',
            hint: '例：大阪大学',
            maxLength: PlayerNames.maxAffiliation,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < players.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _field(
                    _player[players[i]]!,
                    '選手${i + 1}',
                    hint: '${players[i].label}選手',
                    maxLength: PlayerNames.maxLength,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('試合情報'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(_title, '大会名', hint: '例：○○市民大会 準決勝'),
              const SizedBox(height: 12),
              _pairSection(Team.a, _colorA),
              const SizedBox(height: 10),
              _pairSection(Team.b, _colorB),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today, size: 18),
                      label: Text(_dateLabel),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _date = DateTime.now()),
                    child: const Text('今日'),
                  ),
                  if (_date != null)
                    IconButton(
                      tooltip: '日付を消す',
                      onPressed: () => setState(() => _date = null),
                      icon: const Icon(Icons.clear),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _field(_venue, '会場', maxLength: MatchInfo.maxVenue),
              const SizedBox(height: 12),
              _field(
                _note,
                'メモ',
                hint: '例：第2コート',
                maxLength: MatchInfo.maxNote,
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}

/// 試合コード入力ダイアログ。OK で大文字・trim 済みの文字列を返す。
class JoinCodeDialog extends StatefulWidget {
  const JoinCodeDialog({super.key});

  @override
  State<JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<JoinCodeDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('試合コードで参加'),
      content: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 6,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(
          labelText: '6文字のコード',
          counterText: '',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim().toUpperCase()),
          child: const Text('参加'),
        ),
      ],
    );
  }
}
