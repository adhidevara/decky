//! Injeksi keyboard dan pointer lewat `SendInput`.

use windows::Win32::UI::Input::KeyboardAndMouse::*;

use super::keys::{is_extended, vk_from_code};

#[derive(Debug, thiserror::Error)]
pub enum InputError {
    #[error("tombol tidak dikenal: {0}")]
    UnknownKey(String),
    #[error("tombol mouse tidak dikenal: {0}")]
    UnknownButton(u8),
    #[error("SendInput ditolak sistem (kemungkinan diblokir UIPI)")]
    Rejected,
}

/// Kirim sekumpulan event ke sistem dalam satu panggilan.
///
/// Satu panggilan `SendInput` untuk seluruh urutan itu penting: Windows
/// menjamin event dalam satu batch tidak disisipi input dari sumber lain,
/// jadi kombinasi tombol tidak bisa "bocor" di tengah.
fn send(inputs: &[INPUT]) -> Result<(), InputError> {
    if inputs.is_empty() {
        return Ok(());
    }
    let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize == inputs.len() {
        Ok(())
    } else {
        // Paling sering karena UIPI: proses dengan integrity level lebih tinggi
        // (installer, Task Manager, layar UAC) tidak bisa disuntik input.
        Err(InputError::Rejected)
    }
}

fn key_input(vk: VIRTUAL_KEY, down: bool) -> INPUT {
    let mut flags = KEYBD_EVENT_FLAGS(0);
    if !down {
        flags |= KEYEVENTF_KEYUP;
    }
    if is_extended(vk) {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

/// Satu unit UTF-16. Dipakai untuk mengetik teks apa adanya, tanpa peduli
/// layout keyboard aktif.
fn unicode_input(unit: u16, down: bool) -> INPUT {
    let mut flags = KEYEVENTF_UNICODE;
    if !down {
        flags |= KEYEVENTF_KEYUP;
    }
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(0),
                wScan: unit,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

/// Tekan kombinasi tombol, lalu lepas dengan urutan terbalik.
///
/// Urutan terbalik itu wajib: melepas modifier sebelum tombol utama membuat
/// aplikasi melihat tombol itu ditekan sendirian.
pub fn hotkey(codes: &[String]) -> Result<(), InputError> {
    let vks = codes
        .iter()
        .map(|c| vk_from_code(c).ok_or_else(|| InputError::UnknownKey(c.clone())))
        .collect::<Result<Vec<_>, _>>()?;

    let mut inputs = Vec::with_capacity(vks.len() * 2);
    for vk in &vks {
        inputs.push(key_input(*vk, true));
    }
    for vk in vks.iter().rev() {
        inputs.push(key_input(*vk, false));
    }
    send(&inputs)
}

/// Tekan lalu lepas satu tombol.
pub fn tap(code: &str) -> Result<(), InputError> {
    let vk = vk_from_code(code).ok_or_else(|| InputError::UnknownKey(code.to_string()))?;
    send(&[key_input(vk, true), key_input(vk, false)])
}

/// Tekan atau lepas satu tombol beserta modifier yang sedang ditahan.
///
/// Modifier ditekan sebelum tombol dan dilepas sesudahnya, supaya aplikasi
/// tidak pernah melihat tombol utama tanpa modifier-nya.
pub fn key_with_mods(code: &str, down: bool, mods: u8) -> Result<(), InputError> {
    let vk = vk_from_code(code).ok_or_else(|| InputError::UnknownKey(code.to_string()))?;
    let modifiers = modifier_vks(mods);

    let mut inputs = Vec::with_capacity(modifiers.len() + 1);
    if down {
        for m in &modifiers {
            inputs.push(key_input(*m, true));
        }
        inputs.push(key_input(vk, true));
    } else {
        inputs.push(key_input(vk, false));
        for m in modifiers.iter().rev() {
            inputs.push(key_input(*m, false));
        }
    }
    send(&inputs)
}

/// Bitmask modifier dari protokol: 1 Shift, 2 Ctrl, 4 Alt, 8 Meta.
fn modifier_vks(mods: u8) -> Vec<VIRTUAL_KEY> {
    let mut out = Vec::new();
    if mods & 1 != 0 {
        out.push(VK_LSHIFT);
    }
    if mods & 2 != 0 {
        out.push(VK_LCONTROL);
    }
    if mods & 4 != 0 {
        out.push(VK_LMENU);
    }
    if mods & 8 != 0 {
        out.push(VK_LWIN);
    }
    out
}

/// Ketik teks sebagai Unicode.
///
/// Dikirim per potongan supaya teks panjang tidak membuat satu panggilan
/// `SendInput` raksasa yang bisa ditolak sistem.
pub fn type_text(text: &str) -> Result<(), InputError> {
    const BATCH: usize = 512;

    let units: Vec<u16> = text.encode_utf16().collect();
    for chunk in units.chunks(BATCH) {
        let mut inputs = Vec::with_capacity(chunk.len() * 2);
        for unit in chunk {
            inputs.push(unicode_input(*unit, true));
            inputs.push(unicode_input(*unit, false));
        }
        send(&inputs)?;
    }
    Ok(())
}

/// Gerakkan kursor relatif terhadap posisinya sekarang.
///
/// Relatif, bukan absolut: koordinat absolut akan memaksa client tahu ukuran
/// layar PC, dan satu paket yang hilang akan melemparkan kursor ke tempat
/// acak alih-alih sekadar melewatkan sedikit gerakan.
pub fn mouse_move(dx: i32, dy: i32) -> Result<(), InputError> {
    if dx == 0 && dy == 0 {
        return Ok(());
    }
    send(&[mouse_input(dx, dy, 0, MOUSEEVENTF_MOVE)])
}

/// 0 kiri, 1 tengah, 2 kanan — sesuai definisi di protokol.
pub fn mouse_button(button: u8, down: bool) -> Result<(), InputError> {
    let flags = match (button, down) {
        (0, true) => MOUSEEVENTF_LEFTDOWN,
        (0, false) => MOUSEEVENTF_LEFTUP,
        (1, true) => MOUSEEVENTF_MIDDLEDOWN,
        (1, false) => MOUSEEVENTF_MIDDLEUP,
        (2, true) => MOUSEEVENTF_RIGHTDOWN,
        (2, false) => MOUSEEVENTF_RIGHTUP,
        _ => return Err(InputError::UnknownButton(button)),
    };
    send(&[mouse_input(0, 0, 0, flags)])
}

/// Putar roda. Satuannya kelipatan 120, seperti yang diharapkan Windows.
///
/// `mods` menahan modifier selama putaran — Ctrl + roda adalah cara hampir
/// semua aplikasi memahami zoom. Modifier ditekan dan dilepas di dalam satu
/// panggilan `SendInput`, jadi tidak mungkin tertinggal menyala.
pub fn mouse_scroll(dx: i32, dy: i32, mods: u8) -> Result<(), InputError> {
    if dx == 0 && dy == 0 {
        return Ok(());
    }

    let modifiers = modifier_vks(mods);
    let mut inputs = Vec::with_capacity(modifiers.len() * 2 + 2);

    for m in &modifiers {
        inputs.push(key_input(*m, true));
    }
    if dy != 0 {
        inputs.push(mouse_input(0, 0, dy, MOUSEEVENTF_WHEEL));
    }
    if dx != 0 {
        inputs.push(mouse_input(0, 0, dx, MOUSEEVENTF_HWHEEL));
    }
    for m in modifiers.iter().rev() {
        inputs.push(key_input(*m, false));
    }

    send(&inputs)
}

fn mouse_input(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                // mouseData membawa jumlah putaran roda untuk event wheel, dan
                // diabaikan untuk yang lain.
                mouseData: data as u32,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Test di sini sengaja tidak memanggil SendInput: itu akan benar-benar
    // menggerakkan keyboard mesin yang menjalankan test. Yang diperiksa adalah
    // penyusunan event dan penanganan error.

    #[test]
    fn tombol_tidak_dikenal_ditolak_sebelum_dikirim() {
        let err = hotkey(&["ControlLeft".into(), "BukanTombol".into()]).unwrap_err();
        assert!(matches!(err, InputError::UnknownKey(k) if k == "BukanTombol"));
    }

    #[test]
    fn teks_kosong_tidak_mengirim_apa_apa() {
        assert!(type_text("").is_ok());
    }

    #[test]
    fn hotkey_kosong_tidak_mengirim_apa_apa() {
        assert!(hotkey(&[]).is_ok());
    }

    #[test]
    fn keyup_memakai_flag_yang_benar() {
        let down = key_input(VK_LCONTROL, true);
        let up = key_input(VK_LCONTROL, false);
        unsafe {
            assert_eq!(down.Anonymous.ki.dwFlags & KEYEVENTF_KEYUP, KEYBD_EVENT_FLAGS(0));
            assert_eq!(up.Anonymous.ki.dwFlags & KEYEVENTF_KEYUP, KEYEVENTF_KEYUP);
        }
    }

    #[test]
    fn tombol_extended_menyertakan_flagnya() {
        let left = key_input(VK_LEFT, true);
        let a = key_input(VIRTUAL_KEY(b'A' as u16), true);
        unsafe {
            assert_eq!(
                left.Anonymous.ki.dwFlags & KEYEVENTF_EXTENDEDKEY,
                KEYEVENTF_EXTENDEDKEY
            );
            assert_eq!(
                a.Anonymous.ki.dwFlags & KEYEVENTF_EXTENDEDKEY,
                KEYBD_EVENT_FLAGS(0)
            );
        }
    }

    #[test]
    fn bitmask_modifier_dipetakan_sesuai_protokol() {
        assert!(modifier_vks(0).is_empty());
        assert_eq!(modifier_vks(1), vec![VK_LSHIFT]);
        assert_eq!(modifier_vks(2), vec![VK_LCONTROL]);
        assert_eq!(modifier_vks(4), vec![VK_LMENU]);
        assert_eq!(modifier_vks(8), vec![VK_LWIN]);
        assert_eq!(modifier_vks(3), vec![VK_LSHIFT, VK_LCONTROL]);
        assert_eq!(
            modifier_vks(15),
            vec![VK_LSHIFT, VK_LCONTROL, VK_LMENU, VK_LWIN]
        );
    }

    #[test]
    fn key_dengan_tombol_tak_dikenal_ditolak() {
        assert!(matches!(
            key_with_mods("BukanTombol", true, 0).unwrap_err(),
            InputError::UnknownKey(_)
        ));
    }

    #[test]
    fn gerakan_nol_tidak_mengirim_apa_apa() {
        assert!(mouse_move(0, 0).is_ok());
        assert!(mouse_scroll(0, 0, 0).is_ok());
        assert!(mouse_scroll(0, 0, 2).is_ok(), "mods tanpa gerakan juga tidak dikirim");
    }

    #[test]
    fn tombol_mouse_tidak_dikenal_ditolak() {
        let err = mouse_button(7, true).unwrap_err();
        assert!(matches!(err, InputError::UnknownButton(7)));
    }

    #[test]
    fn gerakan_memakai_flag_relatif() {
        let input = mouse_input(5, -3, 0, MOUSEEVENTF_MOVE);
        unsafe {
            assert_eq!(input.Anonymous.mi.dx, 5);
            assert_eq!(input.Anonymous.mi.dy, -3);
            assert_eq!(input.Anonymous.mi.dwFlags & MOUSEEVENTF_MOVE, MOUSEEVENTF_MOVE);
            assert_eq!(
                input.Anonymous.mi.dwFlags & MOUSEEVENTF_ABSOLUTE,
                MOUSE_EVENT_FLAGS(0),
                "koordinat absolut tidak pernah dipakai"
            );
        }
    }

    #[test]
    fn scroll_membawa_jumlah_di_mouse_data() {
        let input = mouse_input(0, 0, 240, MOUSEEVENTF_WHEEL);
        unsafe {
            assert_eq!(input.Anonymous.mi.mouseData, 240);
        }
    }

    #[test]
    fn unicode_memakai_scancode_bukan_vk() {
        let input = unicode_input('é' as u16, true);
        unsafe {
            assert_eq!(input.Anonymous.ki.wVk, VIRTUAL_KEY(0));
            assert_eq!(input.Anonymous.ki.wScan, 'é' as u16);
            assert_eq!(
                input.Anonymous.ki.dwFlags & KEYEVENTF_UNICODE,
                KEYEVENTF_UNICODE
            );
        }
    }
}
