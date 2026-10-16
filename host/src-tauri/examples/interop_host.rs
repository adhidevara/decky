//! Server Decky tanpa GUI, untuk uji interop dengan client Dart.
//!
//! ```text
//! cargo run --example interop_host -- --pin 123456 --port 8787
//! ```
//!
//! Mencetak `HOST_ID=<uuid>` dan `READY` ke stdout supaya proses penguji tahu
//! kapan boleh menyambung. Config ditulis ke direktori sementara, jadi
//! menjalankan ini tidak menyentuh config Decky milik user.

use std::sync::Arc;

use decky_host_lib::config::HostConfig;
use decky_host_lib::pairing::{PairingSession, TokenStore};
use decky_host_lib::state::AppCtx;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("DECKY_LOG").unwrap_or_else(|_| "info".into()),
        )
        .init();

    let mut pin = "123456".to_string();
    let mut port: u16 = 8787;
    let mut client_to_reset: Option<String> = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--pin" => pin = args.next().unwrap_or(pin),
            "--port" => port = args.next().and_then(|v| v.parse().ok()).unwrap_or(port),
            // Hapus token sisa dari run sebelumnya supaya tes selalu mulai
            // dari keadaan belum-dipasangkan.
            "--reset-client" => client_to_reset = args.next(),
            other => anyhow::bail!("argumen tidak dikenal: {other}"),
        }
    }

    if let Some(ref client_id) = client_to_reset {
        TokenStore::delete(client_id)?;
    }

    let cfg_dir = std::env::temp_dir().join(format!("decky-interop-{}", uuid::Uuid::new_v4()));
    let mut cfg = HostConfig::default();
    cfg.port = port;
    cfg.host_name = "Decky Interop".to_string();
    let host_id = cfg.host_id.clone();

    let ctx = Arc::new(AppCtx::new(cfg_dir.clone(), cfg));
    ctx.start_pairing_with(PairingSession::with_pin(pin.clone()));

    let (_shutdown, shutdown_rx) = tokio::sync::watch::channel(false);
    let server_ctx = ctx.clone();
    tokio::spawn(async move {
        if let Err(e) = decky_host_lib::net::server::run(server_ctx, shutdown_rx).await {
            eprintln!("server berhenti: {e}");
            std::process::exit(1);
        }
    });

    // Beri listener waktu untuk bind sebelum mengaku siap.
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    println!("HOST_ID={host_id}");
    println!("PIN={pin}");
    println!("PORT={port}");
    println!("READY");

    // Jalan sampai proses penguji membunuhnya. Sengaja tidak memakai
    // tokio::signal supaya crate utama tidak perlu fitur tambahan hanya
    // untuk contoh ini.
    std::future::pending::<()>().await;
    let _ = std::fs::remove_dir_all(&cfg_dir);
    Ok(())
}
