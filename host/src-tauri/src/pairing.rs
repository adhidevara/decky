//! Pairing berbasis PIN dan penyimpanan token.
//!
//! Token sesi disimpan di Windows Credential Manager (via crate `keyring`),
//! bukan di file config. Credential Manager sendiri didukung DPAPI, jadi token
//! ter-enkripsi dengan kredensial login user tanpa kita perlu memanggil
//! CryptProtectData sendiri.

use rand::RngExt;
use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::net::noise::TOKEN_LEN;

/// Berapa lama PIN berlaku setelah ditampilkan.
pub const PIN_TTL: Duration = Duration::from_secs(60);

/// Percobaan pairing gagal yang ditoleransi per client_id sebelum di-throttle.
pub const MAX_ATTEMPTS: u8 = 5;

/// Lama throttle setelah batas percobaan terlampaui.
pub const THROTTLE: Duration = Duration::from_secs(900);

const KEYRING_SERVICE: &str = "decky-host";

#[derive(Debug, thiserror::Error)]
pub enum PairingError {
    #[error("tidak ada sesi pairing aktif")]
    NotPairing,
    #[error("PIN kedaluwarsa")]
    Expired,
    #[error("terlalu banyak percobaan, coba lagi nanti")]
    Throttled,
    #[error("keyring: {0}")]
    Keyring(#[from] keyring::Error),
}

/// Sesi pairing yang sedang berjalan. Hanya boleh ada satu dalam satu waktu.
#[derive(Debug, Clone)]
pub struct PairingSession {
    pub pin: String,
    pub started: Instant,
}

impl PairingSession {
    pub fn new() -> Self {
        Self::with_pin(random_pin())
    }

    /// Sesi dengan PIN yang ditentukan. Dipakai uji interop.
    pub fn with_pin(pin: String) -> Self {
        Self {
            pin,
            started: Instant::now(),
        }
    }

    pub fn expired(&self) -> bool {
        self.started.elapsed() > PIN_TTL
    }

    pub fn remaining(&self) -> Duration {
        PIN_TTL.saturating_sub(self.started.elapsed())
    }
}

impl Default for PairingSession {
    fn default() -> Self {
        Self::new()
    }
}

/// PIN 6 digit dari RNG kriptografis.
///
/// Rentangnya sengaja 0..=999_999 lalu di-pad, supaya tiap PIN — termasuk
/// yang berawalan nol — sama mungkinnya.
pub fn random_pin() -> String {
    let n: u32 = rand::rng().random_range(0..1_000_000);
    format!("{n:06}")
}

pub fn random_token() -> [u8; TOKEN_LEN] {
    let mut t = [0u8; TOKEN_LEN];
    rand::rng().fill(&mut t);
    t
}

/// Pembatas laju percobaan pairing, per client_id.
#[derive(Debug, Default)]
pub struct AttemptLimiter {
    entries: HashMap<String, Attempt>,
}

#[derive(Debug, Clone, Copy)]
struct Attempt {
    count: u8,
    first: Instant,
    blocked_until: Option<Instant>,
}

impl AttemptLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apakah client ini sedang diblokir?
    pub fn blocked(&self, client_id: &str) -> bool {
        self.entries
            .get(client_id)
            .and_then(|a| a.blocked_until)
            .is_some_and(|until| Instant::now() < until)
    }

    /// Catat satu percobaan gagal. Mengembalikan true kalau client jadi diblokir.
    pub fn record_failure(&mut self, client_id: &str) -> bool {
        let now = Instant::now();
        let entry = self.entries.entry(client_id.to_string()).or_insert(Attempt {
            count: 0,
            first: now,
            blocked_until: None,
        });

        // Jendela 10 menit: percobaan lama tidak ikut dihitung.
        if now.duration_since(entry.first) > Duration::from_secs(600) {
            entry.count = 0;
            entry.first = now;
            entry.blocked_until = None;
        }

        entry.count = entry.count.saturating_add(1);
        if entry.count >= MAX_ATTEMPTS {
            entry.blocked_until = Some(now + THROTTLE);
            return true;
        }
        false
    }

    /// Pairing sukses — bersihkan hitungan.
    pub fn clear(&mut self, client_id: &str) {
        self.entries.remove(client_id);
    }
}

/// Token per device di Credential Manager.
pub struct TokenStore;

impl TokenStore {
    fn entry(client_id: &str) -> Result<keyring::Entry, PairingError> {
        Ok(keyring::Entry::new(KEYRING_SERVICE, client_id)?)
    }

    pub fn save(client_id: &str, token: &[u8; TOKEN_LEN]) -> Result<(), PairingError> {
        Self::entry(client_id)?.set_secret(token)?;
        Ok(())
    }

    /// Ambil token. `Ok(None)` kalau device belum pernah dipasangkan.
    pub fn load(client_id: &str) -> Result<Option<[u8; TOKEN_LEN]>, PairingError> {
        match Self::entry(client_id)?.get_secret() {
            Ok(bytes) if bytes.len() == TOKEN_LEN => {
                let mut t = [0u8; TOKEN_LEN];
                t.copy_from_slice(&bytes);
                Ok(Some(t))
            }
            // Panjang tidak wajar = entri rusak; perlakukan seperti belum dipasangkan
            // supaya user bisa pairing ulang alih-alih mentok.
            Ok(bytes) => {
                tracing::warn!(
                    "token {client_id} panjangnya {} byte, harusnya {TOKEN_LEN} — diabaikan",
                    bytes.len()
                );
                Ok(None)
            }
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn delete(client_id: &str) -> Result<(), PairingError> {
        match Self::entry(client_id)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_selalu_enam_digit() {
        for _ in 0..200 {
            let p = random_pin();
            assert_eq!(p.len(), 6);
            assert!(p.chars().all(|c| c.is_ascii_digit()));
        }
    }

    #[test]
    fn token_tidak_berulang() {
        assert_ne!(random_token(), random_token());
    }

    #[test]
    fn sesi_baru_belum_kedaluwarsa() {
        let s = PairingSession::new();
        assert!(!s.expired());
        assert!(s.remaining() <= PIN_TTL);
    }

    #[test]
    fn limiter_blokir_setelah_batas() {
        let mut l = AttemptLimiter::new();
        for i in 1..MAX_ATTEMPTS {
            assert!(!l.record_failure("c1"), "percobaan ke-{i} belum boleh memblokir");
            assert!(!l.blocked("c1"));
        }
        assert!(l.record_failure("c1"));
        assert!(l.blocked("c1"));
    }

    #[test]
    fn limiter_terpisah_per_client() {
        let mut l = AttemptLimiter::new();
        for _ in 0..MAX_ATTEMPTS {
            l.record_failure("c1");
        }
        assert!(l.blocked("c1"));
        assert!(!l.blocked("c2"));
    }

    #[test]
    fn sukses_menghapus_hitungan() {
        let mut l = AttemptLimiter::new();
        l.record_failure("c1");
        l.record_failure("c1");
        l.clear("c1");
        assert!(!l.blocked("c1"));
        for i in 1..MAX_ATTEMPTS {
            assert!(!l.record_failure("c1"), "hitungan harusnya mulai dari nol (ke-{i})");
        }
    }
}
