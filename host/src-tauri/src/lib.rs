//! Decky Host — pintu masuk aplikasi Tauri.

pub mod actions;
pub mod config;
pub mod net;
pub mod pairing;
pub mod proto_gen;
pub mod state;

use std::sync::Arc;
use tauri::{Emitter, Manager};
use tokio::sync::watch;

use config::HostConfig;
use net::mdns::Advertiser;
use pairing::TokenStore;
use state::{AppCtx, Connection};

/// Dipegang Tauri sebagai managed state.
struct Runtime {
    ctx: Arc<AppCtx>,
    /// Kirim `true` untuk menghentikan server.
    shutdown: watch::Sender<bool>,
    /// Disimpan supaya service mDNS tetap hidup selama app jalan.
    _advertiser: Option<Advertiser>,
}

#[derive(serde::Serialize)]
struct HostStatus {
    host_name: String,
    host_id: String,
    port: u16,
    pairing_pin: Option<String>,
    pairing_secs_left: Option<u64>,
    connections: Vec<Connection>,
    devices: Vec<config::PairedDevice>,
}

#[tauri::command]
fn status(rt: tauri::State<'_, Runtime>) -> HostStatus {
    let session = rt.ctx.active_pairing();
    rt.ctx.with_cfg(|cfg| HostStatus {
        host_name: cfg.host_name.clone(),
        host_id: cfg.host_id.clone(),
        port: cfg.port,
        pairing_pin: session.as_ref().map(|s| s.pin.clone()),
        pairing_secs_left: session.as_ref().map(|s| s.remaining().as_secs()),
        connections: rt.ctx.connections(),
        devices: cfg.devices.clone(),
    })
}

#[tauri::command]
fn start_pairing(rt: tauri::State<'_, Runtime>) -> String {
    rt.ctx.start_pairing().pin
}

#[tauri::command]
fn stop_pairing(rt: tauri::State<'_, Runtime>) {
    rt.ctx.stop_pairing();
}

#[tauri::command]
fn forget_device(rt: tauri::State<'_, Runtime>, client_id: String) -> Result<(), String> {
    // Token dihapus duluan: kalau langkah kedua gagal, yang tersisa cuma
    // entri tampilan yatim, bukan kredensial yang masih bisa dipakai.
    TokenStore::delete(&client_id).map_err(|e| e.to_string())?;
    rt.ctx
        .update_cfg(|c| c.remove_device(&client_id))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn deck_config(rt: tauri::State<'_, Runtime>) -> actions::DeckConfig {
    rt.ctx.with_cfg(|c| c.deck.clone())
}

#[tauri::command]
fn set_deck_config(
    rt: tauri::State<'_, Runtime>,
    deck: actions::DeckConfig,
) -> Result<(), String> {
    rt.ctx
        .update_cfg(|c| c.deck = deck)
        .map_err(|e| e.to_string())?;
    // Dorong layout baru ke HP yang sedang terhubung, jangan tunggu mereka
    // menyambung ulang.
    rt.ctx.emit(state::UiEvent::DeckChanged);
    Ok(())
}

#[tauri::command]
fn obs_settings(rt: tauri::State<'_, Runtime>) -> actions::obs::ObsSettings {
    rt.ctx.with_cfg(|c| c.obs.clone())
}

#[tauri::command]
async fn set_obs_settings(
    rt: tauri::State<'_, Runtime>,
    settings: actions::obs::ObsSettings,
) -> Result<(), String> {
    rt.ctx
        .update_cfg(|c| c.obs = settings.clone())
        .map_err(|e| e.to_string())?;
    rt.ctx.obs.configure(settings).await;
    Ok(())
}

/// Coba sambung ke OBS sekarang, untuk tombol "Tes koneksi" di UI.
#[tauri::command]
async fn obs_probe(rt: tauri::State<'_, Runtime>) -> Result<String, String> {
    rt.ctx.obs.current_scene().await
}

#[tauri::command]
fn set_host_name(rt: tauri::State<'_, Runtime>, name: String) -> Result<(), String> {
    let name = name.trim().to_string();
    if name.is_empty() {
        return Err("nama host tidak boleh kosong".into());
    }
    rt.ctx
        .update_cfg(|c| c.host_name = name)
        .map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("DECKY_LOG")
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let cfg_dir = app.path().app_config_dir()?;
            let cfg = HostConfig::load_or_init(&cfg_dir)?;
            tracing::info!("config dimuat dari {}", cfg_dir.display());

            let advertiser =
                match Advertiser::start(&cfg.host_id, &cfg.host_name, cfg.port, "windows") {
                    Ok(a) => Some(a),
                    Err(e) => {
                        // mDNS gagal bukan alasan untuk tidak jalan — user masih
                        // bisa konek dengan mengetik IP.
                        tracing::error!("mDNS tidak aktif: {e}");
                        None
                    }
                };

            let ctx = Arc::new(AppCtx::new(cfg_dir, cfg));
            let (shutdown, shutdown_rx) = watch::channel(false);

            // Teruskan event dari lapisan jaringan ke frontend.
            let mut events = ctx.subscribe();
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                while let Ok(ev) = events.recv().await {
                    if let Err(e) = handle.emit("decky://event", &ev) {
                        tracing::warn!("gagal mengirim event ke UI: {e}");
                    }
                }
            });

            let server_ctx = ctx.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = net::server::run(server_ctx.clone(), shutdown_rx).await {
                    tracing::error!("server berhenti karena error: {e}");
                    server_ctx.emit(state::UiEvent::ServerError { msg: e.to_string() });
                }
            });

            app.manage(Runtime {
                ctx,
                shutdown,
                _advertiser: advertiser,
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            status,
            start_pairing,
            stop_pairing,
            forget_device,
            set_host_name,
            deck_config,
            set_deck_config,
            obs_settings,
            set_obs_settings,
            obs_probe
        ])
        .build(tauri::generate_context!())
        .expect("gagal membangun aplikasi Tauri")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                if let Some(rt) = app.try_state::<Runtime>() {
                    let _ = rt.shutdown.send(true);
                }
            }
        });
}
