//! Publikasi mDNS supaya client menemukan host tanpa perlu ketik IP.

use mdns_sd::{ServiceDaemon, ServiceInfo};
use std::collections::HashMap;

pub const SERVICE_TYPE: &str = "_decky._tcp.local.";

/// Daemon mDNS yang hidup. Service dicabut otomatis saat nilai ini di-drop.
pub struct Advertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

impl Advertiser {
    /// Umumkan host ini di jaringan lokal.
    ///
    /// `host_id` masuk ke TXT record supaya client bisa mengenali host yang
    /// sama walau nama tampilannya diubah user.
    pub fn start(host_id: &str, host_name: &str, port: u16, os: &str) -> anyhow::Result<Self> {
        let daemon = ServiceDaemon::new()?;

        let instance = sanitize(host_name);
        let mut txt = HashMap::new();
        txt.insert("v".to_string(), "1".to_string());
        txt.insert("name".to_string(), host_name.to_string());
        txt.insert("os".to_string(), os.to_string());
        txt.insert("id".to_string(), host_id.to_string());

        let info = ServiceInfo::new(
            SERVICE_TYPE,
            &instance,
            &format!("{instance}.local."),
            "",
            port,
            txt,
        )?
        // Biarkan daemon yang mencari alamat IP dan mengikuti perubahan
        // jaringan — host bisa pindah Wi-Fi tanpa kita daftar ulang manual.
        .enable_addr_auto();

        let fullname = info.get_fullname().to_string();
        daemon.register(info)?;
        tracing::info!("mDNS terdaftar sebagai {fullname} di port {port}");

        Ok(Self { daemon, fullname })
    }
}

impl Drop for Advertiser {
    fn drop(&mut self) {
        if let Err(e) = self.daemon.unregister(&self.fullname) {
            tracing::warn!("gagal mencabut service mDNS: {e}");
        }
    }
}

/// Ubah nama host jadi label DNS yang sah.
///
/// Nama komputer Windows bisa mengandung spasi dan karakter lain yang tidak
/// valid untuk label DNS-SD, jadi disaring dulu.
fn sanitize(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .collect();
    let trimmed = cleaned.trim_matches('-');
    if trimmed.is_empty() {
        "decky-host".to_string()
    } else {
        trimmed.chars().take(63).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::sanitize;

    #[test]
    fn spasi_dan_simbol_jadi_strip() {
        assert_eq!(sanitize("Adhi PC"), "Adhi-PC");
        assert_eq!(sanitize("PC_Kerja.01"), "PC-Kerja-01");
    }

    #[test]
    fn strip_di_tepi_dibuang() {
        assert_eq!(sanitize("--pc--"), "pc");
    }

    #[test]
    fn nama_kosong_punya_fallback() {
        assert_eq!(sanitize(""), "decky-host");
        assert_eq!(sanitize("???"), "decky-host");
    }

    #[test]
    fn label_dipotong_63_karakter() {
        assert_eq!(sanitize(&"a".repeat(100)).len(), 63);
    }
}
