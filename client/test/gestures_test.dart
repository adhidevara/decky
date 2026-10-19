
import 'package:decky_client/modes/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gerakkan satu jari beberapa langkah, kembalikan keluaran terakhir.
GestureOutput drag(
  GestureTracker t,
  int id,
  Offset from,
  Offset step, {
  int steps = 1,
}) {
  var position = from;
  var out = GestureOutput.none;
  for (var i = 0; i < steps; i++) {
    position += step;
    out = t.move(id, position, step);
  }
  return out;
}

void main() {
  group('satu jari', () {
    test('menggerakkan kursor', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      final out = t.move(1, const Offset(110, 105), const Offset(10, 5));
      expect(out.move, const Offset(10, 5));
      expect(t.mode, GestureMode.move);
    });

    test('ketukan singkat jadi klik kiri', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      expect(t.up(1).tapButton, 0);
    });

    test('geseran jauh bukan ketukan', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      drag(t, 1, const Offset(100, 100), const Offset(20, 0), steps: 3);
      expect(t.up(1).tapButton, isNull);
    });
  });

  group('dua jari', () {
    void twoFingersDown(GestureTracker t) {
      t.down(1, const Offset(100, 100));
      t.down(2, const Offset(200, 100));
    }

    test('ketukan dua jari jadi klik kanan', () {
      final t = GestureTracker();
      twoFingersDown(t);
      t.up(1);
      expect(t.up(2).tapButton, 2);
    });

    test('ketukan tiga jari jadi klik tengah', () {
      final t = GestureTracker();
      twoFingersDown(t);
      t.down(3, const Offset(300, 100));
      t.up(1);
      t.up(2);
      expect(t.up(3).tapButton, 1);
    });

    test('bergeser bersama jadi scroll', () {
      final t = GestureTracker();
      twoFingersDown(t);

      // Kedua jari turun bersama; jarak antar jari tidak berubah.
      GestureOutput out = GestureOutput.none;
      var a = const Offset(100, 100);
      var b = const Offset(200, 100);
      for (var i = 0; i < 4; i++) {
        const step = Offset(0, 10);
        a += step;
        b += step;
        t.move(1, a, step);
        out = t.move(2, b, step);
      }

      expect(t.mode, GestureMode.scroll);
      expect(out.scroll.dy, greaterThan(0));
      expect(out.zoom, 0);
    });

    test('scroll mengikuti titik tengah, bukan jumlah kedua jari', () {
      final t = GestureTracker();
      twoFingersDown(t);

      var a = const Offset(100, 100);
      var b = const Offset(200, 100);
      const step = Offset(0, 10);

      // Lewati ambang penentuan mode dulu.
      for (var i = 0; i < 3; i++) {
        a += step;
        b += step;
        t.move(1, a, step);
        t.move(2, b, step);
      }
      expect(t.mode, GestureMode.scroll);

      // Event datang per jari, jadi satu langkah penuh adalah jumlah kedua
      // panggilan. Sepuluh piksel oleh kedua jari harus jadi 10, bukan 20.
      a += step;
      final first = t.move(1, a, step);
      b += step;
      final second = t.move(2, b, step);
      expect(first.scroll.dy + second.scroll.dy, closeTo(10, 0.01));
    });

    test('merenggang jadi zoom positif', () {
      final t = GestureTracker();
      twoFingersDown(t);

      var a = const Offset(100, 100);
      var b = const Offset(200, 100);
      GestureOutput out = GestureOutput.none;
      for (var i = 0; i < 4; i++) {
        a += const Offset(-10, 0);
        b += const Offset(10, 0);
        t.move(1, a, const Offset(-10, 0));
        out = t.move(2, b, const Offset(10, 0));
      }

      expect(t.mode, GestureMode.pinch);
      expect(out.zoom, greaterThan(0), reason: 'merenggang harus memperbesar');
      expect(out.scroll, Offset.zero);
    });

    test('merapat jadi zoom negatif', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      t.down(2, const Offset(300, 100));

      var a = const Offset(100, 100);
      var b = const Offset(300, 100);
      GestureOutput out = GestureOutput.none;
      for (var i = 0; i < 4; i++) {
        a += const Offset(10, 0);
        b += const Offset(-10, 0);
        t.move(1, a, const Offset(10, 0));
        out = t.move(2, b, const Offset(-10, 0));
      }

      expect(out.zoom, lessThan(0));
    });

    test('mode terkunci sampai jari diangkat', () {
      final t = GestureTracker();
      twoFingersDown(t);

      // Mulai jelas sebagai pinch.
      var a = const Offset(100, 100);
      var b = const Offset(200, 100);
      for (var i = 0; i < 4; i++) {
        a += const Offset(-10, 0);
        b += const Offset(10, 0);
        t.move(1, a, const Offset(-10, 0));
        t.move(2, b, const Offset(10, 0));
      }
      expect(t.mode, GestureMode.pinch);

      // Lalu geser bersama. Mode tidak boleh berubah di tengah gestur.
      for (var i = 0; i < 5; i++) {
        const step = Offset(0, 12);
        a += step;
        b += step;
        t.move(1, a, step);
        t.move(2, b, step);
      }
      expect(t.mode, GestureMode.pinch, reason: 'mode tidak boleh bolak-balik');
    });

    test('gerakan kecil belum memutuskan mode', () {
      final t = GestureTracker();
      twoFingersDown(t);
      final out = t.move(1, const Offset(102, 100), const Offset(2, 0));
      expect(t.mode, GestureMode.undecided);
      expect(out.isEmpty, isTrue);
    });
  });

  group('pemulihan keadaan', () {
    test('cancel melepaskan jari, bukan menyangkutkannya', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      t.down(2, const Offset(200, 100));
      expect(t.fingers, 2);

      // Inilah event yang dulu tidak ditangani: penghitung jari tersangkut di
      // dua, dan setiap gerakan satu jari sesudahnya dianggap scroll selamanya.
      t.up(1, cancelled: true);
      t.up(2, cancelled: true);
      expect(t.fingers, 0);
      expect(t.mode, GestureMode.idle);

      t.down(3, const Offset(100, 100));
      final out = t.move(3, const Offset(120, 100), const Offset(20, 0));
      expect(t.mode, GestureMode.move);
      expect(out.move, const Offset(20, 0), reason: 'harus menggerakkan kursor lagi');
      expect(out.scroll, Offset.zero);
    });

    test('gestur yang dibatalkan tidak jadi ketukan', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      expect(t.up(1, cancelled: true).tapButton, isNull);
    });

    test('event untuk jari tak dikenal diabaikan', () {
      final t = GestureTracker();
      expect(t.move(99, const Offset(10, 10), const Offset(5, 5)).isEmpty, isTrue);
      expect(t.up(99).isEmpty, isTrue);
    });

    test('mengangkat satu jari dari scroll tidak membuat kursor meloncat', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      t.down(2, const Offset(200, 100));

      var a = const Offset(100, 100);
      var b = const Offset(200, 100);
      for (var i = 0; i < 4; i++) {
        const step = Offset(0, 10);
        a += step;
        b += step;
        t.move(1, a, step);
        t.move(2, b, step);
      }
      expect(t.mode, GestureMode.scroll);

      t.up(2);
      final out = t.move(1, a + const Offset(0, 10), const Offset(0, 10));
      expect(out.move, Offset.zero, reason: 'jari sisa tidak boleh langsung menggerakkan kursor');
    });

    test('clear mengosongkan semuanya', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      t.down(2, const Offset(200, 100));
      t.clear();
      expect(t.fingers, 0);
      expect(t.mode, GestureMode.idle);
    });
  });

  group('seret', () {
    test('tekan-tahan memulai dan mengakhiri seret', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      expect(t.longPress().dragStart, isTrue);
      expect(t.mode, GestureMode.drag);

      final moved = t.move(1, const Offset(150, 100), const Offset(50, 0));
      expect(moved.move, const Offset(50, 0), reason: 'seret tetap menggerakkan kursor');

      final out = t.up(1);
      expect(out.dragEnd, isTrue);
      expect(out.tapButton, isNull, reason: 'akhir seret bukan ketukan');
    });

    test('tekan-tahan dengan dua jari diabaikan', () {
      final t = GestureTracker();
      t.down(1, const Offset(100, 100));
      t.down(2, const Offset(200, 100));
      expect(t.longPress().dragStart, isFalse);
    });
  });
}
