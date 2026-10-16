/// Identitas client dan penyimpanan token sesi.
///
/// `client_id` adalah UUID yang dibuat sekali lalu dipakai selamanya — host
/// memakainya untuk mencocokkan device dengan tokennya. Token itu sendiri
/// disimpan di Android Keystore lewat `flutter_secure_storage`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

// flutter_secure_storage 11 selalu memakai EncryptedSharedPreferences di
// Android, jadi tidak ada lagi opsi yang perlu diset.
const _storage = FlutterSecureStorage();

const _kClientId = 'decky.client_id';
String _tokenKey(String hostId) => 'decky.token.$hostId';

class Identity {
  Identity({required this.clientId, required this.deviceName});

  final String clientId;
  final String deviceName;

  /// Muat identitas, membuatnya kalau ini peluncuran pertama.
  static Future<Identity> load() async {
    var id = await _storage.read(key: _kClientId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _storage.write(key: _kClientId, value: id);
    }
    return Identity(clientId: id, deviceName: await _deviceName());
  }

  static Future<String> _deviceName() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      // "Pixel 7" lebih berguna di layar host daripada nama model mentah.
      final name = '${info.manufacturer} ${info.model}'.trim();
      return name.isEmpty ? 'Android' : name;
    } catch (_) {
      // Emulator atau platform lain: nama generik lebih baik daripada gagal.
      return 'Android';
    }
  }
}

/// Token sesi per host.
class TokenStore {
  /// Token untuk host tertentu, atau null kalau belum pernah dipasangkan.
  static Future<Uint8List?> load(String hostId) async {
    final raw = await _storage.read(key: _tokenKey(hostId));
    if (raw == null) return null;
    final bytes = base64Decode(raw);
    if (bytes.length != 32) {
      // Entri rusak: buang dan perlakukan seperti belum dipasangkan, supaya
      // user bisa pairing ulang alih-alih mentok di layar error.
      await delete(hostId);
      return null;
    }
    return Uint8List.fromList(bytes);
  }

  static Future<void> save(String hostId, Uint8List token) =>
      _storage.write(key: _tokenKey(hostId), value: base64Encode(token));

  static Future<void> delete(String hostId) => _storage.delete(key: _tokenKey(hostId));
}
