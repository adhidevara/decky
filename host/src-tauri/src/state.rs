//! State bersama antara server jaringan dan UI Tauri.
//!
//! Server tidak tahu apa-apa soal Tauri. Ia menyiarkan [`UiEvent`] lewat
//! broadcast channel, dan `lib.rs` yang meneruskannya ke frontend. Dengan
//! begitu lapisan jaringan bisa diuji tanpa menjalankan aplikasi.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;

use crate::actions::obs::ObsClient;
use crate::config::HostConfig;
use crate::pairing::{AttemptLimiter, PairingSession};

/// Satu client yang sedang terhubung.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Connection {
    pub client_id: String,
    pub name: String,
    pub platform: String,
    pub addr: String,
    /// Round-trip terakhir dalam ms, kalau sudah pernah terukur.
    pub rtt_ms: Option<u32>,
}

/// Event yang dikirim ke UI.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum UiEvent {
    PairingStarted { pin: String, ttl_secs: u64 },
    PairingEnded,
    DevicePaired { client_id: String, name: String },
    Connected(Connection),
    Disconnected { client_id: String },
    Rtt { client_id: String, rtt_ms: u32 },
    /// Layout atau profil deck berubah; koneksi yang hidup mengirim ulang.
    DeckChanged,
    ServerError { msg: String },
}

pub struct AppCtx {
    pub cfg_dir: PathBuf,
    cfg: Mutex<HostConfig>,
    pairing: Mutex<Option<PairingSession>>,
    limiter: Mutex<AttemptLimiter>,
    conns: Mutex<HashMap<String, Connection>>,
    events: broadcast::Sender<UiEvent>,
    /// Koneksi OBS dipakai bersama semua client, dan menyambung sendiri
    /// saat pertama dibutuhkan.
    pub obs: Arc<ObsClient>,
}

impl AppCtx {
    pub fn new(cfg_dir: PathBuf, cfg: HostConfig) -> Self {
        let (events, _) = broadcast::channel(64);
        let obs = Arc::new(ObsClient::new(cfg.obs.clone()));
        Self {
            cfg_dir,
            obs,
            cfg: Mutex::new(cfg),
            pairing: Mutex::new(None),
            limiter: Mutex::new(AttemptLimiter::new()),
            conns: Mutex::new(HashMap::new()),
            events,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<UiEvent> {
        self.events.subscribe()
    }

    /// Siarkan event. Tidak ada pelanggan bukan error — UI boleh saja belum siap.
    pub fn emit(&self, ev: UiEvent) {
        let _ = self.events.send(ev);
    }

    // ── config ──────────────────────────────────────────────────────────

    /// Baca sesuatu dari config. Kunci dilepas sebelum fungsi ini kembali.
    pub fn with_cfg<T>(&self, f: impl FnOnce(&HostConfig) -> T) -> T {
        f(&self.cfg.lock().expect("config mutex keracunan"))
    }

    /// Ubah config lalu langsung simpan ke disk.
    pub fn update_cfg<T>(&self, f: impl FnOnce(&mut HostConfig) -> T) -> anyhow::Result<T> {
        let (out, snapshot) = {
            let mut cfg = self.cfg.lock().expect("config mutex keracunan");
            let out = f(&mut cfg);
            (out, cfg.clone())
        };
        snapshot.save(&self.cfg_dir)?;
        Ok(out)
    }

    pub fn host_id(&self) -> String {
        self.with_cfg(|c| c.host_id.clone())
    }

    pub fn host_name(&self) -> String {
        self.with_cfg(|c| c.host_name.clone())
    }

    pub fn port(&self) -> u16 {
        self.with_cfg(|c| c.port)
    }

    // ── pairing ─────────────────────────────────────────────────────────

    /// Mulai sesi pairing baru, menggantikan yang lama kalau ada.
    pub fn start_pairing(&self) -> PairingSession {
        self.start_pairing_with(PairingSession::new())
    }

    /// Varian dengan PIN yang ditentukan pemanggil.
    ///
    /// Dipakai uji interop, yang butuh PIN tetap supaya kedua sisi menurunkan
    /// PSK yang sama tanpa harus membaca layar.
    pub fn start_pairing_with(&self, session: PairingSession) -> PairingSession {
        *self.pairing.lock().expect("pairing mutex keracunan") = Some(session.clone());
        self.emit(UiEvent::PairingStarted {
            pin: session.pin.clone(),
            ttl_secs: session.remaining().as_secs(),
        });
        session
    }

    pub fn stop_pairing(&self) {
        let had = self
            .pairing
            .lock()
            .expect("pairing mutex keracunan")
            .take()
            .is_some();
        if had {
            self.emit(UiEvent::PairingEnded);
        }
    }

    /// Sesi pairing yang masih berlaku, kalau ada.
    ///
    /// Sesi yang sudah kedaluwarsa dibuang sekalian di sini, jadi tidak perlu
    /// timer terpisah untuk membersihkannya.
    pub fn active_pairing(&self) -> Option<PairingSession> {
        let mut guard = self.pairing.lock().expect("pairing mutex keracunan");
        match guard.as_ref() {
            Some(s) if s.expired() => {
                *guard = None;
                drop(guard);
                self.emit(UiEvent::PairingEnded);
                None
            }
            other => other.cloned(),
        }
    }

    pub fn limiter_blocked(&self, client_id: &str) -> bool {
        self.limiter
            .lock()
            .expect("limiter mutex keracunan")
            .blocked(client_id)
    }

    pub fn record_pair_failure(&self, client_id: &str) -> bool {
        self.limiter
            .lock()
            .expect("limiter mutex keracunan")
            .record_failure(client_id)
    }

    pub fn clear_pair_failures(&self, client_id: &str) {
        self.limiter
            .lock()
            .expect("limiter mutex keracunan")
            .clear(client_id);
    }

    // ── koneksi ─────────────────────────────────────────────────────────

    pub fn add_conn(&self, conn: Connection) {
        self.conns
            .lock()
            .expect("conns mutex keracunan")
            .insert(conn.client_id.clone(), conn.clone());
        self.emit(UiEvent::Connected(conn));
    }

    pub fn remove_conn(&self, client_id: &str) {
        let existed = self
            .conns
            .lock()
            .expect("conns mutex keracunan")
            .remove(client_id)
            .is_some();
        if existed {
            self.emit(UiEvent::Disconnected {
                client_id: client_id.to_string(),
            });
        }
    }

    pub fn set_rtt(&self, client_id: &str, rtt_ms: u32) {
        let mut conns = self.conns.lock().expect("conns mutex keracunan");
        if let Some(c) = conns.get_mut(client_id) {
            c.rtt_ms = Some(rtt_ms);
        }
        drop(conns);
        self.emit(UiEvent::Rtt {
            client_id: client_id.to_string(),
            rtt_ms,
        });
    }

    pub fn connections(&self) -> Vec<Connection> {
        self.conns
            .lock()
            .expect("conns mutex keracunan")
            .values()
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> AppCtx {
        let dir = std::env::temp_dir().join(format!("decky-test-{}", uuid::Uuid::new_v4()));
        AppCtx::new(dir, HostConfig::default())
    }

    #[test]
    fn pairing_aktif_lalu_dihentikan() {
        let c = ctx();
        assert!(c.active_pairing().is_none());
        let s = c.start_pairing();
        assert_eq!(c.active_pairing().map(|p| p.pin), Some(s.pin));
        c.stop_pairing();
        assert!(c.active_pairing().is_none());
    }

    #[test]
    fn start_pairing_mengganti_pin_lama() {
        let c = ctx();
        let first = c.start_pairing();
        let second = c.start_pairing();
        assert_eq!(c.active_pairing().map(|p| p.pin), Some(second.pin));
        // PIN acak, jadi sesekali bisa sama; yang penting sesi aktifnya yang baru.
        let _ = first;
    }

    #[test]
    fn koneksi_dicatat_dan_dihapus() {
        let c = ctx();
        let conn = Connection {
            client_id: "c1".into(),
            name: "HP".into(),
            platform: "android".into(),
            addr: "192.168.1.5:51000".into(),
            rtt_ms: None,
        };
        c.add_conn(conn);
        assert_eq!(c.connections().len(), 1);
        c.set_rtt("c1", 12);
        assert_eq!(c.connections()[0].rtt_ms, Some(12));
        c.remove_conn("c1");
        assert!(c.connections().is_empty());
    }

    #[test]
    fn event_sampai_ke_pelanggan() {
        let c = ctx();
        let mut rx = c.subscribe();
        c.start_pairing();
        let ev = rx.try_recv().expect("event pairing tidak terkirim");
        assert!(matches!(ev, UiEvent::PairingStarted { .. }));
    }
}
