/// Cache ikon dan artwork yang dialamatkan oleh isinya.
///
/// `blob_id` adalah hash isi berkas, jadi isinya tidak pernah berubah untuk id
/// yang sama. Itu membuat cache ini aman disimpan selamanya — tidak perlu
/// kedaluwarsa, tidak perlu validasi ulang.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class CachedBlob {
  const CachedBlob(this.mime, this.bytes);
  final String mime;
  final Uint8List bytes;

  bool get isSvg => mime == 'image/svg+xml';
}

class BlobCache {
  final Map<String, CachedBlob> _memory = {};
  final Set<String> _requested = {};
  Directory? _dir;

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/blobs');
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  CachedBlob? peek(String blobId) => _memory[blobId];

  /// Muat dari disk ke memori kalau ada. Mengembalikan null kalau belum pernah
  /// di-cache, yang berarti pemanggil perlu memintanya ke host.
  Future<CachedBlob?> load(String blobId) async {
    final cached = _memory[blobId];
    if (cached != null) return cached;

    try {
      final dir = await _directory();
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.startsWith('$blobId.')) continue;

        final mime = _mimeForExtension(name.split('.').last);
        if (mime == null) continue;

        final blob = CachedBlob(mime, await entry.readAsBytes());
        _memory[blobId] = blob;
        return blob;
      }
    } on FileSystemException {
      // Cache rusak atau tidak bisa dibaca bukan alasan untuk gagal; ikon
      // akan diminta ulang ke host.
    }
    return null;
  }

  Future<void> store(String blobId, String mime, Uint8List bytes) async {
    _memory[blobId] = CachedBlob(mime, bytes);
    _requested.remove(blobId);

    final ext = _extensionForMime(mime);
    if (ext == null) return;
    try {
      final dir = await _directory();
      await File('${dir.path}/$blobId.$ext').writeAsBytes(bytes);
    } on FileSystemException {
      // Gagal menulis ke disk hanya berarti ikon diminta ulang sesi depan.
    }
  }

  /// Tandai bahwa blob ini sudah diminta, supaya satu layout dengan banyak
  /// tombol tidak mengirim permintaan yang sama berkali-kali.
  bool markRequested(String blobId) => _requested.add(blobId);

  String? _mimeForExtension(String ext) => switch (ext) {
        'png' => 'image/png',
        'jpg' => 'image/jpeg',
        'webp' => 'image/webp',
        'svg' => 'image/svg+xml',
        _ => null,
      };

  String? _extensionForMime(String mime) => switch (mime) {
        'image/png' => 'png',
        'image/jpeg' => 'jpg',
        'image/webp' => 'webp',
        'image/svg+xml' => 'svg',
        _ => null,
      };
}
