/// Mode Trackpad: kontrol pointer dan keyboard.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Protokol diimpor dengan prefix: Flutter sudah memiliki Text, Key, KeyEvent,
// TextInput dan ButtonStyle, dan mengganti nama di skema setiap kali bentrok
// adalah permainan yang tidak akan selesai.
import '../protocol/proto_gen.dart' as proto;
import '../transport/connection.dart';

/// Seberapa sering delta yang terkumpul dikirim ke host.
///
/// Mengirim tiap event sentuhan akan membanjiri socket — layar 120 Hz
/// menghasilkan 120 event per detik per jari. Mengumpulkannya per frame
/// membuat jumlah paket tetap masuk akal tanpa menambah latency yang terasa:
/// 8 ms masih jauh di bawah ambang yang bisa dirasakan tangan.
const Duration _flushInterval = Duration(milliseconds: 8);

/// Jarak maksimal yang masih dianggap ketukan, bukan geseran.
const double _tapSlop = 12;

/// Durasi maksimal sebuah ketukan.
const Duration _tapTimeout = Duration(milliseconds: 250);

class TrackpadPage extends StatefulWidget {
  const TrackpadPage({super.key, required this.conn});

  final DeckyConnection conn;

  @override
  State<TrackpadPage> createState() => _TrackpadPageState();
}

class _TrackpadPageState extends State<TrackpadPage> {
  final List<List<int>> _pending = [];
  Timer? _flusher;

  /// Akumulasi scroll sampai cukup besar untuk dikirim sebagai piksel bulat.
  double _scrollRestX = 0;
  double _scrollRestY = 0;

  int _pointers = 0;
  /// Jumlah jari terbanyak selama satu sentuhan — itulah yang menentukan
  /// arti ketukan, karena saat jari diangkat hitungannya sudah turun.
  int _maxPointers = 0;
  Offset _travel = Offset.zero;
  DateTime? _touchStart;
  bool _dragging = false;

  final FocusNode _keyboardFocus = FocusNode();
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _flusher = Timer.periodic(_flushInterval, (_) => _flush());
  }

  @override
  void dispose() {
    _flusher?.cancel();
    _keyboardFocus.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final batch = List<List<int>>.from(_pending);
    _pending.clear();
    await widget.conn.send(
      proto.MsgType.pointerMove,
      proto.PointerMove(e: batch, dt: _flushInterval.inMilliseconds).toMap(),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    _maxPointers = _pointers > _maxPointers ? _pointers : _maxPointers;
    if (_pointers == 1) {
      _travel = Offset.zero;
      _touchStart = DateTime.now();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    _travel += event.delta;

    if (_pointers >= 2) {
      _accumulateScroll(event.delta);
      return;
    }

    // Delta datang sebagai double karena ada penskalaan piksel; dibulatkan
    // di sini, dan sisa pecahannya ditangani host lewat akumulatornya.
    final dx = event.delta.dx.round();
    final dy = event.delta.dy.round();
    if (dx != 0 || dy != 0) {
      _pending.add([dx, dy]);
      // Batch yang terlalu panjang berarti socket tidak mengejar; buang yang
      // tertua, karena gerakan lama sudah tidak relevan.
      if (_pending.length > 60) _pending.removeAt(0);
    }
  }

  void _accumulateScroll(Offset delta) {
    _scrollRestX += delta.dx;
    _scrollRestY += delta.dy;

    final dx = _scrollRestX.truncate();
    final dy = _scrollRestY.truncate();
    if (dx == 0 && dy == 0) return;

    _scrollRestX -= dx;
    _scrollRestY -= dy;
    widget.conn.send(proto.MsgType.scroll, proto.Scroll(dx: dx, dy: dy).toMap());
  }

  Future<void> _onPointerUp(PointerUpEvent event) async {
    _pointers = _pointers > 0 ? _pointers - 1 : 0;
    if (_pointers > 0) return;

    final fingers = _maxPointers;
    final travel = _travel.distance;
    final held = DateTime.now().difference(_touchStart ?? DateTime.now());
    _maxPointers = 0;
    _scrollRestX = 0;
    _scrollRestY = 0;

    if (_dragging) {
      _dragging = false;
      await _button(0, false);
      return;
    }

    final isTap = travel < _tapSlop && held < _tapTimeout;
    if (!isTap) return;

    // Satu jari klik kiri, dua jari klik kanan — kebiasaan yang sama dengan
    // trackpad laptop, jadi tidak perlu dipelajari ulang.
    final button = switch (fingers) {
      1 => 0,
      2 => 2,
      3 => 1,
      _ => null,
    };
    if (button == null) return;

    unawaited(HapticFeedback.selectionClick());
    await _button(button, true);
    await _button(button, false);
  }

  Future<void> _button(int btn, bool down) => widget.conn.send(
        proto.MsgType.pointerButton,
        proto.PointerButton(btn: btn, down: down).toMap(),
      );

  /// Tekan-tahan memulai seret: tombol kiri ditahan sampai jari diangkat.
  Future<void> _onLongPress() async {
    if (_pointers != 1 || _dragging) return;
    _dragging = true;
    unawaited(HapticFeedback.mediumImpact());
    await _button(0, true);
  }

  Future<void> _sendText(String text) async {
    if (text.isEmpty) return;
    _textController.clear();
    await widget.conn.send(proto.MsgType.text, proto.TextInput(s: text).toMap());
  }

  Future<void> _sendKey(String code, {int mods = 0}) async {
    await widget.conn.send(proto.MsgType.key, proto.KeyEvent(code: code, down: true, mods: mods).toMap());
    await widget.conn.send(proto.MsgType.key, proto.KeyEvent(code: code, down: false, mods: mods).toMap());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trackpad'),
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard),
            tooltip: 'Keyboard',
            onPressed: () => _keyboardFocus.requestFocus(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: _onLongPress,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _dragging ? 'Menyeret…' : 'Geser untuk menggerakkan kursor',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          _ButtonBar(onPress: _button),
          _KeyboardBar(
            focusNode: _keyboardFocus,
            controller: _textController,
            onText: _sendText,
            onKey: _sendKey,
          ),
        ],
      ),
    );
  }
}

/// Tombol mouse eksplisit, untuk saat ketukan multi-jari tidak praktis.
class _ButtonBar extends StatelessWidget {
  const _ButtonBar({required this.onPress});

  final Future<void> Function(int btn, bool down) onPress;

  @override
  Widget build(BuildContext context) {
    Widget button(String label, int btn, {int flex = 1}) => Expanded(
          flex: flex,
          child: GestureDetector(
            onTapDown: (_) {
              HapticFeedback.selectionClick();
              onPress(btn, true);
            },
            onTapUp: (_) => onPress(btn, false),
            onTapCancel: () => onPress(btn, false),
            child: Container(
              height: 52,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(label),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          button('Kiri', 0, flex: 2),
          button('Tengah', 1),
          button('Kanan', 2, flex: 2),
        ],
      ),
    );
  }
}

/// Input teks plus tombol khusus yang paling sering dipakai.
class _KeyboardBar extends StatelessWidget {
  const _KeyboardBar({
    required this.focusNode,
    required this.controller,
    required this.onText,
    required this.onKey,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final Future<void> Function(String text) onText;
  final Future<void> Function(String code, {int mods}) onKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  focusNode: focusNode,
                  controller: controller,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(
                    hintText: 'Ketik lalu kirim ke PC…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: onText,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.send),
                onPressed: () => onText(controller.text),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final (label, code) in const [
                ('Esc', 'Escape'),
                ('Tab', 'Tab'),
                ('Enter', 'Enter'),
                ('⌫', 'Backspace'),
                ('←', 'ArrowLeft'),
                ('↑', 'ArrowUp'),
                ('↓', 'ArrowDown'),
                ('→', 'ArrowRight'),
              ])
                ActionChip(label: Text(label), onPressed: () => onKey(code)),
            ],
          ),
        ],
      ),
    );
  }
}
