//! Injeksi keyboard lewat `SendInput`.
//!
//! Fase 3 menambahkan pointer di sini; untuk sekarang hanya keyboard, yang
//! sudah cukup untuk hotkey dan teks di mode Deck.

use windows::Win32::UI::Input::KeyboardAndMouse::*;

use super::keys::{is_extended, vk_from_code};

#[derive(Debug, thiserror::Error)]
pub enum InputError {
    #[error("tombol tidak dikenal: {0}")]
    UnknownKey(String),
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
