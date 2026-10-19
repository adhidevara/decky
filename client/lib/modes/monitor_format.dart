/// Pemformatan angka dan riwayat untuk mode Monitor.
///
/// Dipisah dari widget supaya bisa diuji: pembulatan satuan dan perilaku
/// buffer riwayat punya banyak kasus tepi yang tidak terlihat dari layar.
library;

import 'dart:math' as math;

/// Ukuran dalam byte, dibulatkan ke satuan yang enak dibaca.
///
/// Memakai kelipatan 1024 dengan label SI pendek, seperti kebiasaan Task
/// Manager — orang membandingkan angka ini dengan yang di sana.
String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble().abs();
  var unit = 0;

  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }

  final sign = bytes < 0 ? '-' : '';
  // Angka besar tidak butuh desimal; angka kecil jadi tidak berguna tanpanya.
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '$sign${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Laju per detik.
String formatRate(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// Persentase tanpa desimal yang menyesatkan.
String formatPercent(num value) => '${value.round()}%';

String formatTemperature(num celsius) => '${celsius.round()}°C';

/// Riwayat nilai dengan panjang tetap, untuk sparkline.
///
/// Nilai terlama dibuang saat penuh. Menyimpan lebih banyak dari yang
/// digambar hanya menghabiskan memori tanpa ada yang melihatnya.
class History {
  History(this.capacity) : assert(capacity > 0);

  final int capacity;
  final List<double> _values = [];

  List<double> get values => List.unmodifiable(_values);
  bool get isEmpty => _values.isEmpty;
  int get length => _values.length;

  void add(double value) {
    _values.add(value);
    if (_values.length > capacity) {
      _values.removeAt(0);
    }
  }

  void clear() => _values.clear();

  /// Nilai terbesar, dipakai sebagai skala sparkline.
  ///
  /// Mengembalikan 0 kalau kosong; pemanggil yang memutuskan skala
  /// minimumnya, karena grafik yang seluruhnya nol tetap harus punya tinggi.
  double get max => _values.isEmpty ? 0 : _values.reduce(math.max);

  double get latest => _values.isEmpty ? 0 : _values.last;
}
