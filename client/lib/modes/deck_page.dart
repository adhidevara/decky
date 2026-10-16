/// Mode Deck: grid tombol makro.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/proto_gen.dart';
import '../transport/frame.dart';
import '../transport/connection.dart';

class DeckPage extends StatefulWidget {
  const DeckPage({super.key, required this.conn});

  final DeckyConnection conn;

  @override
  State<DeckPage> createState() => _DeckPageState();
}

class _DeckPageState extends State<DeckPage> {
  DeckLayout? _layout;
  DeckProfiles? _profiles;
  String? _error;
  final Set<int> _pressed = {};

  @override
  void initState() {
    super.initState();
    widget.conn.messages.listen(_onMessage);
  }

  void _onMessage(Frame frame) {
    if (!mounted) return;
    switch (frame.type) {
      case MsgType.deckLayout:
        setState(() => _layout = DeckLayout.fromMap(frame.data));
      case MsgType.deckProfiles:
        setState(() => _profiles = DeckProfiles.fromMap(frame.data));
      case MsgType.error:
        final err = ErrorMsg.fromMap(frame.data);
        setState(() => _error = err.msg);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err.msg), behavior: SnackBarBehavior.floating),
        );
    }
  }

  Future<void> _press(Button b) async {
    setState(() => _pressed.add(b.idx));
    // Getar pendek memberi konfirmasi bahwa tekanan terkirim, tanpa perlu
    // menunggu balasan host.
    unawaited(HapticFeedback.selectionClick());
    await widget.conn.send(MsgType.deckPress, DeckPress(idx: b.idx).toMap());
  }

  Future<void> _release(Button b) async {
    setState(() => _pressed.remove(b.idx));
    await widget.conn.send(MsgType.deckRelease, DeckRelease(idx: b.idx).toMap());
  }

  Future<void> _switchProfile(String id) =>
      widget.conn.send(MsgType.deckSwitchProfile, DeckSwitchProfile(profileId: id).toMap());

  @override
  Widget build(BuildContext context) {
    final layout = _layout;

    return Scaffold(
      appBar: AppBar(
        title: Text(layout?.name ?? 'Deck'),
        actions: [
          if ((_profiles?.profiles.length ?? 0) > 1)
            PopupMenuButton<String>(
              icon: const Icon(Icons.layers),
              tooltip: 'Ganti profil',
              onSelected: _switchProfile,
              itemBuilder: (_) => [
                for (final p in _profiles!.profiles)
                  PopupMenuItem(
                    value: p.id,
                    child: Row(
                      children: [
                        if (p.id == _profiles!.active)
                          const Icon(Icons.check, size: 18)
                        else
                          const SizedBox(width: 18),
                        const SizedBox(width: 8),
                        Text(p.name),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: layout == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_error ?? 'Menunggu layout dari host…'),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: layout.cols,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemCount: layout.cols * layout.rows,
                itemBuilder: (context, i) {
                  // Grid selalu digambar penuh; petak tanpa tombol dibiarkan
                  // kosong supaya posisi tombol tidak bergeser antar profil.
                  final button = layout.buttons.where((b) => b.idx == i).firstOrNull;
                  if (button == null) return const _EmptySlot();
                  return _DeckButton(
                    button: button,
                    pressed: _pressed.contains(button.idx),
                    onDown: () => _press(button),
                    onUp: () => _release(button),
                  );
                },
              ),
            ),
    );
  }
}

class _DeckButton extends StatelessWidget {
  const _DeckButton({
    required this.button,
    required this.pressed,
    required this.onDown,
    required this.onUp,
  });

  final Button button;
  final bool pressed;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = button.color != null ? _parseHex(button.color!) : null;
    final base = tint ?? scheme.surfaceContainerHighest;

    return Semantics(
      button: true,
      label: button.actionHint == null
          ? button.label
          : '${button.label}. ${button.actionHint}',
      child: GestureDetector(
        onTapDown: (_) => onDown(),
        onTapUp: (_) => onUp(),
        onTapCancel: onUp,
        child: AnimatedScale(
          scale: pressed ? 0.94 : 1,
          duration: const Duration(milliseconds: 80),
          child: Container(
            decoration: BoxDecoration(
              color: pressed ? Color.alphaBlend(Colors.black26, base) : base,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            child: Text(
              button.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: tint != null
                    ? _readableOn(tint)
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptySlot extends StatelessWidget {
  const _EmptySlot();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
    );
  }
}

Color _parseHex(String hex) {
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return value == null ? Colors.grey : Color(0xFF000000 | value);
}

/// Hitam atau putih, mana pun yang lebih terbaca di atas warna tombol.
Color _readableOn(Color background) =>
    background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
