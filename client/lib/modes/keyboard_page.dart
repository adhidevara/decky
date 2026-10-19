/// Mode Keyboard: papan ketik penuh dengan modifier lengket.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/proto_gen.dart' as proto;
import '../transport/connection.dart';
import 'keyboard_layout.dart';

class KeyboardPage extends StatefulWidget {
  const KeyboardPage({super.key, required this.conn});

  final DeckyConnection conn;

  @override
  State<KeyboardPage> createState() => _KeyboardPageState();
}

class _KeyboardPageState extends State<KeyboardPage> {
  final ModifierBank _mods = ModifierBank();
  final TextEditingController _text = TextEditingController();
  bool _showFunctionRow = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _press(KeyCap key) async {
    if (key.action case final action?) {
      unawaited(HapticFeedback.selectionClick());
      setState(() {
        switch (action) {
          case KeyAction.toggleFunctionRow:
            _showFunctionRow = !_showFunctionRow;
        }
      });
      return;
    }
    if (key.modifier case final modifier?) {
      setState(() => _mods.tap(modifier));
      unawaited(HapticFeedback.selectionClick());
      return;
    }
    await _sendKey(key.code, _mods.mask);
    // Modifier sekali pakai habis di sini; yang terkunci bertahan.
    setState(_mods.consume);
  }

  Future<void> _sendKey(String code, int mods) async {
    unawaited(HapticFeedback.selectionClick());
    await widget.conn.send(
      proto.MsgType.key,
      proto.KeyEvent(code: code, down: true, mods: mods).toMap(),
    );
    await widget.conn.send(
      proto.MsgType.key,
      proto.KeyEvent(code: code, down: false, mods: mods).toMap(),
    );
  }

  Future<void> _sendText(String text) async {
    if (text.isEmpty) return;
    _text.clear();
    // Teks dikirim apa adanya sebagai Unicode, bukan sebagai rangkaian
    // tombol: dengan begitu layout keyboard di PC tidak berpengaruh, dan
    // karakter yang tidak ada di layout tetap bisa diketik.
    await widget.conn.send(proto.MsgType.text, proto.TextInput(s: text).toMap());
  }

  /// Tombol yang sedang menyala digambar sama seperti modifier terkunci —
  /// keduanya berarti "ini aktif sampai kamu mematikannya".
  ModState _highlightOf(KeyCap key) {
    if (key.action == KeyAction.toggleFunctionRow) {
      return _showFunctionRow ? ModState.locked : ModState.off;
    }
    final modifier = key.modifier;
    return modifier == null ? ModState.off : _mods.stateOf(modifier);
  }

  @override
  Widget build(BuildContext context) {
    final shift = _mods.isActive(Modifier.shift);
    final rows = [
      if (_showFunctionRow) ...functionRow,
      ...mainRows,
    ];

    return Scaffold(
      // Tanpa tombol pengalih di app bar: Fn ada di layout, dan dua kontrol
      // untuk hal yang sama hanya membuat orang menebak mana yang benar.
      appBar: AppBar(title: const Text('Keyboard')),
      body: Column(
        children: [
          _TextField(controller: _text, onSubmit: _sendText),
          _ComboBar(onCombo: (combo) => _sendKey(combo.code, combo.mods)),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                children: [
                  for (final row in rows)
                    Expanded(
                      child: Row(
                        // Tanpa stretch, Row menengahkan tombol pada tinggi
                        // teksnya dan barisnya jadi pipih dengan celah besar.
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final key in row)
                            Expanded(
                              // Lebar dinyatakan dalam kelipatan tombol huruf;
                              // dikali 10 supaya flex tetap bilangan bulat.
                              flex: (key.width * 10).round(),
                              child: _Key(
                                cap: key,
                                shift: shift,
                                state: _highlightOf(key),
                                onTap: () => _press(key),
                              ),
                            ),
                        ],
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
}

class _Key extends StatelessWidget {
  const _Key({
    required this.cap,
    required this.shift,
    required this.state,
    required this.onTap,
  });

  final KeyCap cap;
  final bool shift;
  final ModState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Tiga keadaan harus bisa dibedakan sekilas, jadi dibedakan dua-duanya:
    // warna isi untuk aktif, garis tepi untuk terkunci.
    final (background, foreground) = switch (state) {
      ModState.off => (scheme.surfaceContainerHigh, scheme.onSurface),
      ModState.latched => (scheme.primaryContainer, scheme.onPrimaryContainer),
      ModState.locked => (scheme.primary, scheme.onPrimary),
    };

    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                cap.labelFor(shift: shift),
                style: TextStyle(
                  fontSize: cap.label.length > 2 ? 13 : 17,
                  fontWeight: FontWeight.w500,
                  color: foreground,
                ),
              ),
              if (state == ModState.locked)
                Positioned(
                  top: 4,
                  right: 6,
                  child: Icon(Icons.lock, size: 11, color: foreground),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComboBar extends StatelessWidget {
  const _ComboBar({required this.onCombo});

  final void Function(Combo) onCombo;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: commonCombos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final combo = commonCombos[i];
          return Center(
            child: ActionChip(
              label: Text(combo.label),
              onPressed: () => onCombo(combo),
            ),
          );
        },
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final Future<void> Function(String) onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.send,
              decoration: const InputDecoration(
                hintText: 'Ketik panjang di sini lalu kirim…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: onSubmit,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            icon: const Icon(Icons.send),
            onPressed: () => onSubmit(controller.text),
          ),
        ],
      ),
    );
  }
}
