/// Mode Deck: grid tombol makro.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../protocol/proto_gen.dart';
import '../transport/blob_cache.dart';
import '../transport/connection.dart';
import '../transport/frame.dart';

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
  /// Tombol toggle yang sedang menyala, menurut host.
  final Set<int> _active = {};
  final BlobCache _blobs = BlobCache();
  StreamSubscription<Frame>? _subscription;

  @override
  void initState() {
    super.initState();

    // Layout biasanya sudah tiba sebelum layar ini dibuka, jadi ambil dulu
    // yang tersimpan sebelum mulai mendengarkan yang berikutnya.
    final layout = widget.conn.latest(MsgType.deckLayout);
    if (layout != null) {
      _layout = DeckLayout.fromMap(layout.data);
      _fetchIcons(_layout!);
    }
    final profiles = widget.conn.latest(MsgType.deckProfiles);
    if (profiles != null) {
      _profiles = DeckProfiles.fromMap(profiles.data);
    }
    _active.addAll(
      widget.conn.deckState.entries.where((e) => e.value).map((e) => e.key),
    );

    _subscription = widget.conn.messages.listen(_onMessage);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onMessage(Frame frame) {
    if (!mounted) return;
    switch (frame.type) {
      case MsgType.deckLayout:
        final layout = DeckLayout.fromMap(frame.data);
        setState(() => _layout = layout);
        _fetchIcons(layout);
      case MsgType.deckProfiles:
        setState(() => _profiles = DeckProfiles.fromMap(frame.data));
      case MsgType.deckState:
        final state = DeckState.fromMap(frame.data);
        setState(() {
          if (state.active) {
            _active.add(state.idx);
          } else {
            _active.remove(state.idx);
          }
        });
      case MsgType.blob:
        final blob = Blob.fromMap(frame.data);
        _blobs.store(blob.blobId, blob.mime.wire, blob.data).then((_) {
          if (mounted) setState(() {});
        });
      case MsgType.error:
        final err = ErrorMsg.fromMap(frame.data);
        setState(() => _error = err.msg);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err.msg), behavior: SnackBarBehavior.floating),
        );
    }
  }

  /// Minta ikon yang belum ada di cache.
  ///
  /// Ikon dialamatkan oleh hash isinya, jadi cache yang sudah terisi tidak
  /// pernah perlu divalidasi ulang — cukup sekali unduh per ikon, selamanya.
  Future<void> _fetchIcons(DeckLayout layout) async {
    for (final button in layout.buttons) {
      final id = button.iconId;
      if (id == null) continue;

      final cached = await _blobs.load(id);
      if (cached != null) {
        if (mounted) setState(() {});
        continue;
      }
      if (_blobs.markRequested(id)) {
        await widget.conn.send(MsgType.wantBlob, WantBlob(blobId: id).toMap());
      }
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
                    active: _active.contains(button.idx),
                    icon: button.iconId == null ? null : _blobs.peek(button.iconId!),
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
    required this.active,
    required this.icon,
    required this.onDown,
    required this.onUp,
  });

  final Button button;
  final bool pressed;
  final bool active;
  final CachedBlob? icon;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = button.color != null ? _parseHex(button.color!) : null;
    final isToggle = button.style == ButtonDisplayStyle.toggle;

    // Toggle yang padam sengaja digambar redup, bukan diberi warna lain:
    // perbedaan terang/gelap terbaca sekilas, bahkan dari sudut mata.
    final base = switch ((tint, isToggle && !active)) {
      (final Color c, false) => c,
      (final Color c, true) => Color.alphaBlend(c.withValues(alpha: 0.28), scheme.surface),
      (null, true) => scheme.surfaceContainerLow,
      (null, false) => scheme.surfaceContainerHighest,
    };
    final foreground = tint != null && !(isToggle && !active)
        ? _readableOn(base)
        : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      toggled: isToggle ? active : null,
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: pressed ? Color.alphaBlend(Colors.black26, base) : base,
              borderRadius: BorderRadius.circular(14),
              border: isToggle && active
                  ? Border.all(color: foreground.withValues(alpha: 0.65), width: 2)
                  : null,
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Flexible(child: _Icon(blob: icon!, tint: foreground)),
                  const SizedBox(height: 6),
                ],
                Text(
                  button.label,
                  textAlign: TextAlign.center,
                  maxLines: icon != null ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: icon != null ? 12 : 15,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Icon extends StatelessWidget {
  const _Icon({required this.blob, required this.tint});

  final CachedBlob blob;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    if (blob.isSvg) {
      // SVG ikon biasanya satu warna; diwarnai mengikuti teks supaya tetap
      // terbaca di tema terang maupun gelap.
      return SvgPicture.memory(
        blob.bytes,
        height: 32,
        colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      );
    }
    return Image.memory(
      blob.bytes,
      height: 32,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => Icon(Icons.broken_image, size: 24, color: tint),
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
