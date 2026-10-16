import 'dart:typed_data';

import 'package:decky_client/protocol/proto_gen.dart';
import 'package:decky_client/transport/frame.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List roundtrip(Uint8List payload) {
  final r = Reassembler();
  Uint8List? out;
  for (final chunk in split(payload)) {
    expect(out, isNull, reason: 'chunk muncul setelah pesan selesai');
    out = r.push(chunk);
  }
  expect(out, isNotNull, reason: 'pesan tidak pernah selesai');
  return out!;
}

void main() {
  group('chunking', () {
    test('chunk tunggal bolak-balik', () {
      final payload = Uint8List.fromList('halo decky'.codeUnits);
      expect(roundtrip(payload), payload);
    });

    test('payload kosong tetap satu chunk', () {
      expect(split(Uint8List(0)).length, 1);
      expect(roundtrip(Uint8List(0)), isEmpty);
    });

    test('payload besar dipecah lalu dirakit lagi', () {
      final payload = Uint8List.fromList(List.generate(250000, (i) => i % 251));
      final chunks = split(payload);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.length <= maxChunk + 1), isTrue);
      expect(roundtrip(payload), payload);
    });

    test('batas chunk persis tidak menambah chunk kosong', () {
      final payload = Uint8List(maxChunk)..fillRange(0, maxChunk, 7);
      expect(split(payload).length, 1);
      expect(roundtrip(payload), payload);
    });

    test('chunk kosong ditolak', () {
      expect(() => Reassembler().push(Uint8List(0)), throwsA(isA<FrameException>()));
    });
  });

  group('messagepack', () {
    test('map bolak-balik dengan kunci string', () {
      final bytes = encodeMap({'ts': 42, 'nama': 'decky'});
      final back = decodeMap(bytes);
      expect(back['ts'], 42);
      expect(back['nama'], 'decky');
    });

    test('map bersarang dinormalkan jadi Map<String, dynamic>', () {
      final bytes = encodeMap({
        'd': {'gpu': {'name': 'RTX', 'temp': 61.5}},
      });
      final back = decodeMap(bytes);
      final d = back['d'] as Map<String, dynamic>;
      final gpu = d['gpu'] as Map<String, dynamic>;
      expect(gpu['name'], 'RTX');
      expect(gpu['temp'], 61.5);
    });

    test('envelope membawa v, t, dan d', () {
      final f = Frame.decode(encodeEnvelope(MsgType.ping, const Ping(ts: 9).toMap()));
      expect(f.v, 1);
      expect(f.type, 'ping');
      expect(Ping.fromMap(f.data).ts, 9);
    });

    test('envelope tanpa t ditolak', () {
      expect(
        () => Frame.decode(encodeMap({'v': 1, 'd': <String, dynamic>{}})),
        throwsA(isA<FrameException>()),
      );
    });
  });

  group('tipe hasil codegen', () {
    test('enum dipetakan ke nilai kawat', () {
      expect(HelloMode.pair.wire, 'pair');
      expect(Capability.monitorCpuTemp.wire, 'monitor.cpu_temp');
      expect(BlobMime.imageSvgXml.wire, 'image/svg+xml');
      expect(Capability.fromWire('monitor.gpu'), Capability.monitorGpu);
    });

    test('field opsional hilang dari map, bukan jadi null', () {
      final m = const Hello(v: 1, mode: HelloMode.session, clientId: 'c1').toMap();
      expect(m.containsKey('name'), isFalse);
      expect(m['client_id'], 'c1');
      expect(m['mode'], 'session');
    });

    test('pointer_move memakai delta berpasangan', () {
      final m = const PointerMove(e: [[3, -4], [0, 1]], dt: 16).toMap();
      final back = PointerMove.fromMap(decodeMap(encodeMap(m)));
      expect(back.e, [[3, -4], [0, 1]]);
      expect(back.dt, 16);
    });
  });
}
