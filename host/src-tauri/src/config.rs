//! Konfigurasi host yang tidak rahasia, disimpan sebagai JSON biasa.
//!
//! Token pairing TIDAK pernah masuk ke sini — token hidup di Windows
//! Credential Manager lewat [`crate::pairing::TokenStore`]. File ini hanya
//! menyimpan metadata yang aman kalau terbaca orang lain.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::actions::DeckConfig;
use crate::actions::obs::ObsSettings;
use crate::proto_gen::DEFAULT_PORT;

/// Device yang pernah dipasangkan. Tanpa token — hanya metadata tampilan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairedDevice {
    pub client_id: String,
    pub name: String,
    pub platform: String,
    /// Unix epoch detik.
    pub paired_at: i64,
    /// Unix epoch detik, diperbarui tiap koneksi sukses.
    pub last_seen: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostConfig {
    /// UUID stabil, diumumkan di TXT record mDNS.
    pub host_id: String,
    /// Nama yang ditampilkan di HP.
    pub host_name: String,
    pub port: u16,
    #[serde(default)]
    pub devices: Vec<PairedDevice>,
    #[serde(default)]
    pub deck: DeckConfig,
    #[serde(default)]
    pub obs: ObsSettings,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self {
            host_id: uuid::Uuid::new_v4().to_string(),
            host_name: hostname(),
            port: DEFAULT_PORT,
            devices: Vec::new(),
            deck: DeckConfig::default(),
            obs: ObsSettings::default(),
        }
    }
}

impl HostConfig {
    /// Muat dari disk, atau buat default dan langsung simpan kalau belum ada.
    pub fn load_or_init(dir: &Path) -> anyhow::Result<Self> {
        let path = Self::path(dir);
        if path.exists() {
            let raw = std::fs::read_to_string(&path)?;
            match serde_json::from_str::<Self>(&raw) {
                Ok(cfg) => return Ok(cfg),
                Err(e) => {
                    // Config rusak jangan bikin app gagal start — sisihkan lalu mulai bersih.
                    tracing::error!("config rusak ({e}), disisihkan ke config.json.bak");
                    let _ = std::fs::rename(&path, path.with_extension("json.bak"));
                }
            }
        }
        let cfg = Self::default();
        cfg.save(dir)?;
        Ok(cfg)
    }

    pub fn save(&self, dir: &Path) -> anyhow::Result<()> {
        std::fs::create_dir_all(dir)?;
        let tmp = Self::path(dir).with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        // Tulis atomik: rename menimpa dalam satu operasi, jadi tidak ada
        // jendela waktu dengan file setengah tertulis.
        std::fs::rename(tmp, Self::path(dir))?;
        Ok(())
    }

    fn path(dir: &Path) -> PathBuf {
        dir.join("config.json")
    }

    pub fn device(&self, client_id: &str) -> Option<&PairedDevice> {
        self.devices.iter().find(|d| d.client_id == client_id)
    }

    /// Tambah device baru atau perbarui yang sudah ada.
    pub fn upsert_device(&mut self, dev: PairedDevice) {
        match self.devices.iter_mut().find(|d| d.client_id == dev.client_id) {
            Some(existing) => *existing = dev,
            None => self.devices.push(dev),
        }
    }

    pub fn remove_device(&mut self, client_id: &str) -> bool {
        let before = self.devices.len();
        self.devices.retain(|d| d.client_id != client_id);
        self.devices.len() != before
    }

    pub fn touch_device(&mut self, client_id: &str) {
        if let Some(d) = self.devices.iter_mut().find(|d| d.client_id == client_id) {
            d.last_seen = now_secs();
        }
    }
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn hostname() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "Decky Host".to_string())
}
