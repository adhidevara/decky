/// Penemuan host lewat mDNS, dengan jalur USB didahulukan.
library;

import 'dart:async';

import 'package:nsd/nsd.dart' as nsd;

import '../protocol/proto_gen.dart' show defaultPort;

const String serviceType = '_decky._tcp';

/// Host yang bisa disambungi.
class HostEndpoint {
  const HostEndpoint({
    required this.hostId,
    required this.name,
    required this.address,
    required this.port,
    required this.via,
  });

  final String hostId;
  final String name;
  final String address;
  final int port;
  final HostVia via;

  /// Endpoint USB lewat `adb reverse`, yang selalu dicoba lebih dulu.
  static const HostEndpoint usb = HostEndpoint(
    hostId: '',
    name: 'USB',
    address: '127.0.0.1',
    port: defaultPort,
    via: HostVia.usb,
  );

  String get wsUrl => 'ws://$address:$port/ws';

  @override
  bool operator ==(Object other) =>
      other is HostEndpoint && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);
}

enum HostVia { usb, wifi, manual }

/// Mencari host Decky di jaringan lokal.
///
/// USB tidak muncul lewat mDNS — `adb reverse` memetakan port host ke
/// localhost HP — jadi pemanggil mencoba [HostEndpoint.usb] duluan dan
/// memakai hasil pencarian ini sebagai cadangan.
class Discovery {
  nsd.Discovery? _discovery;
  final _controller = StreamController<List<HostEndpoint>>.broadcast();
  final Map<String, HostEndpoint> _found = {};

  Stream<List<HostEndpoint>> get hosts => _controller.stream;

  Future<void> start() async {
    if (_discovery != null) return;
    final d = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.v4);
    _discovery = d;
    d.addServiceListener((service, status) {
      final endpoint = _toEndpoint(service);
      if (endpoint == null) return;
      if (status == nsd.ServiceStatus.found) {
        _found[endpoint.hostId] = endpoint;
      } else {
        _found.remove(endpoint.hostId);
      }
      _controller.add(_found.values.toList());
    });
  }

  Future<void> stop() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) await nsd.stopDiscovery(d);
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  HostEndpoint? _toEndpoint(nsd.Service s) {
    final addr = s.addresses?.firstOrNull?.address;
    final port = s.port;
    if (addr == null || port == null) return null;

    final txt = s.txt ?? const {};
    String? text(String key) {
      final v = txt[key];
      return v == null ? null : String.fromCharCodes(v);
    }

    // Tanpa host id kita tidak bisa mencocokkan token tersimpan, jadi entri
    // seperti itu tidak berguna.
    final id = text('id');
    if (id == null || id.isEmpty) return null;

    return HostEndpoint(
      hostId: id,
      name: text('name') ?? s.name ?? 'Decky Host',
      address: addr,
      port: port,
      via: HostVia.wifi,
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
