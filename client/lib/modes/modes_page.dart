/// Rumah untuk semua mode setelah tersambung.
library;

import 'package:flutter/material.dart';

import '../protocol/proto_gen.dart';
import '../transport/connection.dart';
import 'deck_page.dart';
import 'keyboard_page.dart';
import 'monitor_page.dart';
import 'trackpad_page.dart';

class ModesPage extends StatefulWidget {
  const ModesPage({super.key, required this.conn});

  final DeckyConnection conn;

  @override
  State<ModesPage> createState() => _ModesPageState();
}

class _ModesPageState extends State<ModesPage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Koneksi putus berarti layar ini tidak punya apa-apa untuk ditampilkan;
    // kembali ke daftar host daripada memamerkan tombol yang tidak berfungsi.
    widget.conn.addListener(_onConnectionChanged);
  }

  @override
  void dispose() {
    widget.conn.removeListener(_onConnectionChanged);
    super.dispose();
  }

  void _onConnectionChanged() {
    final state = widget.conn.status.state;
    if (state == ConnState.idle || state == ConnState.failed) {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mode hanya muncul kalau host memang mendukungnya. Tab yang menganggur
    // lebih buruk daripada tab yang tidak ada.
    final modes = <_Mode>[
      if (widget.conn.supports(Capability.deck))
        _Mode(
          icon: Icons.grid_view,
          label: 'Deck',
          build: () => DeckPage(conn: widget.conn),
        ),
      if (widget.conn.supports(Capability.input)) ...[
        _Mode(
          icon: Icons.touch_app,
          label: 'Trackpad',
          build: () => TrackpadPage(conn: widget.conn),
        ),
        _Mode(
          icon: Icons.keyboard,
          label: 'Keyboard',
          build: () => KeyboardPage(conn: widget.conn),
        ),
      ],
      if (widget.conn.supports(Capability.monitor))
        _Mode(
          icon: Icons.speed,
          label: 'Monitor',
          build: () => MonitorPage(conn: widget.conn),
        ),
    ];

    if (modes.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Decky')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Host ini belum mengumumkan mode apa pun.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final index = _index.clamp(0, modes.length - 1);

    return Scaffold(
      // IndexedStack, bukan rebuild: berpindah tab tidak boleh membuang state
      // trackpad atau memuat ulang ikon deck.
      body: IndexedStack(
        index: index,
        children: [for (final mode in modes) mode.build()],
      ),
      bottomNavigationBar: modes.length < 2
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final mode in modes)
                  NavigationDestination(icon: Icon(mode.icon), label: mode.label),
              ],
            ),
    );
  }
}

class _Mode {
  const _Mode({required this.icon, required this.label, required this.build});

  final IconData icon;
  final String label;
  final Widget Function() build;
}
