//! Pemetaan nama `KeyboardEvent.code` (W3C) ke virtual-key Windows.
//!
//! Protokol memakai nama W3C supaya netral platform: `KeyA` menunjuk tombol
//! yang sama secara fisik di layout QWERTY maupun AZERTY, sementara "A" tidak.
//! Host-lah yang menerjemahkan ke VK, bukan client.

use windows::Win32::UI::Input::KeyboardAndMouse::*;

/// Terjemahkan satu nama kode W3C ke virtual-key Windows.
///
/// Mengembalikan `None` untuk nama yang tidak dikenal — pemanggil melaporkan
/// itu sebagai `action_failed`, bukan menebak tombol lain.
pub fn vk_from_code(code: &str) -> Option<VIRTUAL_KEY> {
    // Huruf dan angka mengikuti pola tetap, jadi ditangani lebih dulu.
    if let Some(c) = code.strip_prefix("Key") {
        let mut chars = c.chars();
        if let (Some(ch), None) = (chars.next(), chars.next()) {
            if ch.is_ascii_uppercase() {
                return Some(VIRTUAL_KEY(ch as u16));
            }
        }
        return None;
    }
    if let Some(d) = code.strip_prefix("Digit") {
        let mut chars = d.chars();
        if let (Some(ch), None) = (chars.next(), chars.next()) {
            if ch.is_ascii_digit() {
                return Some(VIRTUAL_KEY(ch as u16));
            }
        }
        return None;
    }
    if let Some(n) = code.strip_prefix("Numpad") {
        if let Ok(d) = n.parse::<u8>() {
            if d <= 9 {
                return Some(VIRTUAL_KEY(VK_NUMPAD0.0 + d as u16));
            }
        }
    }
    if let Some(f) = code.strip_prefix('F') {
        if let Ok(n) = f.parse::<u8>() {
            if (1..=24).contains(&n) {
                return Some(VIRTUAL_KEY(VK_F1.0 + n as u16 - 1));
            }
        }
    }

    let vk = match code {
        // Modifier. Kiri dan kanan dibedakan; nama polos dipetakan ke kiri.
        "ControlLeft" | "Control" => VK_LCONTROL,
        "ControlRight" => VK_RCONTROL,
        "ShiftLeft" | "Shift" => VK_LSHIFT,
        "ShiftRight" => VK_RSHIFT,
        "AltLeft" | "Alt" => VK_LMENU,
        "AltRight" => VK_RMENU,
        "MetaLeft" | "Meta" | "Super" => VK_LWIN,
        "MetaRight" => VK_RWIN,

        // Kontrol dan navigasi.
        "Enter" | "NumpadEnter" => VK_RETURN,
        "Escape" => VK_ESCAPE,
        "Backspace" => VK_BACK,
        "Tab" => VK_TAB,
        "Space" => VK_SPACE,
        "CapsLock" => VK_CAPITAL,
        "Delete" => VK_DELETE,
        "Insert" => VK_INSERT,
        "Home" => VK_HOME,
        "End" => VK_END,
        "PageUp" => VK_PRIOR,
        "PageDown" => VK_NEXT,
        "ArrowUp" => VK_UP,
        "ArrowDown" => VK_DOWN,
        "ArrowLeft" => VK_LEFT,
        "ArrowRight" => VK_RIGHT,
        "PrintScreen" => VK_SNAPSHOT,
        "ScrollLock" => VK_SCROLL,
        "Pause" => VK_PAUSE,
        "ContextMenu" => VK_APPS,
        "NumLock" => VK_NUMLOCK,

        // Tanda baca, memakai posisi fisik QWERTY seperti definisi W3C.
        "Minus" => VK_OEM_MINUS,
        "Equal" => VK_OEM_PLUS,
        "BracketLeft" => VK_OEM_4,
        "BracketRight" => VK_OEM_6,
        "Backslash" => VK_OEM_5,
        "Semicolon" => VK_OEM_1,
        "Quote" => VK_OEM_7,
        "Backquote" => VK_OEM_3,
        "Comma" => VK_OEM_COMMA,
        "Period" => VK_OEM_PERIOD,
        "Slash" => VK_OEM_2,
        "IntlBackslash" => VK_OEM_102,

        // Numpad non-digit.
        "NumpadAdd" => VK_ADD,
        "NumpadSubtract" => VK_SUBTRACT,
        "NumpadMultiply" => VK_MULTIPLY,
        "NumpadDivide" => VK_DIVIDE,
        "NumpadDecimal" => VK_DECIMAL,

        // Tombol media, tersedia lewat VK meski keyboard fisik tidak punya.
        "MediaPlayPause" => VK_MEDIA_PLAY_PAUSE,
        "MediaTrackNext" => VK_MEDIA_NEXT_TRACK,
        "MediaTrackPrevious" => VK_MEDIA_PREV_TRACK,
        "MediaStop" => VK_MEDIA_STOP,
        "AudioVolumeUp" => VK_VOLUME_UP,
        "AudioVolumeDown" => VK_VOLUME_DOWN,
        "AudioVolumeMute" => VK_VOLUME_MUTE,

        _ => return None,
    };
    Some(vk)
}

/// Apakah VK ini perlu flag extended-key di `SendInput`?
///
/// Tanpa flag ini Windows mengira tombol navigasi berasal dari numpad, dan
/// aplikasi yang membaca scancode mentah akan salah menafsirkannya.
pub fn is_extended(vk: VIRTUAL_KEY) -> bool {
    matches!(
        vk,
        VK_RCONTROL
            | VK_RMENU
            | VK_INSERT
            | VK_DELETE
            | VK_HOME
            | VK_END
            | VK_PRIOR
            | VK_NEXT
            | VK_UP
            | VK_DOWN
            | VK_LEFT
            | VK_RIGHT
            | VK_NUMLOCK
            | VK_SNAPSHOT
            | VK_DIVIDE
            | VK_LWIN
            | VK_RWIN
            | VK_APPS
            | VK_MEDIA_PLAY_PAUSE
            | VK_MEDIA_NEXT_TRACK
            | VK_MEDIA_PREV_TRACK
            | VK_MEDIA_STOP
            | VK_VOLUME_UP
            | VK_VOLUME_DOWN
            | VK_VOLUME_MUTE
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn huruf_dan_angka() {
        assert_eq!(vk_from_code("KeyA"), Some(VIRTUAL_KEY(b'A' as u16)));
        assert_eq!(vk_from_code("KeyZ"), Some(VIRTUAL_KEY(b'Z' as u16)));
        assert_eq!(vk_from_code("Digit0"), Some(VIRTUAL_KEY(b'0' as u16)));
        assert_eq!(vk_from_code("Digit9"), Some(VIRTUAL_KEY(b'9' as u16)));
    }

    #[test]
    fn tombol_fungsi() {
        assert_eq!(vk_from_code("F1"), Some(VK_F1));
        assert_eq!(vk_from_code("F12"), Some(VIRTUAL_KEY(VK_F1.0 + 11)));
        assert_eq!(vk_from_code("F24"), Some(VIRTUAL_KEY(VK_F1.0 + 23)));
        assert_eq!(vk_from_code("F25"), None, "F25 tidak ada");
        assert_eq!(vk_from_code("F0"), None);
    }

    #[test]
    fn numpad() {
        assert_eq!(vk_from_code("Numpad0"), Some(VK_NUMPAD0));
        assert_eq!(vk_from_code("Numpad9"), Some(VIRTUAL_KEY(VK_NUMPAD0.0 + 9)));
        assert_eq!(vk_from_code("NumpadAdd"), Some(VK_ADD));
    }

    #[test]
    fn modifier_kiri_kanan_dibedakan() {
        assert_eq!(vk_from_code("ControlLeft"), Some(VK_LCONTROL));
        assert_eq!(vk_from_code("ControlRight"), Some(VK_RCONTROL));
        assert_eq!(
            vk_from_code("Control"),
            vk_from_code("ControlLeft"),
            "nama polos harus memetakan ke modifier kiri"
        );
    }

    #[test]
    fn nama_tidak_dikenal_ditolak() {
        assert_eq!(vk_from_code("Key"), None);
        assert_eq!(vk_from_code("KeyAB"), None);
        assert_eq!(vk_from_code("Keya"), None, "harus huruf besar");
        assert_eq!(vk_from_code("Totally Not A Key"), None);
        assert_eq!(vk_from_code(""), None);
    }

    #[test]
    fn tombol_navigasi_ditandai_extended() {
        assert!(is_extended(vk_from_code("ArrowLeft").unwrap()));
        assert!(is_extended(vk_from_code("Delete").unwrap()));
        assert!(!is_extended(vk_from_code("KeyA").unwrap()));
        assert!(!is_extended(vk_from_code("ControlLeft").unwrap()));
    }
}
