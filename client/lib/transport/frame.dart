/// MessagePack + chunking, pasangan dari `host/src-tauri/src/net/frame.rs`.
///
/// Satu pesan Noise maksimal 65535 byte termasuk tag 16 byte, jadi plaintext
/// efektif 65519 byte. Payload lebih besar dipecah di sini, dengan satu byte
/// flag di depan tiap chunk: 0 = chunk terakhir, 1 = masih ada lanjutan.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

/// Plaintext maksimal per pesan Noise, dikurangi 1 byte flag.
const int maxChunk = 65519 - 1;

/// Batas pesan yang sudah dirakit, supaya host jahat tidak bisa menghabiskan
/// memori HP.
const int maxMessage = 8 * 1024 * 1024;

class FrameException implements Exception {
  FrameException(this.message);
  final String message;
  @override
  String toString() => 'FrameException: $message';
}

/// Encode map jadi MessagePack.
Uint8List encodeMap(Map<String, dynamic> map) => msgpack.serialize(map);

/// Decode MessagePack jadi map berkunci String.
///
/// msgpack_dart mengembalikan `Map<dynamic, dynamic>`; semua kunci di protokol
/// Decky berupa string, jadi langsung di-cast di sini.
Map<String, dynamic> decodeMap(Uint8List bytes) {
  final raw = msgpack.deserialize(bytes);
  if (raw is! Map) {
    throw FrameException('payload bukan map: ${raw.runtimeType}');
  }
  return raw.map((k, v) => MapEntry(k.toString(), _normalize(v)));
}

/// msgpack_dart mengembalikan `Map<dynamic, dynamic>` untuk map bersarang;
/// normalkan supaya `fromMap` hasil codegen bisa memakainya langsung.
dynamic _normalize(dynamic v) {
  if (v is Map) {
    return v.map((k, val) => MapEntry(k.toString(), _normalize(val)));
  }
  if (v is List) {
    return v.map(_normalize).toList();
  }
  return v;
}

/// Bungkus payload jadi envelope protokol.
Uint8List encodeEnvelope(String type, Map<String, dynamic> payload, {int? id}) {
  return encodeMap({
    'v': 1,
    't': type,
    'id': ?id,
    'd': payload,
  });
}

/// Satu envelope yang sudah di-parse.
///
/// Dinamai `Frame` supaya tidak bentrok dengan `Envelope` hasil codegen, yang
/// memetakan `t` ke enum dan karenanya menolak tipe pesan yang belum dikenal.
class Frame {
  Frame({required this.v, required this.type, required this.data, this.id});

  final int v;
  final String type;
  final int? id;
  final Map<String, dynamic> data;

  factory Frame.decode(Uint8List bytes) {
    final m = decodeMap(bytes);
    final t = m['t'];
    if (t is! String) throw FrameException('envelope tanpa field t');
    final d = m['d'];
    return Frame(
      v: m['v'] as int? ?? 1,
      type: t,
      id: m['id'] as int?,
      data: d is Map<String, dynamic> ? d : <String, dynamic>{},
    );
  }
}

/// Pecah payload jadi chunk siap-enkripsi.
List<Uint8List> split(Uint8List payload) {
  if (payload.isEmpty) {
    return [Uint8List.fromList([0])];
  }
  final out = <Uint8List>[];
  for (var offset = 0; offset < payload.length; offset += maxChunk) {
    final end = (offset + maxChunk < payload.length) ? offset + maxChunk : payload.length;
    final isLast = end == payload.length;
    final buf = Uint8List(end - offset + 1);
    buf[0] = isLast ? 0 : 1;
    buf.setRange(1, buf.length, payload, offset);
    out.add(buf);
  }
  return out;
}

/// Merakit chunk yang datang berurutan jadi pesan utuh.
class Reassembler {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  /// Suapkan satu chunk hasil dekripsi.
  ///
  /// Mengembalikan pesan utuh saat chunk terakhir tiba, atau null kalau masih
  /// menunggu lanjutan.
  Uint8List? push(Uint8List chunk) {
    if (chunk.isEmpty) throw FrameException('chunk kosong');
    if (_buf.length + chunk.length - 1 > maxMessage) {
      _buf.clear();
      throw FrameException('pesan melebihi batas $maxMessage byte');
    }
    _buf.add(Uint8List.sublistView(chunk, 1));
    if (chunk[0] == 0) {
      return _buf.takeBytes();
    }
    return null;
  }

  void reset() => _buf.clear();
}

/// Representasi hex, dipakai untuk log debug dan kunci cache.
String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Base64 tanpa padding, untuk id blob yang ringkas.
String b64(Uint8List b) => base64Url.encode(b).replaceAll('=', '');
