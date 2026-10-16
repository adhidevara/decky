//! Aksi yang bisa dipicu tombol deck.
//!
//! Catatan keamanan yang disengaja: client **tidak pernah** mengirim definisi
//! aksi, hanya indeks tombol. Apa yang dijalankan sepenuhnya ditentukan oleh
//! konfigurasi di PC. HP yang dibajak paling banter bisa menekan tombol yang
//! sudah ada — tidak bisa membuat tombol baru atau menjalankan perintah
//! sembarangan.

pub mod input;
pub mod keys;
pub mod obs;

use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::proto_gen::{Button, DeckLayout};

#[derive(Debug, thiserror::Error)]
pub enum ActionError {
    #[error(transparent)]
    Input(#[from] input::InputError),
    #[error("gagal menjalankan: {0}")]
    Spawn(#[from] std::io::Error),
    #[error("OBS: {0}")]
    Obs(String),
    #[error("tombol {0} tidak ada di profil aktif")]
    NoSuchButton(u16),
}

/// Apa yang terjadi saat sebuah tombol ditekan.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    /// Jalankan aplikasi.
    LaunchApp {
        path: String,
        #[serde(default)]
        args: Vec<String>,
    },
    /// Buka URL atau file dengan aplikasi bawaannya.
    OpenUrl { url: String },
    /// Tekan kombinasi tombol, mis. `["ControlLeft", "ShiftLeft", "KeyM"]`.
    Hotkey { keys: Vec<String> },
    /// Ketik teks apa adanya.
    Text { text: String },
    /// Satu tombol media, mis. `MediaPlayPause`.
    MediaKey { key: String },
    /// Jalankan perintah shell.
    RunScript {
        command: String,
        #[serde(default)]
        args: Vec<String>,
    },
    /// Ganti scene OBS lewat obs-websocket.
    ObsScene { scene: String },
    /// Tombol kosong — menempati petak tanpa melakukan apa-apa.
    None,
}

impl Default for Action {
    fn default() -> Self {
        Action::None
    }
}

impl Action {
    /// Deskripsi singkat untuk pembaca layar di HP.
    ///
    /// Bukan definisi aksi: client tidak boleh bisa merekonstruksi apa yang
    /// dijalankan dari sini.
    pub fn hint(&self) -> String {
        match self {
            Action::LaunchApp { path, .. } => {
                let name = std::path::Path::new(path)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(path);
                format!("Buka {name}")
            }
            Action::OpenUrl { .. } => "Buka tautan".into(),
            Action::Hotkey { keys } => format!("Tekan {}", keys.join(" + ")),
            Action::Text { .. } => "Ketik teks".into(),
            Action::MediaKey { key } => format!("Media: {key}"),
            Action::RunScript { .. } => "Jalankan perintah".into(),
            Action::ObsScene { scene } => format!("Scene OBS: {scene}"),
            Action::None => "Kosong".into(),
        }
    }
}

/// Satu tombol beserta aksinya. Hanya ada di sisi host.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ButtonDef {
    pub idx: u16,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon_id: Option<String>,
    #[serde(default)]
    pub action: Action,
}

impl ButtonDef {
    /// Bentuk yang dikirim ke client — tanpa definisi aksi.
    pub fn to_wire(&self) -> Button {
        Button {
            idx: self.idx,
            label: self.label.clone(),
            icon_id: self.icon_id.clone(),
            color: self.color.clone(),
            style: None,
            action_hint: Some(self.action.hint()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub cols: u8,
    pub rows: u8,
    #[serde(default)]
    pub buttons: Vec<ButtonDef>,
}

impl Profile {
    pub fn to_wire(&self) -> DeckLayout {
        DeckLayout {
            profile_id: self.id.clone(),
            name: self.name.clone(),
            cols: self.cols,
            rows: self.rows,
            buttons: self.buttons.iter().map(ButtonDef::to_wire).collect(),
        }
    }

    pub fn button(&self, idx: u16) -> Option<&ButtonDef> {
        self.buttons.iter().find(|b| b.idx == idx)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeckConfig {
    pub active: String,
    pub profiles: Vec<Profile>,
}

impl Default for DeckConfig {
    fn default() -> Self {
        // Layout contoh supaya pemakaian pertama tidak disambut grid kosong.
        // Semuanya aman: tidak ada yang menjalankan skrip atau mengubah apa pun.
        let buttons = vec![
            ButtonDef {
                idx: 0,
                label: "Mute".into(),
                color: Some("#dc2626".into()),
                icon_id: None,
                action: Action::MediaKey {
                    key: "AudioVolumeMute".into(),
                },
            },
            ButtonDef {
                idx: 1,
                label: "Play".into(),
                color: None,
                icon_id: None,
                action: Action::MediaKey {
                    key: "MediaPlayPause".into(),
                },
            },
            ButtonDef {
                idx: 2,
                label: "Next".into(),
                color: None,
                icon_id: None,
                action: Action::MediaKey {
                    key: "MediaTrackNext".into(),
                },
            },
            ButtonDef {
                idx: 3,
                label: "Copy".into(),
                color: None,
                icon_id: None,
                action: Action::Hotkey {
                    keys: vec!["ControlLeft".into(), "KeyC".into()],
                },
            },
            ButtonDef {
                idx: 4,
                label: "Paste".into(),
                color: None,
                icon_id: None,
                action: Action::Hotkey {
                    keys: vec!["ControlLeft".into(), "KeyV".into()],
                },
            },
            ButtonDef {
                idx: 5,
                label: "Notepad".into(),
                color: None,
                icon_id: None,
                action: Action::LaunchApp {
                    path: "notepad.exe".into(),
                    args: vec![],
                },
            },
        ];

        Self {
            active: "default".into(),
            profiles: vec![Profile {
                id: "default".into(),
                name: "Utama".into(),
                cols: 3,
                rows: 2,
                buttons,
            }],
        }
    }
}

impl DeckConfig {
    pub fn active_profile(&self) -> Option<&Profile> {
        self.profiles
            .iter()
            .find(|p| p.id == self.active)
            // Profil aktif bisa saja terhapus lewat edit manual; jangan sampai
            // deck jadi kosong total karenanya.
            .or_else(|| self.profiles.first())
    }

    pub fn profile(&self, id: &str) -> Option<&Profile> {
        self.profiles.iter().find(|p| p.id == id)
    }
}

/// Jalankan satu aksi.
///
/// Injeksi input bersifat blocking tapi berlangsung dalam hitungan mikrodetik,
/// jadi dijalankan langsung. Hanya OBS yang perlu `await`.
pub async fn execute(action: &Action, obs: &Arc<obs::ObsClient>) -> Result<(), ActionError> {
    match action {
        Action::Hotkey { keys } => input::hotkey(keys)?,
        Action::MediaKey { key } => input::tap(key)?,
        Action::Text { text } => input::type_text(text)?,

        Action::LaunchApp { path, args } => {
            std::process::Command::new(path).args(args).spawn()?;
        }

        Action::OpenUrl { url } => {
            // `start` adalah builtin cmd, bukan program; argumen kosong di
            // depan adalah judul window, yang wajib ada kalau URL dikutip.
            std::process::Command::new("cmd")
                .args(["/C", "start", "", url])
                .spawn()?;
        }

        Action::RunScript { command, args } => {
            std::process::Command::new(command).args(args).spawn()?;
        }

        Action::ObsScene { scene } => {
            obs.set_scene(scene).await.map_err(ActionError::Obs)?;
        }

        Action::None => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_bawaan_konsisten() {
        let cfg = DeckConfig::default();
        let p = cfg.active_profile().expect("profil aktif harus ada");
        assert_eq!(p.buttons.len() as u16, p.cols as u16 * p.rows as u16);

        let mut seen: Vec<u16> = p.buttons.iter().map(|b| b.idx).collect();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), p.buttons.len(), "indeks tombol harus unik");
        assert!(
            p.buttons.iter().all(|b| b.idx < p.cols as u16 * p.rows as u16),
            "indeks tombol harus muat di grid"
        );
    }

    #[test]
    fn profil_aktif_jatuh_ke_yang_pertama_kalau_id_hilang() {
        let mut cfg = DeckConfig::default();
        cfg.active = "sudah-dihapus".into();
        assert_eq!(cfg.active_profile().map(|p| p.id.as_str()), Some("default"));
    }

    #[test]
    fn bentuk_kawat_tidak_membocorkan_aksi() {
        let def = ButtonDef {
            idx: 0,
            label: "Deploy".into(),
            color: None,
            icon_id: None,
            action: Action::RunScript {
                command: "deploy.sh".into(),
                args: vec!["--prod".into(), "--token=rahasia".into()],
            },
        };
        let wire = def.to_wire();
        let hint = wire.action_hint.unwrap();
        assert!(!hint.contains("rahasia"));
        assert!(!hint.contains("deploy.sh"));
        assert_eq!(hint, "Jalankan perintah");
    }

    #[test]
    fn hint_hotkey_bisa_dibaca_manusia() {
        let a = Action::Hotkey {
            keys: vec!["ControlLeft".into(), "ShiftLeft".into(), "KeyM".into()],
        };
        assert_eq!(a.hint(), "Tekan ControlLeft + ShiftLeft + KeyM");
    }

    #[test]
    fn hint_launch_memakai_nama_file_saja() {
        let a = Action::LaunchApp {
            path: r"C:\Program Files\Obsidian\Obsidian.exe".into(),
            args: vec![],
        };
        assert_eq!(a.hint(), "Buka Obsidian");
    }

    #[test]
    fn aksi_bolak_balik_lewat_json() {
        let cfg = DeckConfig::default();
        let json = serde_json::to_string(&cfg).unwrap();
        let back: DeckConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back.profiles[0].buttons[0].action, cfg.profiles[0].buttons[0].action);
    }

    #[test]
    fn tombol_tanpa_aksi_terbaca_sebagai_none() {
        let def: ButtonDef =
            serde_json::from_str(r#"{"idx":0,"label":"Kosong"}"#).unwrap();
        assert_eq!(def.action, Action::None);
    }
}
