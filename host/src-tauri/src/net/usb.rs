//! Jembatan USB: pasang `adb reverse` otomatis saat device tercolok.
//!
//! `adb reverse tcp:P tcp:P` membuat port P di HP meneruskan ke port P di PC,
//! jadi client cukup menyambung ke `127.0.0.1` dan lalu lintasnya lewat kabel.
//! Latency-nya di bawah 5 ms dan tidak tergantung Wi-Fi sama sekali.
//!
//! Tanpa ini user harus menjalankan perintah adb sendiri setiap kali mencolok
//! kabel — yang jelas bukan pengalaman yang diharapkan dari aplikasi jadi.

use std::collections::HashSet;
use std::time::Duration;
use tokio::process::Command;

/// Jeda antar pemeriksaan daftar device.
const POLL: Duration = Duration::from_secs(2);

/// Pantau device yang tercolok dan pasangkan reverse tunnel untuk tiap yang baru.
///
/// Jalan selamanya; panggil lewat `tokio::spawn`.
pub async fn watch(port: u16) {
    let mut known: HashSet<String> = HashSet::new();
    let mut reported_missing = false;

    loop {
        tokio::time::sleep(POLL).await;

        let devices = match list_devices().await {
            Ok(d) => {
                reported_missing = false;
                d
            }
            Err(e) => {
                // adb tidak terpasang itu wajar — banyak user hanya memakai
                // Wi-Fi. Laporkan sekali, lalu diam supaya log tidak banjir.
                if !reported_missing {
                    tracing::info!("jembatan USB tidak aktif ({e})");
                    reported_missing = true;
                }
                known.clear();
                continue;
            }
        };

        for serial in &devices {
            if known.insert(serial.clone()) {
                match install_reverse(serial, port).await {
                    Ok(()) => tracing::info!("jembatan USB siap untuk {serial}"),
                    Err(e) => {
                        tracing::warn!("adb reverse gagal untuk {serial}: {e}");
                        // Jangan ingat yang gagal, supaya dicoba lagi nanti.
                        known.remove(serial);
                    }
                }
            }
        }

        // Device yang dicabut harus dilupakan, kalau tidak reverse-nya tidak
        // akan dipasang ulang saat dicolok kembali.
        known.retain(|s| devices.contains(s));
    }
}

/// Serial device yang statusnya `device` (bukan `unauthorized` atau `offline`).
async fn list_devices() -> Result<HashSet<String>, String> {
    let out = Command::new("adb")
        .arg("devices")
        .output()
        .await
        .map_err(|e| format!("adb tidak bisa dijalankan: {e}"))?;

    if !out.status.success() {
        return Err(format!("adb devices keluar dengan {}", out.status));
    }

    Ok(parse_devices(&String::from_utf8_lossy(&out.stdout)))
}

/// Ambil serial dari keluaran `adb devices`.
///
/// Hanya status `device` yang diterima: `unauthorized` berarti user belum
/// menyetujui dialog debugging, dan `offline` berarti device sedang tidak
/// bisa diajak bicara.
fn parse_devices(stdout: &str) -> HashSet<String> {
    stdout
        .lines()
        .skip(1) // baris "List of devices attached"
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let serial = parts.next()?;
            let state = parts.next()?;
            (state == "device").then(|| serial.to_string())
        })
        .collect()
}

async fn install_reverse(serial: &str, port: u16) -> Result<(), String> {
    let out = Command::new("adb")
        .args(["-s", serial, "reverse"])
        .arg(format!("tcp:{port}"))
        .arg(format!("tcp:{port}"))
        .output()
        .await
        .map_err(|e| e.to_string())?;

    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::parse_devices;

    #[test]
    fn mengambil_device_yang_siap() {
        let out = "List of devices attached\n\
                   GYGYD24921200860\tdevice product:BTK-W09 model:BTK_W09\n";
        let devices = parse_devices(out);
        assert_eq!(devices.len(), 1);
        assert!(devices.contains("GYGYD24921200860"));
    }

    #[test]
    fn melewati_device_yang_belum_diizinkan() {
        let out = "List of devices attached\n\
                   AAA111\tunauthorized\n\
                   BBB222\toffline\n\
                   CCC333\tdevice\n";
        let devices = parse_devices(out);
        assert_eq!(devices, ["CCC333".to_string()].into_iter().collect());
    }

    #[test]
    fn tanpa_device_hasilnya_kosong() {
        assert!(parse_devices("List of devices attached\n\n").is_empty());
        assert!(parse_devices("").is_empty());
    }

    #[test]
    fn baris_judul_tidak_ikut_terbaca() {
        // Baris pertama punya dua kata, jadi tanpa skip ia akan lolos filter.
        assert!(parse_devices("List of devices attached\n").is_empty());
    }
}
