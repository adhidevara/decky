//! Integrasi obs-websocket v5.
//!
//! OBS jarang sudah berjalan saat Decky start, dan sering ditutup di tengah
//! sesi. Jadi koneksi dibuat malas dan di-reset diam-diam saat putus: tombol
//! scene berikutnya akan menyambung ulang sendiri, tanpa user perlu
//! menyentuh apa pun.

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObsSettings {
    pub enabled: bool,
    pub host: String,
    pub port: u16,
    /// Kosong kalau obs-websocket dijalankan tanpa autentikasi.
    #[serde(default)]
    pub password: String,
}

impl Default for ObsSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            host: "127.0.0.1".into(),
            port: 4455, // default obs-websocket v5
            password: String::new(),
        }
    }
}

pub struct ObsClient {
    settings: Mutex<ObsSettings>,
    client: Mutex<Option<obws::Client>>,
}

impl ObsClient {
    pub fn new(settings: ObsSettings) -> Self {
        Self {
            settings: Mutex::new(settings),
            client: Mutex::new(None),
        }
    }

    pub async fn settings(&self) -> ObsSettings {
        self.settings.lock().await.clone()
    }

    /// Ganti setelan dan buang koneksi lama supaya yang baru dipakai.
    pub async fn configure(&self, settings: ObsSettings) {
        *self.settings.lock().await = settings;
        *self.client.lock().await = None;
    }

    /// Apakah OBS sedang tersambung dan merespons?
    ///
    /// Dipakai untuk memutuskan apakah cap `obs` diumumkan ke client.
    pub async fn is_live(&self) -> bool {
        let settings = self.settings.lock().await.clone();
        if !settings.enabled {
            return false;
        }
        self.with_client(|c| Box::pin(async move { c.general().version().await.map(|_| ()) }))
            .await
            .is_ok()
    }

    pub async fn set_scene(&self, scene: &str) -> Result<(), String> {
        // Nama di-copy supaya future yang dihasilkan tidak meminjam apa pun
        // dari pemanggil — itu yang membuat bound HRTB di bawah bisa dipenuhi.
        let name = scene.to_string();
        self.with_client(move |c| {
            Box::pin(async move {
                c.scenes()
                    .set_current_program_scene(obws::requests::scenes::SceneId::Name(&name))
                    .await
            })
        })
        .await
    }

    pub async fn current_scene(&self) -> Result<String, String> {
        self.with_client(|c| {
            Box::pin(async move { c.scenes().current_program_scene().await.map(|s| s.id.name) })
        })
        .await
    }

    /// Jalankan satu operasi, menyambung dulu kalau perlu.
    ///
    /// Kalau operasi gagal, koneksi yang di-cache dibuang: kegagalan hampir
    /// selalu berarti OBS sudah ditutup, dan menyimpan socket mati hanya
    /// membuat percobaan berikutnya ikut gagal.
    async fn with_client<T, F>(&self, f: F) -> Result<T, String>
    where
        // HRTB plus future ter-box: tanpa ini peminjaman `obws::Client` dari
        // guard tidak bisa dibuktikan hidup cukup lama oleh pengecek lifetime.
        F: for<'a> FnOnce(
            &'a obws::Client,
        ) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = Result<T, obws::error::Error>> + Send + 'a>,
        >,
    {
        let settings = self.settings.lock().await.clone();
        if !settings.enabled {
            return Err("integrasi OBS tidak diaktifkan".into());
        }

        let mut guard = self.client.lock().await;
        if guard.is_none() {
            let password = (!settings.password.is_empty()).then_some(settings.password.as_str());
            let client = obws::Client::connect(&settings.host, settings.port, password)
                .await
                .map_err(|e| format!("tidak bisa menyambung ke OBS: {e}"))?;
            *guard = Some(client);
        }

        let result = f(guard.as_ref().expect("baru saja diisi")).await;
        if result.is_err() {
            *guard = None;
        }
        result.map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn nonaktif_berarti_tidak_pernah_menyambung() {
        let obs = ObsClient::new(ObsSettings::default());
        assert!(!obs.is_live().await);
        let err = obs.set_scene("Apa saja").await.unwrap_err();
        assert!(err.contains("tidak diaktifkan"));
    }

    #[tokio::test]
    async fn configure_mengganti_setelan() {
        let obs = ObsClient::new(ObsSettings::default());
        obs.configure(ObsSettings {
            enabled: true,
            host: "192.168.1.9".into(),
            port: 4466,
            password: "rahasia".into(),
        })
        .await;

        let s = obs.settings().await;
        assert!(s.enabled);
        assert_eq!(s.host, "192.168.1.9");
        assert_eq!(s.port, 4466);
    }

    #[test]
    fn port_bawaan_sesuai_obs_websocket_v5() {
        assert_eq!(ObsSettings::default().port, 4455);
        assert!(!ObsSettings::default().enabled, "harus opt-in");
    }
}
