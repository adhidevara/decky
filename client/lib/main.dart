import 'package:flutter/material.dart';

import 'modes/modes_page.dart';
import 'transport/connection.dart';
import 'transport/discovery.dart';
import 'transport/identity.dart';

void main() => runApp(const DeckyApp());

class DeckyApp extends StatelessWidget {
  const DeckyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Decky',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F6FED),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ConnectPage(),
    );
  }
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final Discovery _discovery = Discovery();
  List<HostEndpoint> _hosts = [];
  DeckyConnection? _conn;
  String? _setupError;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final identity = await Identity.load();
      final conn = DeckyConnection(identity);
      conn.addListener(() => setState(() {}));
      if (!mounted) return;
      setState(() => _conn = conn);

      await _discovery.start();
      _discovery.hosts.listen((hosts) {
        if (mounted) setState(() => _hosts = hosts);
      });
    } catch (e) {
      if (mounted) setState(() => _setupError = '$e');
    }
  }

  @override
  void dispose() {
    _discovery.dispose();
    _conn?.dispose();
    super.dispose();
  }

  Future<void> _connect(HostEndpoint host) async {
    final conn = _conn!;

    // Mode sesi dicoba dulu; kalau host belum mengenal device ini, layer
    // koneksi memanggil balik untuk minta PIN. Urutan itu perlu karena lewat
    // USB `host_id` baru diketahui setelah Hello terkirim.
    await conn.connect(host, askPin: (_) => _askPin(host));
    if (!mounted) return;

    // Begitu tersambung, deck adalah layar yang sebenarnya dipakai orang;
    // daftar host hanya pintu masuk.
    if (conn.status.isLive) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ModesPage(conn: conn)),
      );
    }
  }

  Future<String?> _askPin(HostEndpoint host) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pairing dengan ${host.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Buka Decky Host di PC, tekan "Pairing", lalu masukkan PIN-nya.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(fontSize: 28, letterSpacing: 8),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(counterText: '', hintText: '000000'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Sambungkan'),
          ),
        ],
      ),
    ).then((pin) => (pin != null && pin.length == 6) ? pin : null);
  }

  @override
  Widget build(BuildContext context) {
    final conn = _conn;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Decky'),
        actions: [
          if (conn?.status.isLive ?? false)
            IconButton(
              icon: const Icon(Icons.link_off),
              tooltip: 'Putuskan',
              onPressed: conn!.disconnect,
            ),
        ],
      ),
      body: _setupError != null
          ? _Message(icon: Icons.error_outline, text: 'Gagal menyiapkan: $_setupError')
          : conn == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _StatusCard(status: conn.status),
                    const SizedBox(height: 24),
                    Text('Host ditemukan', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    // USB selalu ditawarkan: adb reverse tidak muncul di mDNS,
                    // tapi jalurnya yang paling cepat kalau kabel tercolok.
                    _HostTile(
                      host: HostEndpoint.usb,
                      subtitle: 'Lewat kabel (adb reverse)',
                      onTap: () => _connect(HostEndpoint.usb),
                    ),
                    for (final h in _hosts)
                      _HostTile(
                        host: h,
                        subtitle: '${h.address}:${h.port}',
                        onTap: () => _connect(h),
                      ),
                    if (_hosts.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: _Message(
                          icon: Icons.wifi_find,
                          text: 'Mencari host di Wi-Fi yang sama…',
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (status.state) {
      ConnState.idle => ('Belum tersambung', Colors.grey, Icons.circle_outlined),
      ConnState.connecting => ('Menyambung…', Colors.orange, Icons.sync),
      ConnState.pairing => ('Pairing…', Colors.orange, Icons.vpn_key),
      ConnState.connected => ('Tersambung', Colors.green, Icons.check_circle),
      ConnState.reconnecting => ('Menyambung ulang…', Colors.orange, Icons.sync_problem),
      ConnState.failed => ('Gagal', Colors.red, Icons.error),
    };

    return Card(
      child: ListTile(
        leading: Icon(icon, color: color, size: 32),
        title: Text(label),
        subtitle: Text([
          if (status.host != null) status.host!.name,
          if (status.rttMs != null) '${status.rttMs} ms',
          if (status.error != null) status.error!,
        ].join(' · ')),
      ),
    );
  }
}

class _HostTile extends StatelessWidget {
  const _HostTile({required this.host, required this.subtitle, required this.onTap});

  final HostEndpoint host;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(host.via == HostVia.usb ? Icons.usb : Icons.computer),
        title: Text(host.name),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
