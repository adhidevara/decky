/// Mode Monitor: CPU, memori, GPU, jaringan, dan disk.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/proto_gen.dart';
import '../transport/connection.dart';
import '../transport/frame.dart';
import 'monitor_format.dart';

/// Seberapa sering host mengirim cuplikan.
///
/// Satu detik cukup untuk melihat beban berubah tanpa membuat radio HP
/// bekerja terus-menerus. Grafiknya memang bergerak pelan, dan itu wajar
/// untuk angka yang memang berubah pelan.
const int _intervalMs = 1000;

/// Panjang riwayat sparkline — 60 cuplikan berarti satu menit terakhir.
const int _historyLength = 60;

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key, required this.conn});

  final DeckyConnection conn;

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  StreamSubscription<Frame>? _subscription;
  MonitorTick? _tick;

  final History _cpu = History(_historyLength);
  final History _netRx = History(_historyLength);
  final History _netTx = History(_historyLength);
  final History _gpu = History(_historyLength);

  @override
  void initState() {
    super.initState();
    _subscription = widget.conn.messages.listen(_onMessage);
    _subscribe();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    // Berhenti berlangganan saat layar ditutup: tidak ada gunanya host
    // mengambil sampel untuk grafik yang tidak dilihat siapa pun.
    widget.conn.send(MsgType.monitorUnsub, const MonitorUnsub().toMap());
    super.dispose();
  }

  Future<void> _subscribe() async {
    // Minta hanya yang bisa ditampilkan. Host melewatkan pengambilan sampel
    // untuk apa pun yang tidak ada di daftar ini.
    final want = <MonitorSubWantItem>[
      MonitorSubWantItem.cpu,
      MonitorSubWantItem.mem,
      MonitorSubWantItem.net,
      MonitorSubWantItem.disk,
      if (widget.conn.supports(Capability.monitorGpu)) MonitorSubWantItem.gpu,
      if (widget.conn.supports(Capability.monitorCpuTemp)) MonitorSubWantItem.temp,
    ];

    await widget.conn.send(
      MsgType.monitorSub,
      MonitorSub(intervalMs: _intervalMs, want: want).toMap(),
    );
  }

  void _onMessage(Frame frame) {
    if (frame.type != MsgType.monitorTick || !mounted) return;

    final tick = MonitorTick.fromMap(frame.data);
    setState(() {
      _tick = tick;
      _cpu.add(tick.cpu);
      _netRx.add(tick.netRx.toDouble());
      _netTx.add(tick.netTx.toDouble());
      if (tick.gpu?.util case final util?) _gpu.add(util);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tick = _tick;

    return Scaffold(
      appBar: AppBar(title: const Text('Monitor')),
      body: tick == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Menunggu data dari host…'),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _CpuCard(tick: tick, history: _cpu),
                const SizedBox(height: 12),
                _MemoryCard(tick: tick),
                if (tick.gpu case final gpu?) ...[
                  const SizedBox(height: 12),
                  _GpuCard(gpu: gpu, history: _gpu),
                ],
                const SizedBox(height: 12),
                _NetworkCard(tick: tick, rx: _netRx, tx: _netTx),
                const SizedBox(height: 12),
                _DiskCard(tick: tick),
              ],
            ),
    );
  }
}

// ── kartu ───────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.trailing, required this.child});

  final String title;
  final String trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Text(
                trailing,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _CpuCard extends StatelessWidget {
  const _CpuCard({required this.tick, required this.history});

  final MonitorTick tick;
  final History history;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: tick.cpuTemp == null
          ? 'CPU'
          : 'CPU · ${formatTemperature(tick.cpuTemp!)}',
      trailing: formatPercent(tick.cpu),
      child: Column(
        children: [
          SizedBox(height: 56, child: Sparkline(history: history, max: 100)),
          if (tick.cpuPerCore case final cores?) ...[
            const SizedBox(height: 12),
            _CoreBars(cores: cores),
          ],
        ],
      ),
    );
  }
}

class _CoreBars extends StatelessWidget {
  const _CoreBars({required this.cores});

  final List<double> cores;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final core in cores)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: SizedBox(
                height: 28,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: (core / 100).clamp(0.02, 1),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.tick});

  final MonitorTick tick;

  @override
  Widget build(BuildContext context) {
    final total = tick.memTotal;
    final fraction = total == 0 ? 0.0 : tick.memUsed / total;

    return _Card(
      title: 'Memori',
      trailing: formatPercent(fraction * 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction.clamp(0, 1),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${formatBytes(tick.memUsed)} dari ${formatBytes(total)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _GpuCard extends StatelessWidget {
  const _GpuCard({required this.gpu, required this.history});

  final Gpu gpu;
  final History history;

  @override
  Widget build(BuildContext context) {
    final memory = (gpu.memUsed != null && gpu.memTotal != null)
        ? '${formatBytes(gpu.memUsed!)} dari ${formatBytes(gpu.memTotal!)}'
        : null;

    return _Card(
      title: gpu.temp == null ? gpu.name : '${gpu.name} · ${formatTemperature(gpu.temp!)}',
      trailing: gpu.util == null ? '—' : formatPercent(gpu.util!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 56, child: Sparkline(history: history, max: 100)),
          if (memory != null) ...[
            const SizedBox(height: 8),
            Text(memory, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.tick, required this.rx, required this.tx});

  final MonitorTick tick;
  final History rx;
  final History tx;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Satu skala untuk kedua arah, kalau tidak unduhan kecil akan terlihat
    // sama besar dengan unggahan besar.
    final scale = math.max(rx.max, math.max(tx.max, 1.0));

    return _Card(
      title: 'Jaringan',
      trailing: formatRate(tick.netRx),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              children: [
                Sparkline(history: rx, max: scale),
                Sparkline(history: tx, max: scale, color: scheme.tertiary),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Legend(color: scheme.primary, label: '↓ ${formatRate(tick.netRx)}'),
              const SizedBox(width: 16),
              _Legend(color: scheme.tertiary, label: '↑ ${formatRate(tick.netTx)}'),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({required this.tick});

  final MonitorTick tick;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Disk',
      trailing: formatRate(tick.diskR + tick.diskW),
      child: Row(
        children: [
          Expanded(child: Text('Baca  ${formatRate(tick.diskR)}')),
          Expanded(child: Text('Tulis ${formatRate(tick.diskW)}')),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 3,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// ── sparkline ───────────────────────────────────────────────────────────

class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.history, required this.max, this.color});

  final History history;
  final double max;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _SparklinePainter(
        values: history.values,
        max: max,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.max, required this.color});

  final List<double> values;
  final double max;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || max <= 0) return;

    // Grafik selalu digambar dengan lebar penuh riwayat, bukan hanya nilai
    // yang sudah ada. Tanpa itu, garis akan meregang saat buffer terisi dan
    // terlihat seperti data yang berubah padahal tidak.
    final step = size.width / (_historyLength - 1);
    final offset = size.width - step * (values.length - 1);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = offset + step * i;
      final y = size.height * (1 - (values[i] / max).clamp(0, 1));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }

    final fill = Path.from(path)
      ..lineTo(offset + step * (values.length - 1), size.height)
      ..lineTo(offset, size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()..color = color.withValues(alpha: 0.15),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values.length != values.length ||
      old.max != max ||
      old.color != color ||
      (values.isNotEmpty && old.values.isNotEmpty && old.values.last != values.last);
}
