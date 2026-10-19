/// Mesin keadaan gestur trackpad.
///
/// Dipisah dari widget supaya bisa diuji tanpa menjalankan Flutter: logika
/// inilah yang menentukan apakah trackpad terasa benar, dan satu-satunya cara
/// memastikannya tetap benar adalah mengujinya langsung.
///
/// Jari dilacak lewat **id**, bukan dihitung jumlahnya. Android mengirim
/// `PointerCancel` — palm rejection, gestur sistem, recognizer yang merebut
/// pointer — dan penghitung angka tidak pernah pulih dari event yang terlewat:
/// ia tersangkut di dua dan setiap gerakan satu jari sesudahnya diperlakukan
/// sebagai scroll selamanya.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Jarak maksimal yang masih dianggap ketukan, bukan geseran.
const double tapSlop = 12;

/// Durasi maksimal sebuah ketukan.
const Duration tapTimeout = Duration(milliseconds: 250);

/// Seberapa jauh dua jari harus bergerak sebelum gestur diputuskan sebagai
/// scroll atau pinch. Di bawah ini keduanya belum bisa dibedakan.
const double _modeThreshold = 16;

enum GestureMode {
  /// Belum ada jari menyentuh.
  idle,

  /// Satu jari: menggerakkan kursor.
  move,

  /// Dua jari, belum jelas mau scroll atau pinch.
  undecided,

  /// Dua jari bergeser bersama.
  scroll,

  /// Dua jari merenggang atau merapat.
  pinch,

  /// Tombol kiri ditahan dan jari masih menyeret.
  drag,
}

/// Apa yang harus dikirim ke host setelah sebuah event sentuhan.
class GestureOutput {
  const GestureOutput({
    this.move = Offset.zero,
    this.scroll = Offset.zero,
    this.zoom = 0,
    this.tapButton,
    this.dragStart = false,
    this.dragEnd = false,
  });

  /// Gerakan kursor, dalam piksel sentuhan.
  final Offset move;

  /// Geseran scroll, dalam piksel sentuhan.
  final Offset scroll;

  /// Perubahan jarak antar jari; positif berarti merenggang (perbesar).
  final double zoom;

  /// 0 kiri, 1 tengah, 2 kanan. Null berarti tidak ada ketukan.
  final int? tapButton;

  final bool dragStart;
  final bool dragEnd;

  bool get isEmpty =>
      move == Offset.zero &&
      scroll == Offset.zero &&
      zoom == 0 &&
      tapButton == null &&
      !dragStart &&
      !dragEnd;

  static const none = GestureOutput();
}

class GestureTracker {
  final Map<int, Offset> _points = {};

  GestureMode _mode = GestureMode.idle;
  int _maxFingers = 0;
  double _travel = 0;
  DateTime? _startedAt;

  /// Jarak dan titik tengah antar dua jari pada event sebelumnya.
  double _lastSpan = 0;
  Offset _lastCentroid = Offset.zero;

  /// Berapa jauh gestur dua jari sudah bergeser dan merenggang, dipakai untuk
  /// memutuskan scroll atau pinch.
  double _spanTravel = 0;
  double _centroidTravel = 0;

  GestureMode get mode => _mode;
  int get fingers => _points.length;

  void down(int id, Offset position) {
    if (_points.isEmpty) {
      _travel = 0;
      _startedAt = DateTime.now();
      _maxFingers = 0;
    }
    _points[id] = position;
    _maxFingers = math.max(_maxFingers, _points.length);

    if (_points.length == 2) {
      // Gestur dua jari dimulai dari nol: jarak dan titik tengah saat ini
      // jadi acuan, bukan sisa dari gestur sebelumnya.
      _lastSpan = _span();
      _lastCentroid = _centroid();
      _spanTravel = 0;
      _centroidTravel = 0;
      _mode = GestureMode.undecided;
    } else if (_points.length == 1 && _mode != GestureMode.drag) {
      _mode = GestureMode.move;
    } else if (_points.length > 2) {
      // Tiga jari atau lebih tidak punya arti selain ketukan tombol tengah.
      _mode = GestureMode.undecided;
    }
  }

  GestureOutput move(int id, Offset position, Offset delta) {
    if (!_points.containsKey(id)) {
      // Event untuk jari yang tidak kita kenal: bisa terjadi setelah cancel.
      // Diabaikan daripada merusak keadaan.
      return GestureOutput.none;
    }
    _points[id] = position;
    _travel += delta.distance;

    if (_points.length == 1) {
      // Mode ikut menentukan, bukan hanya jumlah jari: jari sisa dari gestur
      // dua jari berstatus undecided dan sengaja tidak menggerakkan apa pun.
      final movesCursor = _mode == GestureMode.move || _mode == GestureMode.drag;
      return movesCursor ? GestureOutput(move: delta) : GestureOutput.none;
    }
    if (_points.length != 2) {
      return GestureOutput.none;
    }

    final span = _span();
    final centroid = _centroid();
    final spanDelta = span - _lastSpan;
    final centroidDelta = centroid - _lastCentroid;
    _lastSpan = span;
    _lastCentroid = centroid;

    if (_mode == GestureMode.undecided) {
      _spanTravel += spanDelta.abs();
      _centroidTravel += centroidDelta.distance;

      if (_spanTravel < _modeThreshold && _centroidTravel < _modeThreshold) {
        return GestureOutput.none;
      }
      // Yang lebih dominan menang, lalu dikunci sampai jari diangkat. Tanpa
      // penguncian, gestur yang sedikit miring akan bolak-balik antara scroll
      // dan zoom di tengah jalan.
      _mode = _spanTravel > _centroidTravel ? GestureMode.pinch : GestureMode.scroll;
    }

    return switch (_mode) {
      // Scroll mengikuti titik tengah, bukan jumlah kedua jari — kalau
      // dijumlahkan, kecepatannya jadi dua kali lipat gerakan sebenarnya.
      GestureMode.scroll => GestureOutput(scroll: centroidDelta),
      GestureMode.pinch => GestureOutput(zoom: spanDelta),
      _ => GestureOutput.none,
    };
  }

  /// Jari diangkat atau dibatalkan sistem.
  ///
  /// `cancelled` membedakan keduanya: gestur yang dibatalkan tidak boleh
  /// berubah jadi ketukan, karena user tidak bermaksud mengetuk apa pun.
  GestureOutput up(int id, {bool cancelled = false}) {
    if (_points.remove(id) == null) return GestureOutput.none;

    if (_points.isNotEmpty) {
      // Masih ada jari di layar. Sisa gestur dimulai ulang dari keadaan
      // sekarang supaya tidak ada lompatan saat satu jari diangkat.
      if (_points.length == 2) {
        _lastSpan = _span();
        _lastCentroid = _centroid();
      } else if (_points.length == 1 && _mode != GestureMode.drag) {
        // Jangan langsung menggerakkan kursor dengan jari sisa: itu membuat
        // mengangkat satu jari dari scroll terasa seperti kursor meloncat.
        _mode = GestureMode.undecided;
      }
      return GestureOutput.none;
    }

    final wasDragging = _mode == GestureMode.drag;
    final fingers = _maxFingers;
    final travel = _travel;
    final held = DateTime.now().difference(_startedAt ?? DateTime.now());
    _reset();

    if (wasDragging) {
      return const GestureOutput(dragEnd: true);
    }
    if (cancelled || travel >= tapSlop || held >= tapTimeout) {
      return GestureOutput.none;
    }

    // Satu jari klik kiri, dua jari klik kanan, tiga jari klik tengah —
    // kebiasaan yang sama dengan trackpad laptop.
    final button = switch (fingers) {
      1 => 0,
      2 => 2,
      3 => 1,
      _ => null,
    };
    return button == null ? GestureOutput.none : GestureOutput(tapButton: button);
  }

  /// Tekan-tahan: mulai menyeret dengan tombol kiri ditahan.
  GestureOutput longPress() {
    if (_points.length != 1 || _mode == GestureMode.drag) {
      return GestureOutput.none;
    }
    _mode = GestureMode.drag;
    return const GestureOutput(dragStart: true);
  }

  /// Lupakan semua jari. Dipanggil saat layar ditinggalkan atau koneksi putus.
  void clear() => _reset();

  void _reset() {
    _points.clear();
    _mode = GestureMode.idle;
    _maxFingers = 0;
    _travel = 0;
    _startedAt = null;
    _lastSpan = 0;
    _lastCentroid = Offset.zero;
    _spanTravel = 0;
    _centroidTravel = 0;
  }

  double _span() {
    if (_points.length < 2) return 0;
    final points = _points.values.toList();
    return (points[0] - points[1]).distance;
  }

  Offset _centroid() {
    if (_points.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final p in _points.values) {
      sum += p;
    }
    return sum / _points.length.toDouble();
  }
}
