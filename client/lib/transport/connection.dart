/// Koneksi ke host: handshake, keepalive, reconnect.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/proto_gen.dart';
import 'discovery.dart';
import 'frame.dart';
import 'identity.dart';
import 'noise.dart';

enum ConnState { idle, connecting, pairing, connected, reconnecting, failed }

class ConnectionStatus {
  const ConnectionStatus(this.state, {this.host, this.error, this.rttMs});

  final ConnState state;
  final HostEndpoint? host;
  final String? error;
  final int? rttMs;

  bool get isLive => state == ConnState.connected;
}

/// Satu koneksi ke satu host.
///
/// Dipakai sebagai `ChangeNotifier` supaya UI bisa ikut tanpa perlu state
/// management tambahan.
class DeckyConnection extends ChangeNotifier {
  DeckyConnection(this._identity);

  final Identity _identity;

  WebSocketChannel? _ws;
  NoiseChannel? _chan;
  final Reassembler _reasm = Reassembler();
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  HostEndpoint? _host;
  int _attempt = 0;
  bool _disposed = false;

  ConnectionStatus _status = const ConnectionStatus(ConnState.idle);
  ConnectionStatus get status => _status;

  Welcome? _welcome;
  Welcome? get welcome => _welcome;

  /// Pesan dari host, setelah didekripsi dan dirakit.
  final _messages = StreamController<Frame>.broadcast();
  Stream<Frame> get messages => _messages.stream;

  bool supports(Capability cap) => _welcome?.caps.contains(cap) ?? false;

  void _setStatus(ConnectionStatus s) {
    if (_disposed) return;
    _status = s;
    notifyListeners();
  }

  /// Sambungkan memakai token tersimpan. PIN hanya dipakai saat pairing.
  Future<void> connect(HostEndpoint host, {String? pin}) async {
    await _teardown();
    _host = host;
    _attempt = 0;
    await _attemptConnect(host, pin: pin);
  }

  Future<void> _attemptConnect(HostEndpoint host, {String? pin}) async {
    final pairing = pin != null;
    _setStatus(ConnectionStatus(
      pairing ? ConnState.pairing : ConnState.connecting,
      host: host,
    ));

    try {
      final ws = IOWebSocketChannel.connect(
        Uri.parse(host.wsUrl),
        connectTimeout: const Duration(seconds: 6),
      );
      _ws = ws;

      // Handshake perlu membaca balasan satu per satu, jadi stream dipasang
      // ke antrean dulu; setelah selesai, barulah dialihkan ke loop pesan.
      final inbox = _Inbox(ws.stream);

      final hello = Hello(
        v: protocolVersion,
        mode: pairing ? HelloMode.pair : HelloMode.session,
        clientId: _identity.clientId,
        name: _identity.deviceName,
        platform: HelloPlatform.android,
      );
      ws.sink.add(encodeMap(hello.toMap()));

      final ack = HelloAck.fromMap(decodeMap(await inbox.next));
      if (!ack.ok) {
        throw DeckyError(ack.code ?? ErrorCode.internal);
      }

      final psk = pairing
          ? await pskFromPin(pin, host.hostId, _identity.clientId)
          : pskFromToken(await _requireToken(host.hostId));

      final hs = await NoiseHandshake.initiator(psk);
      ws.sink.add(await hs.writeMessage1());
      final chan = await hs.readMessage2(await inbox.next);
      _chan = chan;

      // Pesan pertama yang terenkripsi selalu Welcome.
      final welcomeFrame = await _readFrame(inbox, chan);
      if (welcomeFrame.type != MsgType.welcome) {
        throw StateError('pesan pertama bukan welcome: ${welcomeFrame.type}');
      }
      final welcome = Welcome.fromMap(welcomeFrame.data);
      _welcome = welcome;

      if (welcome.token != null) {
        await TokenStore.save(welcome.hostId, welcome.token!);
      }

      _attempt = 0;
      _setStatus(ConnectionStatus(ConnState.connected, host: host));
      _startMessageLoop(inbox, chan);
      _startPing();
    } catch (e) {
      await _teardown();
      final fatal = e is DeckyError && e.fatal;
      _setStatus(ConnectionStatus(
        fatal ? ConnState.failed : ConnState.reconnecting,
        host: host,
        error: e.toString(),
      ));
      // Pairing tidak pernah diulang otomatis: PIN sekali pakai, dan mencoba
      // lagi hanya akan membakar jatah rate limit host.
      if (!fatal && !pairing) _scheduleReconnect();
    }
  }

  Future<Uint8List> _requireToken(String hostId) async {
    final token = await TokenStore.load(hostId);
    if (token == null) throw DeckyError(ErrorCode.authFailed);
    return token;
  }

  Future<Frame> _readFrame(_Inbox inbox, NoiseChannel chan) async {
    while (true) {
      final plain = _reasm.push(await chan.open(await inbox.next));
      if (plain != null) return Frame.decode(plain);
    }
  }

  void _startMessageLoop(_Inbox inbox, NoiseChannel chan) {
    _sub = inbox.rest.listen(
      (raw) async {
        try {
          final plain = _reasm.push(await chan.open(Uint8List.fromList(raw as List<int>)));
          if (plain == null) return;
          final frame = Frame.decode(plain);
          if (frame.type == MsgType.ping) {
            // Host memeriksa apakah kita masih hidup; balas apa adanya.
            await send(MsgType.pong, Ping.fromMap(frame.data).toMap());
            return;
          }
          _messages.add(frame);
        } catch (e) {
          debugPrint('frame rusak: $e');
        }
      },
      onDone: _onDropped,
      onError: (Object e) => _onDropped(),
    );
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      final sentAt = DateTime.now().millisecondsSinceEpoch;
      await send(MsgType.ping, Ping(ts: sentAt).toMap());
    });

    // RTT diukur dari pong yang kembali, bukan dari timer di atas.
    messages.where((f) => f.type == MsgType.pong).listen((f) {
      final sent = Ping.fromMap(f.data).ts;
      final rtt = DateTime.now().millisecondsSinceEpoch - sent;
      if (rtt >= 0 && _status.isLive) {
        _setStatus(ConnectionStatus(ConnState.connected, host: _host, rttMs: rtt));
      }
    });
  }

  /// Kirim satu pesan ke host.
  Future<void> send(String type, Map<String, dynamic> payload) async {
    final chan = _chan;
    final ws = _ws;
    if (chan == null || ws == null) return;
    for (final chunk in split(encodeEnvelope(type, payload))) {
      ws.sink.add(await chan.seal(chunk));
    }
  }

  void _onDropped() {
    if (_disposed) return;
    _setStatus(ConnectionStatus(ConnState.reconnecting, host: _host));
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final host = _host;
    if (host == null || _disposed) return;
    _reconnectTimer?.cancel();

    // Backoff eksponensial dibatasi 30 detik: cukup cepat saat Wi-Fi hanya
    // kedip, cukup lambat untuk tidak menguras baterai saat host mati.
    final delay = Duration(
      milliseconds: (500 * (1 << _attempt.clamp(0, 6))).clamp(500, 30000),
    );
    _attempt++;
    _reconnectTimer = Timer(delay, () => _attemptConnect(host));
  }

  Future<void> _teardown() async {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    await _ws?.sink.close();
    _ws = null;
    _chan = null;
    _reasm.reset();
  }

  /// Putuskan dan jangan coba sambung lagi.
  Future<void> disconnect() async {
    _host = null;
    await _teardown();
    _setStatus(const ConnectionStatus(ConnState.idle));
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    _messages.close();
    super.dispose();
  }
}

class DeckyError implements Exception {
  DeckyError(this.code);
  final ErrorCode code;

  /// Error yang tidak akan hilang dengan mencoba lagi.
  bool get fatal =>
      code == ErrorCode.authFailed ||
      code == ErrorCode.protoVersion ||
      code == ErrorCode.pairExpired ||
      code == ErrorCode.pairThrottled;

  @override
  String toString() => switch (code) {
        ErrorCode.authFailed => 'Device belum dipasangkan — lakukan pairing ulang',
        ErrorCode.protoVersion => 'Versi host dan client tidak cocok',
        ErrorCode.pairExpired => 'PIN kedaluwarsa — minta PIN baru di host',
        ErrorCode.pairThrottled => 'Terlalu banyak percobaan — tunggu sebentar',
        _ => 'Host menolak koneksi (${code.wire})',
      };
}

/// Membaca stream satu pesan demi satu selama handshake, lalu menyerahkan
/// sisanya ke loop pesan.
class _Inbox {
  _Inbox(Stream<dynamic> source) {
    _sub = source.listen(
      (event) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(Uint8List.fromList(event as List<int>));
        } else {
          _buffered.add(event);
        }
      },
      onError: _fail,
      onDone: () => _fail(StateError('koneksi ditutup host')),
    );
  }

  late final StreamSubscription<dynamic> _sub;
  final List<dynamic> _buffered = [];
  final List<Completer<Uint8List>> _waiting = [];
  final StreamController<dynamic> _rest = StreamController<dynamic>();

  void _fail(Object e, [StackTrace? _]) {
    for (final c in _waiting) {
      if (!c.isCompleted) c.completeError(e);
    }
    _waiting.clear();
    if (!_rest.isClosed) _rest.addError(e);
  }

  Future<Uint8List> get next {
    if (_buffered.isNotEmpty) {
      return Future.value(Uint8List.fromList(_buffered.removeAt(0) as List<int>));
    }
    final c = Completer<Uint8List>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 10));
  }

  /// Sisa stream setelah handshake selesai.
  Stream<dynamic> get rest {
    _sub.onData((event) {
      if (!_rest.isClosed) _rest.add(event);
    });
    _sub.onDone(() => _rest.close());
    for (final buffered in _buffered) {
      _rest.add(buffered);
    }
    _buffered.clear();
    return _rest.stream;
  }
}
