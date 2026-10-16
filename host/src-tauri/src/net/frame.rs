//! Serialisasi MessagePack + chunking di atas Noise.
//!
//! Satu pesan Noise maksimal 65535 byte termasuk tag 16 byte, jadi plaintext
//! efektif maksimal 65519 byte. Payload yang lebih besar (ikon, album art)
//! dipecah di sini supaya lapisan aplikasi tidak perlu tahu batas itu.
//!
//! Format tiap chunk sebelum dienkripsi:
//!
//! ```text
//! [u8 flag][payload…]      flag: 0 = chunk terakhir, 1 = masih ada lanjutan
//! ```

use serde::{Serialize, de::DeserializeOwned};

/// Plaintext maksimal per pesan Noise, dikurangi 1 byte flag kita.
pub const MAX_CHUNK: usize = 65519 - 1;

/// Batas atas pesan yang sudah dirakit, untuk mencegah client jahat
/// membuat host kehabisan memori.
pub const MAX_MESSAGE: usize = 8 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("encode messagepack gagal: {0}")]
    Encode(#[from] rmp_serde::encode::Error),
    #[error("decode messagepack gagal: {0}")]
    Decode(#[from] rmp_serde::decode::Error),
    #[error("chunk kosong")]
    EmptyChunk,
    #[error("pesan melebihi batas {MAX_MESSAGE} byte")]
    TooLarge,
}

/// Encode nilai jadi MessagePack dengan nama field (map, bukan array).
///
/// Harus `_named` — client Dart membaca berdasarkan nama field, dan skema
/// mengizinkan field opsional hilang.
pub fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, FrameError> {
    Ok(rmp_serde::to_vec_named(value)?)
}

pub fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, FrameError> {
    Ok(rmp_serde::from_slice(bytes)?)
}

/// Pecah payload jadi chunk siap-enkripsi, masing-masing dengan byte flag.
pub fn split(payload: &[u8]) -> Vec<Vec<u8>> {
    if payload.is_empty() {
        return vec![vec![0u8]];
    }
    let total = payload.len().div_ceil(MAX_CHUNK);
    payload
        .chunks(MAX_CHUNK)
        .enumerate()
        .map(|(i, part)| {
            let mut buf = Vec::with_capacity(part.len() + 1);
            buf.push(if i + 1 == total { 0u8 } else { 1u8 });
            buf.extend_from_slice(part);
            buf
        })
        .collect()
}

/// Merakit ulang chunk yang datang berurutan jadi pesan utuh.
#[derive(Debug, Default)]
pub struct Reassembler {
    buf: Vec<u8>,
}

impl Reassembler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Suapkan satu chunk hasil dekripsi.
    ///
    /// Mengembalikan `Some(pesan)` saat chunk terakhir diterima, `None` kalau
    /// masih menunggu lanjutan.
    pub fn push(&mut self, chunk: &[u8]) -> Result<Option<Vec<u8>>, FrameError> {
        let (&flag, rest) = chunk.split_first().ok_or(FrameError::EmptyChunk)?;
        if self.buf.len() + rest.len() > MAX_MESSAGE {
            self.buf.clear();
            return Err(FrameError::TooLarge);
        }
        self.buf.extend_from_slice(rest);
        if flag == 0 {
            Ok(Some(std::mem::take(&mut self.buf)))
        } else {
            Ok(None)
        }
    }

    /// Buang state parsial, dipakai saat koneksi di-reset.
    pub fn reset(&mut self) {
        self.buf.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(payload: &[u8]) -> Vec<u8> {
        let mut r = Reassembler::new();
        let mut out = None;
        for chunk in split(payload) {
            assert!(out.is_none(), "chunk muncul setelah pesan selesai");
            out = r.push(&chunk).unwrap();
        }
        out.expect("pesan tidak pernah selesai")
    }

    #[test]
    fn chunk_tunggal_bolak_balik() {
        let payload = b"halo decky".to_vec();
        assert_eq!(roundtrip(&payload), payload);
    }

    #[test]
    fn payload_kosong_tetap_satu_chunk() {
        assert_eq!(split(b"").len(), 1);
        assert_eq!(roundtrip(b""), Vec::<u8>::new());
    }

    #[test]
    fn payload_besar_dipecah_dan_dirakit_lagi() {
        let payload: Vec<u8> = (0..250_000u32).map(|i| (i % 251) as u8).collect();
        let chunks = split(&payload);
        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|c| c.len() <= MAX_CHUNK + 1));
        assert_eq!(roundtrip(&payload), payload);
    }

    #[test]
    fn batas_chunk_persis_tidak_menambah_chunk_kosong() {
        let payload = vec![7u8; MAX_CHUNK];
        assert_eq!(split(&payload).len(), 1);
        assert_eq!(roundtrip(&payload), payload);
    }

    #[test]
    fn chunk_kosong_ditolak() {
        let mut r = Reassembler::new();
        assert!(matches!(r.push(&[]), Err(FrameError::EmptyChunk)));
    }

    #[test]
    fn messagepack_pakai_nama_field() {
        use crate::proto_gen::Ping;
        let bytes = encode(&Ping { ts: 42 }).unwrap();
        // Map dengan satu entri bernama "ts" -> byte pertama 0x81 (fixmap len 1).
        assert_eq!(bytes[0], 0x81);
        assert_eq!(decode::<Ping>(&bytes).unwrap().ts, 42);
    }
}
