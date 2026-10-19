import 'package:decky_client/modes/monitor_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('format byte', () {
    test('byte mentah tanpa desimal', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('naik satuan pada 1024', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('angka besar tidak memakai desimal', () {
      // 150 MB lebih enak dibaca daripada 150.3 MB; satu desimal di angka
      // sebesar itu hanya menambah derau.
      expect(formatBytes(150 * 1024 * 1024), '150 MB');
      expect(formatBytes(999 * 1024), '999 KB');
    });

    test('berhenti di terabyte', () {
      final huge = 5.0 * 1024 * 1024 * 1024 * 1024 * 1024;
      expect(formatBytes(huge), endsWith('TB'));
    });

    test('nilai negatif tetap terbaca', () {
      expect(formatBytes(-2048), '-2.0 KB');
    });

    test('laju memakai akhiran per detik', () {
      expect(formatRate(1024), '1.0 KB/s');
      expect(formatRate(0), '0 B/s');
    });
  });

  group('format lain', () {
    test('persen dibulatkan', () {
      expect(formatPercent(0), '0%');
      expect(formatPercent(42.4), '42%');
      expect(formatPercent(42.6), '43%');
      expect(formatPercent(100), '100%');
    });

    test('suhu dibulatkan', () {
      expect(formatTemperature(61.4), '61°C');
      expect(formatTemperature(72.8), '73°C');
    });
  });

  group('riwayat', () {
    test('menyimpan nilai sampai kapasitas', () {
      final h = History(3);
      expect(h.isEmpty, isTrue);
      h.add(1);
      h.add(2);
      expect(h.values, [1, 2]);
      expect(h.length, 2);
    });

    test('membuang yang terlama saat penuh', () {
      final h = History(3);
      for (final v in [1.0, 2.0, 3.0, 4.0]) {
        h.add(v);
      }
      expect(h.values, [2, 3, 4], reason: 'nilai pertama harus terdorong keluar');
      expect(h.length, 3);
    });

    test('max dipakai sebagai skala', () {
      final h = History(5);
      h.add(3);
      h.add(9);
      h.add(1);
      expect(h.max, 9);
    });

    test('riwayat kosong tidak membuat pembagian dengan nol', () {
      final h = History(5);
      expect(h.max, 0);
      expect(h.latest, 0);
      expect(h.values, isEmpty);
    });

    test('latest adalah yang terbaru', () {
      final h = History(2);
      h.add(1);
      h.add(2);
      h.add(3);
      expect(h.latest, 3);
    });

    test('clear mengosongkan', () {
      final h = History(3);
      h.add(1);
      h.clear();
      expect(h.isEmpty, isTrue);
      expect(h.latest, 0);
    });
  });
}
