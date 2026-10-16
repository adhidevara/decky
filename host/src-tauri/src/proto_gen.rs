// DIBUAT OTOMATIS oleh protocol/codegen/generate.mjs — JANGAN DIEDIT.
// Sumber: protocol/schema/decky-v1.json (protokol v1)
// Regenerate: node protocol/codegen/generate.mjs

#![allow(dead_code, clippy::all)]

use serde::{Deserialize, Serialize};

/// MessageType
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MessageType {
    #[serde(rename = "ping")]
    Ping,
    #[serde(rename = "pong")]
    Pong,
    #[serde(rename = "error")]
    Error,
    #[serde(rename = "welcome")]
    Welcome,
    #[serde(rename = "deck_layout")]
    DeckLayout,
    #[serde(rename = "deck_state")]
    DeckState,
    #[serde(rename = "deck_profiles")]
    DeckProfiles,
    #[serde(rename = "monitor_tick")]
    MonitorTick,
    #[serde(rename = "media_state")]
    MediaState,
    #[serde(rename = "lyrics")]
    Lyrics,
    #[serde(rename = "blob")]
    Blob,
    #[serde(rename = "deck_press")]
    DeckPress,
    #[serde(rename = "deck_release")]
    DeckRelease,
    #[serde(rename = "deck_switch_profile")]
    DeckSwitchProfile,
    #[serde(rename = "pointer_move")]
    PointerMove,
    #[serde(rename = "pointer_button")]
    PointerButton,
    #[serde(rename = "scroll")]
    Scroll,
    #[serde(rename = "key")]
    Key,
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "monitor_sub")]
    MonitorSub,
    #[serde(rename = "monitor_unsub")]
    MonitorUnsub,
    #[serde(rename = "media_cmd")]
    MediaCmd,
    #[serde(rename = "want_blob")]
    WantBlob,
}

/// Capability
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Capability {
    #[serde(rename = "deck")]
    Deck,
    #[serde(rename = "input")]
    Input,
    #[serde(rename = "monitor")]
    Monitor,
    #[serde(rename = "monitor.cpu_temp")]
    MonitorCpuTemp,
    #[serde(rename = "monitor.gpu")]
    MonitorGpu,
    #[serde(rename = "monitor.gpu_temp")]
    MonitorGpuTemp,
    #[serde(rename = "media")]
    Media,
    #[serde(rename = "media.seek")]
    MediaSeek,
    #[serde(rename = "lyrics")]
    Lyrics,
    #[serde(rename = "obs")]
    Obs,
}

/// ErrorCode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ErrorCode {
    #[serde(rename = "proto_version")]
    ProtoVersion,
    #[serde(rename = "auth_failed")]
    AuthFailed,
    #[serde(rename = "pair_expired")]
    PairExpired,
    #[serde(rename = "pair_throttled")]
    PairThrottled,
    #[serde(rename = "unknown_action")]
    UnknownAction,
    #[serde(rename = "action_failed")]
    ActionFailed,
    #[serde(rename = "cap_missing")]
    CapMissing,
    #[serde(rename = "internal")]
    Internal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HelloMode {
    #[serde(rename = "pair")]
    Pair,
    #[serde(rename = "session")]
    Session,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HelloPlatform {
    #[serde(rename = "android")]
    Android,
    #[serde(rename = "ios")]
    Ios,
    #[serde(rename = "web")]
    Web,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum WelcomeOs {
    #[serde(rename = "windows")]
    Windows,
    #[serde(rename = "macos")]
    Macos,
    #[serde(rename = "linux")]
    Linux,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ButtonStyle {
    #[serde(rename = "normal")]
    Normal,
    #[serde(rename = "toggle")]
    Toggle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LyricsSource {
    #[serde(rename = "lrc_file")]
    LrcFile,
    #[serde(rename = "cache")]
    Cache,
    #[serde(rename = "online")]
    Online,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlobMime {
    #[serde(rename = "image/png")]
    ImagePng,
    #[serde(rename = "image/jpeg")]
    ImageJpeg,
    #[serde(rename = "image/webp")]
    ImageWebp,
    #[serde(rename = "image/svg+xml")]
    ImageSvgXml,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MonitorSubWantItem {
    #[serde(rename = "cpu")]
    Cpu,
    #[serde(rename = "cpu_per_core")]
    CpuPerCore,
    #[serde(rename = "mem")]
    Mem,
    #[serde(rename = "net")]
    Net,
    #[serde(rename = "disk")]
    Disk,
    #[serde(rename = "gpu")]
    Gpu,
    #[serde(rename = "temp")]
    Temp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MediaCmdCmd {
    #[serde(rename = "toggle")]
    Toggle,
    #[serde(rename = "play")]
    Play,
    #[serde(rename = "pause")]
    Pause,
    #[serde(rename = "next")]
    Next,
    #[serde(rename = "prev")]
    Prev,
    #[serde(rename = "seek")]
    Seek,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    /// versi protokol
    pub v: i64,
    pub t: MessageType,
    /// hanya untuk pola request/response
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u32>,
    /// payload, bentuknya ditentukan oleh t
    pub d: serde_json::Value,
}

/// Frame plaintext pertama dari client, SEBELUM handshake Noise.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hello {
    pub v: i64,
    pub mode: HelloMode,
    pub client_id: String,
    /// nama device untuk ditampilkan di host
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<HelloPlatform>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
}

/// Balasan plaintext host atas Hello.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelloAck {
    pub v: i64,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noise: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<ErrorCode>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Ping {
    /// monotonic ms pengirim
    pub ts: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Error {
    pub code: ErrorCode,
    pub msg: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Welcome {
    pub host_name: String,
    pub os: WelcomeOs,
    pub host_id: String,
    pub proto: i64,
    pub caps: Vec<Capability>,
    /// token pairing 32 byte; HANYA dikirim sekali, pada koneksi mode=pair yang sukses
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(with = "serde_bytes")]
    pub token: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Button {
    pub idx: u16,
    pub label: String,
    /// blob_id ikon; client cache by id
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub style: Option<ButtonStyle>,
    /// teks deskriptif untuk aksesibilitas; BUKAN definisi aksi
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeckLayout {
    pub profile_id: String,
    pub name: String,
    pub cols: u8,
    pub rows: u8,
    pub buttons: Vec<Button>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeckState {
    pub idx: u16,
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeckProfiles {
    pub profiles: Vec<serde_json::Value>,
    pub active: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Gpu {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub util: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mem_used: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mem_total: Option<u64>,
    /// derajat Celsius
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temp: Option<f32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MonitorTick {
    pub ts: i64,
    pub cpu: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_per_core: Option<Vec<f32>>,
    pub mem_used: u64,
    pub mem_total: u64,
    /// byte/detik sejak tick sebelumnya
    pub net_rx: u64,
    pub net_tx: u64,
    pub disk_r: u64,
    pub disk_w: u64,
    /// hanya ada kalau cap monitor.cpu_temp diumumkan
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_temp: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu: Option<Gpu>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaState {
    pub playing: bool,
    pub title: String,
    pub artist: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    pub duration_ms: u64,
    pub position_ms: u64,
    /// monotonic host ms saat position_ms diambil; client ekstrapolasi dari sini
    pub pos_at: i64,
    /// blob_id album art
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub art_id: Option<String>,
    /// aplikasi sumber, mis. Spotify
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Lyrics {
    /// hash artist+title; client buang lirik kalau track_key tidak cocok dengan media_state
    pub track_key: String,
    pub source: LyricsSource,
    pub lines: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Blob {
    /// hash konten; stabil, jadi client bisa cache permanen
    pub blob_id: String,
    pub mime: BlobMime,
    /// byte mentah di MessagePack, base64 hanya saat direpresentasikan sebagai JSON
    #[serde(with = "serde_bytes")]
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeckPress {
    pub idx: u16,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeckSwitchProfile {
    pub profile_id: String,
}

/// Delta relatif yang sudah di-coalesce. TIDAK PERNAH koordinat absolut.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PointerMove {
    /// pasangan [dx, dy]
    pub e: Vec<Vec<i16>>,
    /// ms sejak batch sebelumnya; dipakai host untuk kurva akselerasi
    pub dt: u16,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PointerButton {
    /// 0 kiri, 1 tengah, 2 kanan
    pub btn: i64,
    pub down: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Scroll {
    pub dx: i16,
    pub dy: i16,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Key {
    /// nama W3C KeyboardEvent.code, mis. KeyA, Enter, ArrowLeft, F5
    pub code: String,
    pub down: bool,
    /// bitmask: 1 Shift, 2 Ctrl, 4 Alt, 8 Meta
    pub mods: u8,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Text {
    pub s: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MonitorSub {
    pub interval_ms: u16,
    /// host kirim hanya yang diminta, untuk hemat bandwidth dan baterai
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub want: Option<Vec<MonitorSubWantItem>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MonitorUnsub {
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaCmd {
    pub cmd: MediaCmdCmd,
    /// posisi target dalam ms, hanya untuk seek
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arg: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WantBlob {
    pub blob_id: String,
}

/// Payload yang sah untuk HostMsg, di-tag oleh field `t` di envelope.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", content = "d")]
pub enum HostMsg {
    #[serde(rename = "ping")]
    Ping(Ping),
    #[serde(rename = "pong")]
    Pong(Ping),
    #[serde(rename = "error")]
    Error(Error),
    #[serde(rename = "welcome")]
    Welcome(Welcome),
    #[serde(rename = "deck_layout")]
    DeckLayout(DeckLayout),
    #[serde(rename = "deck_state")]
    DeckState(DeckState),
    #[serde(rename = "deck_profiles")]
    DeckProfiles(DeckProfiles),
    #[serde(rename = "monitor_tick")]
    MonitorTick(MonitorTick),
    #[serde(rename = "media_state")]
    MediaState(MediaState),
    #[serde(rename = "lyrics")]
    Lyrics(Lyrics),
    #[serde(rename = "blob")]
    Blob(Blob),
}

/// Payload yang sah untuk ClientMsg, di-tag oleh field `t` di envelope.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", content = "d")]
pub enum ClientMsg {
    #[serde(rename = "ping")]
    Ping(Ping),
    #[serde(rename = "pong")]
    Pong(Ping),
    #[serde(rename = "error")]
    Error(Error),
    #[serde(rename = "deck_press")]
    DeckPress(DeckPress),
    #[serde(rename = "deck_release")]
    DeckRelease(DeckPress),
    #[serde(rename = "deck_switch_profile")]
    DeckSwitchProfile(DeckSwitchProfile),
    #[serde(rename = "pointer_move")]
    PointerMove(PointerMove),
    #[serde(rename = "pointer_button")]
    PointerButton(PointerButton),
    #[serde(rename = "scroll")]
    Scroll(Scroll),
    #[serde(rename = "key")]
    Key(Key),
    #[serde(rename = "text")]
    Text(Text),
    #[serde(rename = "monitor_sub")]
    MonitorSub(MonitorSub),
    #[serde(rename = "monitor_unsub")]
    MonitorUnsub(MonitorUnsub),
    #[serde(rename = "media_cmd")]
    MediaCmd(MediaCmd),
    #[serde(rename = "want_blob")]
    WantBlob(WantBlob),
}

pub const PROTOCOL_VERSION: u8 = 1;
pub const DEFAULT_PORT: u16 = 8787;
pub const ALL_MESSAGE_TYPES: [&str; 23] = ["ping", "pong", "error", "welcome", "deck_layout", "deck_state", "deck_profiles", "monitor_tick", "media_state", "lyrics", "blob", "deck_press", "deck_release", "deck_switch_profile", "pointer_move", "pointer_button", "scroll", "key", "text", "monitor_sub", "monitor_unsub", "media_cmd", "want_blob"];
