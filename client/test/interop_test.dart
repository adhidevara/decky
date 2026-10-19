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

    expect(welcome.caps, contains(Capability.deck));

    Future<Frame> nextFrame() async {
      final bytes = Reassembler().push(await chan.open(await inbox.next));
      return Frame.decode(bytes!);
    }

    Future<void> send(String type, Map<String, dynamic> payload) async {
      ws.sink.add(await chan.seal(split(encodeEnvelope(type, payload)).single));
    }

    // 4. Deck dikirim otomatis setelah welcome: daftar profil, lalu layout.
    final profilesFrame = await nextFrame();
    expect(profilesFrame.type, MsgType.deckProfiles);
    final profiles = DeckProfiles.fromMap(profilesFrame.data);
    expect(profiles.profiles, isNotEmpty);

    final layoutFrame = await nextFrame();
    expect(layoutFrame.type, MsgType.deckLayout);
    final layout = DeckLayout.fromMap(layoutFrame.data);
    expect(layout.profileId, profiles.active);
    expect(layout.buttons, isNotEmpty);
    expect(layout.buttons.every((b) => b.idx < layout.cols * layout.rows), isTrue);

    // 5. Menekan tombol yang tidak ada harus ditolak, bukan didiamkan.
    //
    // Sengaja memilih indeks kosong: menekan tombol asli akan benar-benar
    // menjalankan aksinya di mesin yang menjalankan test ini.
    await send(MsgType.deckPress, const DeckPress(idx: 9999).toMap());
    final errFrame = await nextFrame();
    expect(errFrame.type, MsgType.error);
    expect(ErrorMsg.fromMap(errFrame.data).code, ErrorCode.unknownAction);

    // 6. Ikon yang tidak ada harus ditolak, bukan membuat host diam.
    await send(MsgType.wantBlob, WantBlob(blobId: '0' * 32).toMap());
    final blobErr = await nextFrame();
    expect(blobErr.type, MsgType.error);
    expect(ErrorMsg.fromMap(blobErr.data).code, ErrorCode.unknownAction);

    // 7. Ping harus dibalas pong dengan ts yang sama persis.
    const ts = 1234567;
    await send(MsgType.ping, const Ping(ts: ts).toMap());
    final pong = await nextFrame();
    expect(pong.type, MsgType.pong);
    expect(Ping.fromMap(pong.data).ts, ts);

    // 8. Beberapa pesan sekaligus, tanpa menunggu satu per satu.
    //
    // Counter nonce Noise maju satu per pesan, jadi enkripsi yang saling
    // menyela akan memakai nonce yang sama dua kali dan merusak sisa koneksi.
    // Dijalankan lewat Future.wait supaya benar-benar bersamaan.
    const batch = [11, 22, 33, 44, 55];
    await Future.wait([
      for (final t in batch) send(MsgType.ping, Ping(ts: t).toMap()),
    ]);

    final echoed = <int>[];
    for (var i = 0; i < batch.length; i++) {
      final frame = await nextFrame();
      expect(frame.type, MsgType.pong);
      echoed.add(Ping.fromMap(frame.data).ts);
    }
    expect(echoed, batch, reason: 'pong harus kembali utuh dan berurutan');

    // 9. Pesan input diterima tanpa balasan error.
    //
    // Gerakan dan scroll sengaja nol: host akan benar-benar menggerakkan
    // kursor mesin yang menjalankan test ini kalau nilainya bukan nol.
    expect(welcome.caps, contains(Capability.input));
    await send(MsgType.pointerMove, const PointerMove(e: [[0, 0]], dt: 16).toMap());
    await send(MsgType.scroll, const Scroll(dx: 0, dy: 0).toMap());

    // Ping susulan: kalau salah satu pesan di atas memicu error, frame
    // berikutnya adalah error itu, bukan pong.
    await send(MsgType.ping, const Ping(ts: 777).toMap());
    final afterInput = await nextFrame();
    expect(
      afterInput.type,
      MsgType.pong,
      reason: 'pesan input tidak boleh menghasilkan error',
    );
    expect(Ping.fromMap(afterInput.data).ts, 777);

    // 10. Berlangganan monitor harus menghasilkan cuplikan berisi angka nyata.
    expect(welcome.caps, contains(Capability.monitor));
    await send(
      MsgType.monitorSub,
      const MonitorSub(
        intervalMs: 200,
        want: [MonitorSubWantItem.cpu, MonitorSubWantItem.mem],
      ).toMap(),
    );

    final tickFrame = await nextFrame();
    expect(tickFrame.type, MsgType.monitorTick);
    final tick = MonitorTick.fromMap(tickFrame.data);
    expect(tick.ts, greaterThan(0));
    expect(tick.cpu, inInclusiveRange(0, 100));
    expect(tick.memTotal, greaterThan(0), reason: 'total memori harus terbaca');
    expect(tick.memUsed, lessThanOrEqualTo(tick.memTotal));
    // Yang tidak diminta tidak boleh ikut diambil.
    expect(tick.netRx, 0);
    expect(tick.diskR, 0);

    // Cuplikan kedua membuktikan ia benar-benar berulang, bukan sekali kirim.
    final second = await nextFrame();
    expect(second.type, MsgType.monitorTick);
    expect(MonitorTick.fromMap(second.data).ts, greaterThanOrEqualTo(tick.ts));

    await send(MsgType.monitorUnsub, const MonitorUnsub().toMap());

    // 11. Tombol keyboard yang tidak dikenal harus ditolak dengan jelas.
    await send(
      MsgType.key,
      const KeyEvent(code: 'BukanTombol', down: true, mods: 0).toMap(),
    );
    final keyErr = await nextFrame();
    expect(keyErr.type, MsgType.error);
    expect(ErrorMsg.fromMap(keyErr.data).code, ErrorCode.actionFailed);

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
