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
import 'gestures.dart';

/// Seberapa sering delta yang terkumpul dikirim ke host.
///
/// Mengirim tiap event sentuhan akan membanjiri socket — layar 120 Hz
/// menghasilkan 120 event per detik per jari. Mengumpulkannya per frame
/// membuat jumlah paket tetap masuk akal tanpa menambah latency yang terasa:
/// 8 ms masih jauh di bawah ambang yang bisa dirasakan tangan.
const Duration _flushInterval = Duration(milliseconds: 8);

/// Bitmask Ctrl, sesuai definisi di protokol.
const int _modCtrl = 2;

/// Perubahan jarak antar jari yang dihitung sebagai satu langkah zoom.
///
/// Ctrl + roda adalah zoom berundak di hampir semua aplikasi, jadi gestur yang
/// mulus harus diubah jadi undakan. Terlalu kecil membuat zoom meloncat liar;
/// terlalu besar membuat pinch terasa tidak merespons.
const double _zoomStep = 28;

class TrackpadPage extends StatefulWidget {
  const TrackpadPage({super.key, required this.conn});

  final DeckyConnection conn;

  @override
  State<TrackpadPage> createState() => _TrackpadPageState();
}

class _TrackpadPageState extends State<TrackpadPage> {
  final GestureTracker _gestures = GestureTracker();

  final List<List<int>> _pendingMove = [];
  Timer? _flusher;

  /// Sisa pecahan scroll dan zoom, supaya gerakan pelan tidak hilang karena
  /// pembulatan.
  double _scrollRestX = 0;
  double _scrollRestY = 0;
  double _zoomRest = 0;

  bool _dragging = false;

  final FocusNode _keyboardFocus = FocusNode();
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _flusher = Timer.periodic(_flushInterval, (_) => _flushMove());
  }

  @override
  void dispose() {
    _flusher?.cancel();
    _gestures.clear();
    _keyboardFocus.dispose();
    _textController.dispose();
    super.dispose();
  }

  // ── gestur ────────────────────────────────────────────────────────────

  void _onDown(PointerDownEvent e) => _gestures.down(e.pointer, e.position);

  void _onMove(PointerMoveEvent e) =>
      _apply(_gestures.move(e.pointer, e.position, e.delta));

  void _onUp(PointerUpEvent e) => _apply(_gestures.up(e.pointer));

  /// Android mengirim ini saat palm rejection, gestur sistem, atau recognizer
  /// merebut pointer. Mengabaikannya membuat jari seolah masih menempel, dan
  /// trackpad tersangkut di mode terakhirnya.
  void _onCancel(PointerCancelEvent e) =>
      _apply(_gestures.up(e.pointer, cancelled: true));

  void _onLongPress() => _apply(_gestures.longPress());

  void _apply(GestureOutput out) {
    if (out.isEmpty) return;

    if (out.move != Offset.zero) _queueMove(out.move);
    if (out.scroll != Offset.zero) _sendScroll(out.scroll);
    if (out.zoom != 0) _sendZoom(out.zoom);

    if (out.dragStart) {
      setState(() => _dragging = true);
      unawaited(HapticFeedback.mediumImpact());
      unawaited(_button(0, true));
    }
    if (out.dragEnd) {
      setState(() => _dragging = false);
      unawaited(_button(0, false));
    }
    if (out.tapButton case final button?) {
      unawaited(HapticFeedback.selectionClick());
      unawaited(_tap(button));
    }
  }

  void _queueMove(Offset delta) {
    final dx = delta.dx.round();
    final dy = delta.dy.round();
    if (dx == 0 && dy == 0) return;

    _pendingMove.add([dx, dy]);
    // Batch yang terlalu panjang berarti socket tidak mengejar; buang yang
    // tertua, karena gerakan lama sudah tidak relevan.
    if (_pendingMove.length > 60) _pendingMove.removeAt(0);
  }

  Future<void> _flushMove() async {
    if (_pendingMove.isEmpty) return;
    final batch = List<List<int>>.from(_pendingMove);
    _pendingMove.clear();
    await widget.conn.send(
      proto.MsgType.pointerMove,
      proto.PointerMove(e: batch, dt: _flushInterval.inMilliseconds).toMap(),
    );
  }

  void _sendScroll(Offset delta) {
    _scrollRestX += delta.dx;
    _scrollRestY += delta.dy;

    final dx = _scrollRestX.truncate();
    final dy = _scrollRestY.truncate();
    if (dx == 0 && dy == 0) return;

    _scrollRestX -= dx;
    _scrollRestY -= dy;
    unawaited(widget.conn.send(
      proto.MsgType.scroll,
      proto.Scroll(dx: dx, dy: dy).toMap(),
    ));
  }

  void _sendZoom(double spanDelta) {
    _zoomRest += spanDelta;

    final steps = (_zoomRest / _zoomStep).truncate();
    if (steps == 0) return;
    _zoomRest -= steps * _zoomStep;

    // Ctrl + roda. Host yang menahan dan melepas Ctrl di dalam satu panggilan,
    // jadi modifier tidak bisa tertinggal menyala kalau koneksi putus.
    unawaited(widget.conn.send(
      proto.MsgType.scroll,
      proto.Scroll(dx: 0, dy: steps * 40, mods: _modCtrl).toMap(),
    ));
  }

  // ── pengiriman ────────────────────────────────────────────────────────

  Future<void> _button(int btn, bool down) => widget.conn.send(
        proto.MsgType.pointerButton,
        proto.PointerButton(btn: btn, down: down).toMap(),
      );

  Future<void> _tap(int btn) async {
    await _button(btn, true);
    await _button(btn, false);
  }

  Future<void> _sendText(String text) async {
    if (text.isEmpty) return;
    _textController.clear();
    await widget.conn.send(proto.MsgType.text, proto.TextInput(s: text).toMap());
  }

  Future<void> _sendKey(String code, {int mods = 0}) async {
    await widget.conn.send(
      proto.MsgType.key,
      proto.KeyEvent(code: code, down: true, mods: mods).toMap(),
    );
    await widget.conn.send(
      proto.MsgType.key,
      proto.KeyEvent(code: code, down: false, mods: mods).toMap(),
    );
  }

  // ── tampilan ──────────────────────────────────────────────────────────

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
              onPointerDown: _onDown,
              onPointerMove: _onMove,
              onPointerUp: _onUp,
              onPointerCancel: _onCancel,
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
                    _dragging ? 'Menyeret…' : _hint,
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

  static const _hint = 'Geser untuk kursor · dua jari scroll · cubit untuk zoom';
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
