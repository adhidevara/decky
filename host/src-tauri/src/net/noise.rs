//! Handshake Noise `NNpsk0` dan derivasi PSK.
//!
//! Dua mode:
//!
//! * **pair** — PSK diturunkan dari PIN yang ditampilkan di layar host.
//!   PIN-nya pendek, jadi keamanannya bersandar pada handshake yang harus
//!   online plus rate limit di [`crate::pairing`], bukan pada entropi PIN.
//! * **session** — PSK adalah token 32 byte yang diterbitkan saat pairing
//!   sukses.

use hkdf::Hkdf;
use sha2::Sha256;
use snow::{HandshakeState, TransportState};

use super::frame::{FrameError, Reassembler, split};

pub const NOISE_PARAMS: &str = "Noise_NNpsk0_25519_ChaChaPoly_SHA256";
pub const TOKEN_LEN: usize = 32;

#[derive(Debug, thiserror::Error)]
pub enum NoiseError {
    #[error("noise: {0}")]
    Snow(#[from] snow::Error),
    #[error(transparent)]
    Frame(#[from] FrameError),
}

/// PSK untuk mode pairing: HKDF-SHA256 atas PIN, di-salt dengan kedua id.
///
/// Salt mengikat handshake ke pasangan host/client tertentu, jadi handshake
/// yang direkam tidak bisa diputar ulang ke host lain.
pub fn psk_from_pin(pin: &str, host_id: &str, client_id: &str) -> [u8; 32] {
    let mut salt = Vec::with_capacity(host_id.len() + client_id.len());
    salt.extend_from_slice(host_id.as_bytes());
    salt.extend_from_slice(client_id.as_bytes());

    let hk = Hkdf::<Sha256>::new(Some(&salt), pin.as_bytes());
    let mut out = [0u8; 32];
    hk.expand(b"decky-pair-v1", &mut out)
        .expect("32 byte selalu muat untuk HKDF-SHA256");
    out
}

/// PSK untuk sesi biasa: token dipakai apa adanya.
pub fn psk_from_token(token: &[u8; TOKEN_LEN]) -> [u8; 32] {
    *token
}

/// Bangun responder (sisi host) dengan PSK yang diberikan.
pub fn responder(psk: &[u8; 32]) -> Result<HandshakeState, NoiseError> {
    Ok(snow::Builder::new(NOISE_PARAMS.parse()?)
        .psk(0, psk)?
        .build_responder()?)
}

/// Bangun initiator. Hanya dipakai di test dan tooling; client sungguhan ada di Dart.
pub fn initiator(psk: &[u8; 32]) -> Result<HandshakeState, NoiseError> {
    Ok(snow::Builder::new(NOISE_PARAMS.parse()?)
        .psk(0, psk)?
        .build_initiator()?)
}

/// Channel terenkripsi yang sudah jadi, plus perakit ulang chunk-nya.
pub struct Channel {
    state: TransportState,
    reasm: Reassembler,
    buf: Vec<u8>,
}

impl Channel {
    pub fn new(state: TransportState) -> Self {
        Self {
            state,
            reasm: Reassembler::new(),
            buf: vec![0u8; 65535],
        }
    }

    /// Enkripsi payload jadi satu atau lebih pesan Noise siap kirim.
    pub fn seal(&mut self, payload: &[u8]) -> Result<Vec<Vec<u8>>, NoiseError> {
        let mut out = Vec::new();
        for chunk in split(payload) {
            let n = self.state.write_message(&chunk, &mut self.buf)?;
            out.push(self.buf[..n].to_vec());
        }
        Ok(out)
    }

    /// Dekripsi satu pesan Noise.
    ///
    /// `Ok(None)` berarti chunk ini bagian dari pesan yang belum lengkap.
    pub fn open(&mut self, ciphertext: &[u8]) -> Result<Option<Vec<u8>>, NoiseError> {
        let n = self.state.read_message(ciphertext, &mut self.buf)?;
        let plain = self.buf[..n].to_vec();
        Ok(self.reasm.push(&plain)?)
    }

    pub fn reset_partial(&mut self) {
        self.reasm.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Jalankan handshake NNpsk0 dua arah, kembalikan channel kedua sisi.
    fn handshake(psk_i: &[u8; 32], psk_r: &[u8; 32]) -> Result<(Channel, Channel), NoiseError> {
        let mut i = initiator(psk_i)?;
        let mut r = responder(psk_r)?;
        let mut b1 = [0u8; 1024];
        let mut b2 = [0u8; 1024];

        let n = i.write_message(&[], &mut b1)?; // -> e, psk
        r.read_message(&b1[..n], &mut b2)?;
        let n = r.write_message(&[], &mut b2)?; // <- e, ee
        i.read_message(&b2[..n], &mut b1)?;

        Ok((
            Channel::new(i.into_transport_mode()?),
            Channel::new(r.into_transport_mode()?),
        ))
    }

    #[test]
    fn psk_cocok_maka_pesan_bolak_balik() {
        let psk = psk_from_pin("123456", "host-a", "client-b");
        let (mut i, mut r) = handshake(&psk, &psk).unwrap();

        let msgs = i.seal(b"halo dari client").unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(r.open(&msgs[0]).unwrap().unwrap(), b"halo dari client");

        let msgs = r.seal(b"balasan host").unwrap();
        assert_eq!(i.open(&msgs[0]).unwrap().unwrap(), b"balasan host");
    }

    #[test]
    fn pin_salah_maka_handshake_gagal() {
        let good = psk_from_pin("123456", "host-a", "client-b");
        let bad = psk_from_pin("654321", "host-a", "client-b");
        assert!(handshake(&bad, &good).is_err());
    }

    #[test]
    fn host_id_beda_maka_psk_beda() {
        let a = psk_from_pin("123456", "host-a", "client-b");
        let b = psk_from_pin("123456", "host-z", "client-b");
        assert_ne!(a, b, "salt harus mengikat PSK ke host tertentu");
    }

    #[test]
    fn payload_besar_terpecah_lalu_utuh_lagi() {
        let psk = psk_from_token(&[9u8; TOKEN_LEN]);
        let (mut i, mut r) = handshake(&psk, &psk).unwrap();

        let big: Vec<u8> = (0..200_000u32).map(|n| (n % 253) as u8).collect();
        let msgs = i.seal(&big).unwrap();
        assert!(msgs.len() > 1);

        let mut got = None;
        for (idx, m) in msgs.iter().enumerate() {
            let res = r.open(m).unwrap();
            if idx + 1 < msgs.len() {
                assert!(res.is_none(), "chunk tengah tidak boleh menyelesaikan pesan");
            } else {
                got = res;
            }
        }
        assert_eq!(got.unwrap(), big);
    }
}
