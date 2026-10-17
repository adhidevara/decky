/// Implementasi Noise `NNpsk0_25519_ChaChaPoly_SHA256`.
///
/// Dart belum punya paket Noise yang terawat, jadi pola ini ditulis langsung
/// dari spesifikasi Noise revisi 34. Hanya NNpsk0 yang diimplementasikan —
/// tanpa static key, tanpa pola lain — supaya permukaannya kecil dan bisa
/// dibaca ulang saat audit.
///
/// Pola:
///
/// ```text
/// NNpsk0:
///   -> psk, e
///   <- e, ee
/// ```
///
/// Catatan penting dari spec: dalam mode PSK, token `e` juga memanggil
/// `MixKey(e.public_key)`, bukan hanya `MixHash`. Melewatkan ini membuat
/// handshake gagal melawan implementasi lain.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String noiseProtocolName = 'Noise_NNpsk0_25519_ChaChaPoly_SHA256';
const int hashLen = 32;
const int dhLen = 32;
const int tagLen = 16;

final _sha256 = Sha256();
final _hmac = Hmac.sha256();
final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();

class NoiseException implements Exception {
  NoiseException(this.message);
  final String message;
  @override
  String toString() => 'NoiseException: $message';
}

// ── primitif ────────────────────────────────────────────────────────────────

Future<Uint8List> _hash(List<int> data) async =>
    Uint8List.fromList((await _sha256.hash(data)).bytes);

Future<Uint8List> _hmacSha256(List<int> key, List<int> data) async {
  final mac = await _hmac.calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

/// HKDF versi Noise: sampai tiga keluaran 32 byte dari satu chaining key.
Future<List<Uint8List>> _hkdf(List<int> ck, List<int> ikm, int outputs) async {
  final tempKey = await _hmacSha256(ck, ikm);
  final o1 = await _hmacSha256(tempKey, [0x01]);
  if (outputs == 1) return [o1];
  final o2 = await _hmacSha256(tempKey, [...o1, 0x02]);
  if (outputs == 2) return [o1, o2];
  final o3 = await _hmacSha256(tempKey, [...o2, 0x03]);
  return [o1, o2, o3];
}

/// Nonce ChaChaPoly ala Noise: 32 bit nol lalu counter 64 bit little-endian.
Uint8List _nonce(int n) {
  final b = Uint8List(12);
  final view = ByteData.view(b.buffer);
  view.setUint64(4, n, Endian.little);
  return b;
}

// ── CipherState ─────────────────────────────────────────────────────────────

class _CipherState {
  _CipherState(this._key);

  final Uint8List _key;
  int _n = 0;

  Future<Uint8List> encrypt(List<int> ad, List<int> plaintext) async {
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(_key),
      nonce: _nonce(_n),
      aad: ad,
    );
    _n++;
    // Di kawat, tag menempel langsung setelah ciphertext.
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> decrypt(List<int> ad, Uint8List ciphertext) async {
    if (ciphertext.length < tagLen) {
      throw NoiseException('ciphertext terlalu pendek: ${ciphertext.length} byte');
    }
    final split = ciphertext.length - tagLen;
    final box = SecretBox(
      Uint8List.sublistView(ciphertext, 0, split),
      nonce: _nonce(_n),
      mac: Mac(Uint8List.sublistView(ciphertext, split)),
    );
    final plain = await _aead.decrypt(box, secretKey: SecretKey(_key), aad: ad);
    _n++;
    return Uint8List.fromList(plain);
  }
}

// ── SymmetricState ──────────────────────────────────────────────────────────

class _SymmetricState {
  _SymmetricState._(this._ck, this._h);

  Uint8List _ck;
  Uint8List _h;
  _CipherState? _cipher;

  static Future<_SymmetricState> initialize(String protocolName) async {
    final name = Uint8List.fromList(protocolName.codeUnits);
    // Spec: nama <= HASHLEN dipakai apa adanya lalu di-pad nol, selebihnya di-hash.
    final h = name.length <= hashLen
        ? (Uint8List(hashLen)..setRange(0, name.length, name))
        : await _hash(name);
    return _SymmetricState._(Uint8List.fromList(h), h);
  }

  Future<void> mixKey(List<int> ikm) async {
    final out = await _hkdf(_ck, ikm, 2);
    _ck = out[0];
    _cipher = _CipherState(out[1]);
  }

  Future<void> mixHash(List<int> data) async {
    _h = await _hash([..._h, ...data]);
  }

  Future<void> mixKeyAndHash(List<int> ikm) async {
    final out = await _hkdf(_ck, ikm, 3);
    _ck = out[0];
    await mixHash(out[1]);
    _cipher = _CipherState(out[2]);
  }

  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    final c = _cipher;
    // Sebelum MixKey pertama belum ada kunci; payload lewat apa adanya.
    final out = c == null
        ? Uint8List.fromList(plaintext)
        : await c.encrypt(_h, plaintext);
    await mixHash(out);
    return out;
  }

  Future<Uint8List> decryptAndHash(Uint8List ciphertext) async {
    final c = _cipher;
    final out = c == null
        ? Uint8List.fromList(ciphertext)
        : await c.decrypt(_h, ciphertext);
    await mixHash(ciphertext);
    return out;
  }

  Future<List<_CipherState>> split() async {
    final out = await _hkdf(_ck, const <int>[], 2);
    return [_CipherState(out[0]), _CipherState(out[1])];
  }
}

// ── HandshakeState ──────────────────────────────────────────────────────────

/// Sisi initiator dari NNpsk0. Host adalah responder.
class NoiseHandshake {
  NoiseHandshake._(this._sym, this._psk);

  final _SymmetricState _sym;
  final Uint8List _psk;
  SimpleKeyPair? _e;
  bool _msg1Sent = false;

  /// Siapkan handshake dengan PSK 32 byte.
  static Future<NoiseHandshake> initiator(Uint8List psk) async {
    if (psk.length != 32) {
      throw NoiseException('PSK harus 32 byte, dapat ${psk.length}');
    }
    final sym = await _SymmetricState.initialize(noiseProtocolName);
    // Prologue kosong: MixHash("") tetap dipanggil demi kesesuaian spec.
    await sym.mixHash(const <int>[]);
    return NoiseHandshake._(sym, psk);
  }

  /// Pesan pertama: `-> psk, e`.
  Future<Uint8List> writeMessage1({List<int> payload = const []}) async {
    if (_msg1Sent) throw NoiseException('pesan 1 sudah dikirim');
    await _sym.mixKeyAndHash(_psk);

    final e = await _x25519.newKeyPair();
    final pub = Uint8List.fromList((await e.extractPublicKey()).bytes);
    _e = e;

    await _sym.mixHash(pub);
    // Khusus mode PSK: kunci ephemeral ikut masuk chaining key.
    await _sym.mixKey(pub);

    final enc = await _sym.encryptAndHash(payload);
    _msg1Sent = true;
    return Uint8List.fromList([...pub, ...enc]);
  }

  /// Pesan kedua dari host: `<- e, ee`. Mengembalikan channel yang siap pakai.
  Future<NoiseChannel> readMessage2(Uint8List message) async {
    if (!_msg1Sent) throw NoiseException('pesan 1 belum dikirim');
    if (message.length < dhLen) {
      throw NoiseException('pesan 2 terlalu pendek: ${message.length} byte');
    }

    final re = Uint8List.sublistView(message, 0, dhLen);
    await _sym.mixHash(re);
    await _sym.mixKey(re);

    final shared = await _x25519.sharedSecretKey(
      keyPair: _e!,
      remotePublicKey: SimplePublicKey(re, type: KeyPairType.x25519),
    );
    await _sym.mixKey(await shared.extractBytes());

    await _sym.decryptAndHash(Uint8List.sublistView(message, dhLen));

    final states = await _sym.split();
    // Initiator mengirim dengan cipher pertama, menerima dengan yang kedua.
    return NoiseChannel._(states[0], states[1]);
  }
}

/// Channel terenkripsi setelah handshake selesai.
///
/// Setiap arah punya counter nonce yang maju satu per pesan, jadi operasi
/// harus berurutan. Operasinya `async`, dan di Dart dua callback stream bisa
/// saling menyela di titik `await` — kalau itu terjadi, kedua panggilan
/// membaca counter yang sama dan sisa koneksi gagal MAC selamanya.
///
/// Urutan dijaga di sini, bukan di pemanggil: itu sifat cipher-nya, dan
/// pemanggil tidak punya alasan untuk tahu.
class NoiseChannel {
  NoiseChannel._(this._send, this._recv);

  final _CipherState _send;
  final _CipherState _recv;

  Future<void> _sendLock = Future.value();
  Future<void> _recvLock = Future.value();

  /// Enkripsi satu chunk (pemecahan payload ada di `frame.dart`).
  Future<Uint8List> seal(List<int> plaintext) {
    final result = _sendLock.then((_) => _send.encrypt(const [], plaintext));
    // Kegagalan tidak boleh mengunci antrean; pemanggil tetap menerima error
    // lewat `result`.
    _sendLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Dekripsi satu pesan Noise.
  ///
  /// Pesan harus disuapkan sesuai urutan datangnya dari socket.
  Future<Uint8List> open(Uint8List ciphertext) {
    final result = _recvLock.then((_) => _recv.decrypt(const [], ciphertext));
    _recvLock = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// PSK mode pairing: HKDF-SHA256 atas PIN, di-salt dengan kedua id.
///
/// Harus identik dengan `psk_from_pin` di host, kalau tidak handshake gagal.
Future<Uint8List> pskFromPin(String pin, String hostId, String clientId) async {
  final salt = Uint8List.fromList([...hostId.codeUnits, ...clientId.codeUnits]);
  final hkdf = Hkdf(hmac: _hmac, outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(Uint8List.fromList(pin.codeUnits)),
    nonce: salt,
    info: Uint8List.fromList('decky-pair-v1'.codeUnits),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// PSK mode sesi: token dipakai apa adanya.
Uint8List pskFromToken(Uint8List token) {
  if (token.length != 32) {
    throw NoiseException('token harus 32 byte, dapat ${token.length}');
  }
  return token;
}
