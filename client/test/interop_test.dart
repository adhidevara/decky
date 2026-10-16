/// Uji interop: client Dart melawan host Rust sungguhan.
///
/// Test ini menjalankan `cargo run --example interop_host`, lalu melakukan
/// pairing penuh — Hello, Noise NNpsk0, Welcome, ping/pong. Unit test di kedua
/// bahasa tidak bisa menangkap ketidakcocokan handshake; hanya test inilah
/// yang membuktikan keduanya benar-benar bicara protokol yang sama.
///
/// Lewati dengan: `flutter test --exclude-tags interop`
@Tags(['interop'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:decky_client/protocol/proto_gen.dart';
import 'package:decky_client/transport/frame.dart';
import 'package:decky_client/transport/noise.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

const String _clientId = 'interop-test-client';
const String _pin = '314159';
const int _port = 8799;

void main() {
  late Process host;
  late String hostId;

  setUpAll(() async {
    host = await Process.start(
      'cargo',
      [
        'run',
        '--quiet',
        '--example',
        'interop_host',
        '--',
        '--pin', _pin,
        '--port', '$_port',
        '--reset-client', _clientId,
      ],
      workingDirectory: '../host/src-tauri',
      environment: {
        'PATH': '${Platform.environment['USERPROFILE']}\\.cargo\\bin;'
            '${Platform.environment['PATH']}',
      },
    );

    host.stderr.transform(utf8.decoder).listen((l) => stderr.write('[host] $l'));

    final ready = Completer<void>();
    host.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('HOST_ID=')) hostId = line.substring(8).trim();
      if (line.trim() == 'READY' && !ready.isCompleted) ready.complete();
    });

    await ready.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () => throw StateError('host interop tidak pernah siap'),
    );
  });

  tearDownAll(() => host.kill());

  test('pairing lengkap lalu ping/pong', () async {
    final ws = IOWebSocketChannel.connect('ws://127.0.0.1:$_port/ws');
    final inbox = StreamQueue<Uint8List>(
      ws.stream.map((e) => Uint8List.fromList(e as List<int>)),
    );

    // 1. Hello plaintext.
    ws.sink.add(encodeMap(const Hello(
      v: 1,
      mode: HelloMode.pair,
      clientId: _clientId,
      name: 'Dart Interop',
      platform: HelloPlatform.android,
      appVersion: '0.1.0',
    ).toMap()));

    final ack = HelloAck.fromMap(decodeMap(await inbox.next));
    expect(ack.ok, isTrue, reason: 'host menolak hello: ${ack.code}');
    expect(ack.noise, noiseProtocolName);

    // 2. Handshake Noise NNpsk0 dengan PSK turunan PIN.
    final psk = await pskFromPin(_pin, hostId, _clientId);
    final hs = await NoiseHandshake.initiator(psk);
    ws.sink.add(await hs.writeMessage1());
    final chan = await hs.readMessage2(await inbox.next);

    // 3. Welcome terenkripsi, berisi token sesi.
    final welcomeFrame = Reassembler().push(await chan.open(await inbox.next));
    expect(welcomeFrame, isNotNull, reason: 'welcome harusnya muat satu chunk');
    final envelope = Frame.decode(welcomeFrame!);
    expect(envelope.type, MsgType.welcome);

    final welcome = Welcome.fromMap(envelope.data);
    expect(welcome.proto, 1);
    expect(welcome.hostId, hostId);
    expect(welcome.token, isNotNull, reason: 'mode pair harus menerbitkan token');
    expect(welcome.token!.length, 32);

    // 4. Ping harus dibalas pong dengan ts yang sama persis.
    const ts = 1234567;
    ws.sink.add(await chan.seal(
      split(encodeEnvelope(MsgType.ping, const Ping(ts: ts).toMap())).single,
    ));

    final pongFrame = Reassembler().push(await chan.open(await inbox.next));
    final pong = Frame.decode(pongFrame!);
    expect(pong.type, MsgType.pong);
    expect(Ping.fromMap(pong.data).ts, ts);

    await ws.sink.close();
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// Antrean kecil untuk membaca stream satu pesan demi satu.
///
/// `package:async` punya StreamQueue, tapi menambah dependensi hanya untuk
/// test rasanya berlebihan.
class StreamQueue<T> {
  StreamQueue(Stream<T> source) {
    _sub = source.listen(
      (event) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(event);
        } else {
          _buffered.add(event);
        }
      },
      onError: (Object e) {
        for (final c in _waiting) {
          c.completeError(e);
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<T> _sub;
  final List<T> _buffered = [];
  final List<Completer<T>> _waiting = [];

  Future<T> get next {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    final c = Completer<T>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 15));
  }

  Future<void> cancel() => _sub.cancel();
}
