import 'package:decky_client/modes/keyboard_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('modifier lengket', () {
    test('awalnya semua mati', () {
      final bank = ModifierBank();
      expect(bank.mask, 0);
      for (final m in Modifier.values) {
        expect(bank.isActive(m), isFalse);
      }
    });

    test('siklus mati, sekali pakai, terkunci, mati', () {
      final bank = ModifierBank();
      expect(bank.stateOf(Modifier.ctrl), ModState.off);
      bank.tap(Modifier.ctrl);
      expect(bank.stateOf(Modifier.ctrl), ModState.latched);
      bank.tap(Modifier.ctrl);
      expect(bank.stateOf(Modifier.ctrl), ModState.locked);
      bank.tap(Modifier.ctrl);
      expect(bank.stateOf(Modifier.ctrl), ModState.off);
    });

    test('mask menggabungkan beberapa modifier', () {
      final bank = ModifierBank();
      bank.tap(Modifier.ctrl);
      bank.tap(Modifier.shift);
      // Ctrl 2 + Shift 1.
      expect(bank.mask, 3);

      bank.tap(Modifier.alt);
      expect(bank.mask, 7);
      bank.tap(Modifier.meta);
      expect(bank.mask, 15);
    });

    test('sekali pakai dilepas setelah tombol ditekan', () {
      final bank = ModifierBank();
      bank.tap(Modifier.ctrl);
      expect(bank.mask, 2);

      bank.consume();
      expect(bank.mask, 0, reason: 'Ctrl+C tidak boleh membuat tombol berikutnya ikut Ctrl');
    });

    test('yang terkunci bertahan setelah tombol ditekan', () {
      final bank = ModifierBank();
      bank.tap(Modifier.shift);
      bank.tap(Modifier.shift); // terkunci
      bank.consume();
      expect(bank.stateOf(Modifier.shift), ModState.locked);
      expect(bank.mask, 1, reason: 'mengunci Shift gunanya untuk mengetik beberapa huruf besar');
    });

    test('terkunci dan sekali pakai bisa bercampur', () {
      final bank = ModifierBank();
      bank.tap(Modifier.ctrl);
      bank.tap(Modifier.ctrl); // Ctrl terkunci
      bank.tap(Modifier.shift); // Shift sekali pakai
      expect(bank.mask, 3);

      bank.consume();
      expect(bank.mask, 2, reason: 'hanya Shift yang dilepas');
    });

    test('clear mematikan semuanya', () {
      final bank = ModifierBank();
      bank.tap(Modifier.ctrl);
      bank.tap(Modifier.ctrl);
      bank.tap(Modifier.alt);
      bank.clear();
      expect(bank.mask, 0);
    });

    test('bitmask sesuai protokol', () {
      expect(Modifier.shift.mask, 1);
      expect(Modifier.ctrl.mask, 2);
      expect(Modifier.alt.mask, 4);
      expect(Modifier.meta.mask, 8);
    });
  });

  group('label tombol', () {
    test('huruf mengikuti shift', () {
      const a = KeyCap('KeyA', 'a');
      expect(a.labelFor(shift: false), 'a');
      expect(a.labelFor(shift: true), 'A');
    });

    test('angka memakai simbol shift-nya', () {
      const one = KeyCap('Digit1', '1', shifted: '!');
      expect(one.labelFor(shift: false), '1');
      expect(one.labelFor(shift: true), '!');
    });

    test('tombol bernama tidak berubah', () {
      const tab = KeyCap('Tab', 'Tab');
      expect(tab.labelFor(shift: true), 'Tab');
    });
  });

  group('layout', () {
    test('setiap tombol punya kode', () {
      for (final row in [...functionRow, ...mainRows]) {
        for (final key in row) {
          expect(key.code, isNotEmpty, reason: 'tombol "${key.label}" tanpa kode');
          expect(key.width, greaterThan(0));
        }
      }
    });

    test('kode memakai nama W3C, bukan karakternya', () {
      final codes = [
        for (final row in mainRows)
          for (final key in row) key.code,
      ];
      expect(codes, contains('KeyA'));
      expect(codes, contains('Digit1'));
      expect(codes, contains('Semicolon'));
      expect(
        codes,
        isNot(contains('a')),
        reason: 'kode adalah posisi fisik tombol, bukan huruf yang dihasilkan',
      );
    });

    test('alfabet lengkap ada', () {
      final codes = {
        for (final row in mainRows)
          for (final key in row) key.code,
      };
      for (final letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
        expect(codes, contains('Key$letter'), reason: 'huruf $letter hilang');
      }
      for (var digit = 0; digit <= 9; digit++) {
        expect(codes, contains('Digit$digit'));
      }
    });

    test('hanya tombol modifier yang menandai dirinya modifier', () {
      for (final row in mainRows) {
        for (final key in row) {
          if (key.isModifier) {
            expect(
              key.code,
              anyOf('ShiftLeft', 'ControlLeft', 'AltLeft', 'MetaLeft'),
            );
          }
        }
      }
    });

    test('keempat modifier tersedia di layout', () {
      final modifiers = {
        for (final row in mainRows)
          for (final key in row)
            if (key.modifier != null) key.modifier!,
      };
      expect(modifiers, Modifier.values.toSet());
    });
  });

  group('kombinasi siap pakai', () {
    test('semuanya memakai modifier', () {
      for (final combo in commonCombos) {
        expect(combo.mods, greaterThan(0), reason: '${combo.label} tanpa modifier');
        expect(combo.code, isNotEmpty);
      }
    });

    test('copy dan paste memakai Ctrl', () {
      final copy = commonCombos.firstWhere((c) => c.label == 'Copy');
      expect(copy.code, 'KeyC');
      expect(copy.mods, Modifier.ctrl.mask);
    });

    test('task manager memakai Ctrl dan Shift', () {
      final combo = commonCombos.firstWhere((c) => c.label.contains('Esc'));
      expect(combo.mods, Modifier.ctrl.mask | Modifier.shift.mask);
    });
  });
}
