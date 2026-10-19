/// Layout keyboard virtual dan keadaan modifier lengket.
///
/// Dipisah dari widget supaya bisa diuji: modifier lengket punya banyak
/// keadaan yang mudah salah, dan satu-satunya cara memastikannya benar adalah
/// mengujinya langsung.
library;

/// Modifier beserta bitmask-nya di protokol.
enum Modifier {
  shift(1, 'Shift', 'ShiftLeft'),
  ctrl(2, 'Ctrl', 'ControlLeft'),
  alt(4, 'Alt', 'AltLeft'),
  meta(8, 'Win', 'MetaLeft');

  const Modifier(this.mask, this.label, this.code);

  final int mask;
  final String label;

  /// Nama W3C tombolnya, kalau perlu dikirim sebagai tombol biasa.
  final String code;
}

/// Keadaan satu modifier.
///
/// Pola yang sama dengan sticky keys di sistem operasi: sekali tekan berlaku
/// untuk satu tombol berikutnya, dua kali tekan mengunci sampai dilepas
/// sendiri. Tanpa penguncian, kombinasi seperti Ctrl+Shift+T mustahil
/// dilakukan dengan satu tangan di layar sentuh.
enum ModState { off, latched, locked }

class ModifierBank {
  final Map<Modifier, ModState> _states = {
    for (final m in Modifier.values) m: ModState.off,
  };

  ModState stateOf(Modifier m) => _states[m] ?? ModState.off;

  bool isActive(Modifier m) => stateOf(m) != ModState.off;

  /// Bitmask untuk dikirim bersama tombol berikutnya.
  int get mask => Modifier.values
      .where(isActive)
      .fold(0, (acc, m) => acc | m.mask);

  /// Siklus: mati → sekali pakai → terkunci → mati.
  void tap(Modifier m) {
    _states[m] = switch (stateOf(m)) {
      ModState.off => ModState.latched,
      ModState.latched => ModState.locked,
      ModState.locked => ModState.off,
    };
  }

  /// Dipanggil setelah tombol biasa ditekan.
  ///
  /// Hanya yang sekali pakai yang dilepas; yang terkunci sengaja bertahan,
  /// karena itulah gunanya dikunci.
  void consume() {
    for (final m in Modifier.values) {
      if (stateOf(m) == ModState.latched) {
        _states[m] = ModState.off;
      }
    }
  }

  void clear() {
    for (final m in Modifier.values) {
      _states[m] = ModState.off;
    }
  }
}

/// Tombol yang mengubah keyboard itu sendiri, bukan mengirim apa pun ke host.
///
/// Fn di keyboard sungguhan pun tidak pernah sampai ke sistem operasi — ia
/// ditangani firmware keyboard. Jadi memperlakukannya sebagai tombol lokal
/// bukan penyederhanaan, itu memang perilakunya.
enum KeyAction { toggleFunctionRow }

/// Satu tombol di layout.
class KeyCap {
  const KeyCap(
    this.code,
    this.label, {
    this.shifted,
    this.width = 1,
    this.modifier,
    this.action,
  });

  /// Nama `KeyboardEvent.code` menurut W3C — netral terhadap layout fisik.
  final String code;

  /// Label saat tidak ada Shift.
  final String label;

  /// Label saat Shift aktif. Null berarti sama saja.
  final String? shifted;

  /// Lebar relatif terhadap tombol huruf.
  final double width;

  /// Terisi kalau tombol ini mengubah modifier, bukan mengirim tombol.
  final Modifier? modifier;

  /// Terisi kalau tombol ini hanya mengubah keyboard di sisi client.
  final KeyAction? action;

  bool get isModifier => modifier != null;

  /// Apakah menekan tombol ini mengirim sesuatu ke host?
  bool get sendsKey => modifier == null && action == null;

  /// Label yang ditampilkan untuk keadaan Shift tertentu.
  String labelFor({required bool shift}) {
    if (!shift) return label;
    if (shifted != null) return shifted!;
    // Huruf tidak perlu daftar terpisah; besar-kecilnya mengikuti Shift.
    return label.length == 1 ? label.toUpperCase() : label;
  }
}

/// Baris tombol fungsi, dimunculkan oleh tombol Fn.
///
/// Escape tidak ada di sini: ia terlalu sering dipakai untuk disembunyikan di
/// balik pengalih, jadi tempatnya di baris utama. Sisanya — F1–F12 dan
/// navigasi dokumen — jarang dipakai dan memakan tinggi layar yang lebih
/// berguna untuk baris huruf.
const List<List<KeyCap>> functionRow = [
  [
    KeyCap('F1', 'F1'),
    KeyCap('F2', 'F2'),
    KeyCap('F3', 'F3'),
    KeyCap('F4', 'F4'),
    KeyCap('F5', 'F5'),
    KeyCap('F6', 'F6'),
    KeyCap('F7', 'F7'),
    KeyCap('F8', 'F8'),
    KeyCap('F9', 'F9'),
    KeyCap('F10', 'F10'),
    KeyCap('F11', 'F11'),
    KeyCap('F12', 'F12'),
    KeyCap('Insert', 'Ins'),
    KeyCap('Home', 'Home'),
    KeyCap('End', 'End'),
    KeyCap('PageUp', 'PgUp'),
    KeyCap('PageDown', 'PgDn'),
  ],
];

/// Layout QWERTY. Kode mengikuti posisi fisik, jadi host bisa menerjemahkannya
/// ke layout apa pun yang sedang aktif di PC.
const List<List<KeyCap>> mainRows = [
  [
    // Esc selalu terlihat: menutup dialog dan membatalkan adalah dua hal yang
    // paling sering dibutuhkan, dan keduanya mendesak saat dibutuhkan.
    KeyCap('Escape', 'Esc', width: 1.3),
    KeyCap('Backquote', '`', shifted: '~'),
    KeyCap('Digit1', '1', shifted: '!'),
    KeyCap('Digit2', '2', shifted: '@'),
    KeyCap('Digit3', '3', shifted: '#'),
    KeyCap('Digit4', '4', shifted: r'$'),
    KeyCap('Digit5', '5', shifted: '%'),
    KeyCap('Digit6', '6', shifted: '^'),
    KeyCap('Digit7', '7', shifted: '&'),
    KeyCap('Digit8', '8', shifted: '*'),
    KeyCap('Digit9', '9', shifted: '('),
    KeyCap('Digit0', '0', shifted: ')'),
    KeyCap('Minus', '-', shifted: '_'),
    KeyCap('Equal', '=', shifted: '+'),
    KeyCap('Backspace', '⌫', width: 2),
  ],
  [
    KeyCap('Tab', 'Tab', width: 1.5),
    KeyCap('KeyQ', 'q'),
    KeyCap('KeyW', 'w'),
    KeyCap('KeyE', 'e'),
    KeyCap('KeyR', 'r'),
    KeyCap('KeyT', 't'),
    KeyCap('KeyY', 'y'),
    KeyCap('KeyU', 'u'),
    KeyCap('KeyI', 'i'),
    KeyCap('KeyO', 'o'),
    KeyCap('KeyP', 'p'),
    KeyCap('BracketLeft', '[', shifted: '{'),
    KeyCap('BracketRight', ']', shifted: '}'),
    KeyCap('Backslash', r'\', shifted: '|', width: 1.5),
  ],
  [
    KeyCap('CapsLock', 'Caps', width: 1.8),
    KeyCap('KeyA', 'a'),
    KeyCap('KeyS', 's'),
    KeyCap('KeyD', 'd'),
    KeyCap('KeyF', 'f'),
    KeyCap('KeyG', 'g'),
    KeyCap('KeyH', 'h'),
    KeyCap('KeyJ', 'j'),
    KeyCap('KeyK', 'k'),
    KeyCap('KeyL', 'l'),
    KeyCap('Semicolon', ';', shifted: ':'),
    KeyCap('Quote', "'", shifted: '"'),
    KeyCap('Enter', '⏎', width: 2.2),
  ],
  [
    KeyCap('ShiftLeft', 'Shift', width: 2.4, modifier: Modifier.shift),
    KeyCap('KeyZ', 'z'),
    KeyCap('KeyX', 'x'),
    KeyCap('KeyC', 'c'),
    KeyCap('KeyV', 'v'),
    KeyCap('KeyB', 'b'),
    KeyCap('KeyN', 'n'),
    KeyCap('KeyM', 'm'),
    KeyCap('Comma', ',', shifted: '<'),
    KeyCap('Period', '.', shifted: '>'),
    KeyCap('Slash', '/', shifted: '?'),
    KeyCap('ArrowUp', '↑'),
    KeyCap('Delete', 'Del', width: 1.4),
  ],
  [
    KeyCap('Fn', 'Fn', width: 1.3, action: KeyAction.toggleFunctionRow),
    KeyCap('ControlLeft', 'Ctrl', width: 1.6, modifier: Modifier.ctrl),
    KeyCap('MetaLeft', 'Win', width: 1.4, modifier: Modifier.meta),
    KeyCap('AltLeft', 'Alt', width: 1.4, modifier: Modifier.alt),
    KeyCap('Space', '', width: 6),
    KeyCap('ArrowLeft', '←'),
    KeyCap('ArrowDown', '↓'),
    KeyCap('ArrowRight', '→'),
  ],
];

/// Kombinasi yang sering dipakai, supaya tidak perlu menekan modifier dulu.
class Combo {
  const Combo(this.label, this.code, this.mods);

  final String label;
  final String code;
  final int mods;
}

const List<Combo> commonCombos = [
  Combo('Copy', 'KeyC', 2),
  Combo('Paste', 'KeyV', 2),
  Combo('Cut', 'KeyX', 2),
  Combo('Undo', 'KeyZ', 2),
  Combo('Redo', 'KeyY', 2),
  Combo('Save', 'KeyS', 2),
  Combo('All', 'KeyA', 2),
  Combo('Find', 'KeyF', 2),
  // Alt+Tab dan Win+D tidak bisa dibuat dari modifier lengket dengan nyaman,
  // karena keduanya mengganti jendela aktif di tengah gestur.
  Combo('Alt+Tab', 'Tab', 4),
  Combo('Win+D', 'KeyD', 8),
  Combo('Ctrl+Shift+Esc', 'Escape', 3),
];
