//! Penyimpanan ikon tombol dan album art, dialamatkan oleh isi berkasnya.
//!
//! `blob_id` adalah hash dari isinya, jadi dua tombol dengan ikon sama memakai
//! satu berkas, dan client bisa meng-cache selamanya: id yang sama selalu
//! berarti byte yang sama.

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Batas ukuran satu ikon. Ikon deck ditampilkan sekitar 100 px di HP; apa pun
/// yang lebih besar dari ini pasti foto yang keliru dipilih.
pub const MAX_BLOB: usize = 512 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum BlobError {
    #[error("tipe berkas tidak didukung: {0}")]
    UnsupportedType(String),
    #[error("berkas terlalu besar: {0} byte, batasnya {MAX_BLOB}")]
    TooLarge(usize),
    #[error("blob {0} tidak ada")]
    NotFound(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Tipe gambar yang boleh disimpan, dipetakan ke ekstensi berkasnya.
///
/// Daftar putih, bukan daftar hitam: client hanya tahu cara menggambar empat
/// ini, dan menyimpan tipe lain hanya akan jadi ikon rusak di HP.
fn extension_for(mime: &str) -> Option<&'static str> {
    match mime {
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/webp" => Some("webp"),
        "image/svg+xml" => Some("svg"),
        _ => None,
    }
}

fn mime_for(extension: &str) -> Option<&'static str> {
    match extension {
        "png" => Some("image/png"),
        "jpg" => Some("image/jpeg"),
        "webp" => Some("image/webp"),
        "svg" => Some("image/svg+xml"),
        _ => None,
    }
}

pub struct BlobStore {
    dir: PathBuf,
}

impl BlobStore {
    pub fn new(config_dir: &Path) -> Self {
        Self {
            dir: config_dir.join("blobs"),
        }
    }

    /// Simpan satu blob, kembalikan id-nya.
    ///
    /// Menyimpan isi yang sudah ada bukan error — id-nya sama, dan berkasnya
    /// memang sudah benar.
    pub fn save(&self, mime: &str, bytes: &[u8]) -> Result<String, BlobError> {
        let ext = extension_for(mime).ok_or_else(|| BlobError::UnsupportedType(mime.into()))?;
        if bytes.len() > MAX_BLOB {
            return Err(BlobError::TooLarge(bytes.len()));
        }

        let id = blob_id(bytes);
        std::fs::create_dir_all(&self.dir)?;
        let path = self.dir.join(format!("{id}.{ext}"));
        if !path.exists() {
            std::fs::write(&path, bytes)?;
        }
        Ok(id)
    }

    /// Ambil blob beserta tipe isinya.
    pub fn load(&self, id: &str) -> Result<(String, Vec<u8>), BlobError> {
        // id dipakai untuk menyusun nama berkas, jadi harus divalidasi dulu:
        // tanpa ini `../../` dari client bisa membaca berkas mana pun.
        if !is_valid_id(id) {
            return Err(BlobError::NotFound(id.to_string()));
        }

        for entry in std::fs::read_dir(&self.dir).or(Err(BlobError::NotFound(id.to_string())))? {
            let path = entry?.path();
            let matches_id = path.file_stem().and_then(|s| s.to_str()) == Some(id);
            if !matches_id {
                continue;
            }
            let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
            let Some(mime) = mime_for(ext) else { continue };
            return Ok((mime.to_string(), std::fs::read(&path)?));
        }
        Err(BlobError::NotFound(id.to_string()))
    }

    /// Hapus blob yang tidak lagi dirujuk tombol mana pun.
    pub fn collect_garbage(&self, in_use: &[String]) -> std::io::Result<usize> {
        if !self.dir.exists() {
            return Ok(0);
        }
        let mut removed = 0;
        for entry in std::fs::read_dir(&self.dir)? {
            let path = entry?.path();
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if !in_use.iter().any(|id| id == stem) {
                std::fs::remove_file(&path)?;
                removed += 1;
            }
        }
        Ok(removed)
    }
}

/// 128 bit pertama SHA-256, dalam hex.
///
/// Setengah hash sudah jauh melampaui kebutuhan: ini pengalamatan isi untuk
/// cache lokal, bukan tanda tangan, dan 32 karakter lebih enak dibaca di log.
pub fn blob_id(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest[..16].iter().map(|b| format!("{b:02x}")).collect()
}

fn is_valid_id(id: &str) -> bool {
    id.len() == 32 && id.chars().all(|c| c.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (BlobStore, tempdir::TempDir) {
        let dir = tempdir::TempDir::new();
        (BlobStore::new(dir.path()), dir)
    }

    /// Direktori sementara kecil, supaya test tidak meninggalkan sampah.
    mod tempdir {
        pub struct TempDir(std::path::PathBuf);

        impl TempDir {
            pub fn new() -> Self {
                let p = std::env::temp_dir().join(format!("decky-blob-{}", uuid::Uuid::new_v4()));
                std::fs::create_dir_all(&p).unwrap();
                Self(p)
            }
            pub fn path(&self) -> &std::path::Path {
                &self.0
            }
        }

        impl Drop for TempDir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    #[test]
    fn simpan_lalu_ambil_lagi() {
        let (s, _d) = store();
        let id = s.save("image/png", b"isi-png-palsu").unwrap();
        let (mime, bytes) = s.load(&id).unwrap();
        assert_eq!(mime, "image/png");
        assert_eq!(bytes, b"isi-png-palsu");
    }

    #[test]
    fn isi_sama_menghasilkan_id_sama() {
        let (s, _d) = store();
        let a = s.save("image/png", b"sama").unwrap();
        let b = s.save("image/png", b"sama").unwrap();
        assert_eq!(a, b);
        assert_ne!(a, s.save("image/png", b"beda").unwrap());
    }

    #[test]
    fn tipe_tidak_didukung_ditolak() {
        let (s, _d) = store();
        let err = s.save("application/zip", b"PK").unwrap_err();
        assert!(matches!(err, BlobError::UnsupportedType(t) if t == "application/zip"));
    }

    #[test]
    fn berkas_terlalu_besar_ditolak() {
        let (s, _d) = store();
        let big = vec![0u8; MAX_BLOB + 1];
        assert!(matches!(
            s.save("image/png", &big).unwrap_err(),
            BlobError::TooLarge(_)
        ));
        assert!(s.save("image/png", &vec![0u8; MAX_BLOB]).is_ok());
    }

    #[test]
    fn id_berbentuk_aneh_tidak_bisa_keluar_dari_folder() {
        let (s, _d) = store();
        for jahat in ["../../config", "..", "a/b", "", &"z".repeat(32)] {
            assert!(
                matches!(s.load(jahat), Err(BlobError::NotFound(_))),
                "id {jahat:?} harusnya ditolak"
            );
        }
    }

    #[test]
    fn id_tidak_dikenal_jadi_not_found() {
        let (s, _d) = store();
        s.save("image/png", b"apa saja").unwrap();
        assert!(matches!(
            s.load(&"0".repeat(32)),
            Err(BlobError::NotFound(_))
        ));
    }

    #[test]
    fn garbage_collection_hanya_membuang_yang_tidak_dipakai() {
        let (s, _d) = store();
        let dipakai = s.save("image/png", b"dipakai").unwrap();
        let yatim = s.save("image/png", b"yatim").unwrap();

        assert_eq!(s.collect_garbage(&[dipakai.clone()]).unwrap(), 1);
        assert!(s.load(&dipakai).is_ok());
        assert!(s.load(&yatim).is_err());
    }

    #[test]
    fn id_panjangnya_32_hex() {
        let id = blob_id(b"apa pun");
        assert_eq!(id.len(), 32);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
