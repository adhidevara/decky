//! Server WebSocket: handshake, pairing, lalu loop pesan terenkripsi.

use futures_util::{SinkExt, StreamExt};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;

use super::frame;
use super::noise::{self, Channel, TOKEN_LEN};
use crate::actions::{self, Action};
use crate::config::{PairedDevice, now_secs};
use crate::pairing::{self, TokenStore};
use crate::actions::ButtonStyle;
use crate::proto_gen::{
    Blob, BlobMime, Capability, ClientMsg, DeckPress, DeckProfiles, DeckState, DeckSwitchProfile,
    ErrorCode, Hello, HelloAck, HelloMode, HostMsg, Ping, Welcome, WantBlob, WelcomeOs,
    PROTOCOL_VERSION,
};
use crate::state::{AppCtx, Connection, UiEvent};
use tokio::sync::broadcast::error::RecvError;

/// Client dianggap mati kalau diam selama ini. Client mengirim ping tiap 5
/// detik, jadi 20 detik memberi ruang tiga ping yang hilang.
const IDLE_TIMEOUT: Duration = Duration::from_secs(20);

/// Batas waktu seluruh handshake, supaya koneksi setengah jadi tidak menumpuk.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

type Ws = WebSocketStream<TcpStream>;

/// Jalankan server sampai `shutdown` berubah jadi true.
pub async fn run(ctx: Arc<AppCtx>, mut shutdown: watch::Receiver<bool>) -> anyhow::Result<()> {
    let port = ctx.port();
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    tracing::info!("server mendengarkan di 0.0.0.0:{port}");

    tokio::spawn(watch_obs_scene(ctx.clone()));

    loop {
        tokio::select! {
            _ = shutdown.changed() => {
                if *shutdown.borrow() {
                    tracing::info!("server berhenti");
                    return Ok(());
                }
            }
            accepted = listener.accept() => {
                let (stream, addr) = match accepted {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::warn!("accept gagal: {e}");
                        continue;
                    }
                };
                // Nagle menahan paket kecil sampai ada ACK — persis pola trafik
                // trackpad. Matikan, kalau tidak pointer terasa tersendat.
                if let Err(e) = stream.set_nodelay(true) {
                    tracing::warn!("set_nodelay gagal untuk {addr}: {e}");
                }
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    if let Err(e) = serve_conn(ctx, stream, addr).await {
                        tracing::debug!("koneksi {addr} selesai: {e}");
                    }
                });
            }
        }
    }
}

/// Pantau scene OBS yang aktif dan siarkan perubahannya.
///
/// obs-websocket punya stream event, tapi polling dua detik jauh lebih
/// sederhana dan tahan terhadap OBS yang ditutup lalu dibuka lagi — kasus yang
/// justru paling sering terjadi. Polling berhenti sendiri saat tidak ada HP
/// yang terhubung atau OBS tidak diaktifkan.
async fn watch_obs_scene(ctx: Arc<AppCtx>) {
    const POLL: Duration = Duration::from_secs(2);
    let mut last: Option<String> = None;

    loop {
        tokio::time::sleep(POLL).await;

        if ctx.connections().is_empty() {
            last = None;
            continue;
        }

        match ctx.obs.current_scene().await {
            Ok(scene) => {
                if last.as_deref() != Some(scene.as_str()) {
                    last = Some(scene.clone());
                    ctx.emit(UiEvent::ObsSceneChanged { scene });
                }
            }
            // OBS tidak jalan atau tidak diaktifkan. Diamkan saja — ini
            // keadaan normal, bukan kesalahan.
            Err(_) => last = None,
        }
    }
}

async fn serve_conn(ctx: Arc<AppCtx>, stream: TcpStream, addr: SocketAddr) -> anyhow::Result<()> {
    let ws = tokio_tungstenite::accept_async(stream).await?;

    let (mut ws, mut chan, hello) =
        match tokio::time::timeout(HANDSHAKE_TIMEOUT, handshake(&ctx, ws, addr)).await {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => return Err(e),
            Err(_) => anyhow::bail!("handshake timeout dari {addr}"),
        };

    let client_id = hello.client_id.clone();
    let conn = Connection {
        client_id: client_id.clone(),
        name: hello.name.clone().unwrap_or_else(|| "Device".into()),
        platform: hello.platform.map(|p| format!("{p:?}").to_lowercase()).unwrap_or_default(),
        addr: addr.to_string(),
        rtt_ms: None,
    };
    ctx.add_conn(conn);

    let result = message_loop(&ctx, &mut ws, &mut chan, &client_id).await;
    ctx.remove_conn(&client_id);
    let _ = ws.close(None).await;
    result
}

/// Hello plaintext → Noise → Welcome. Mengembalikan channel yang sudah aman.
async fn handshake(
    ctx: &Arc<AppCtx>,
    mut ws: Ws,
    addr: SocketAddr,
) -> anyhow::Result<(Ws, Channel, Hello)> {
    let hello: Hello = frame::decode(&read_binary(&mut ws).await?)?;
    let host_id = ctx.host_id();

    if hello.v != PROTOCOL_VERSION as i64 {
        reject(&mut ws, &host_id, ErrorCode::ProtoVersion).await;
        anyhow::bail!("versi protokol {} tidak didukung", hello.v);
    }
    if ctx.limiter_blocked(&hello.client_id) {
        reject(&mut ws, &host_id, ErrorCode::PairThrottled).await;
        anyhow::bail!("client {} sedang di-throttle", hello.client_id);
    }

    // Tentukan PSK sebelum mengaku siap, supaya client yang tidak dikenal
    // ditolak tanpa kita buang waktu di handshake kripto.
    let (psk, pairing_mode) = match hello.mode {
        HelloMode::Pair => {
            let Some(session) = ctx.active_pairing() else {
                reject(&mut ws, &host_id, ErrorCode::PairExpired).await;
                anyhow::bail!("tidak ada sesi pairing aktif");
            };
            (
                noise::psk_from_pin(&session.pin, &host_id, &hello.client_id),
                true,
            )
        }
        HelloMode::Session => match TokenStore::load(&hello.client_id)? {
            Some(token) => (noise::psk_from_token(&token), false),
            None => {
                reject(&mut ws, &host_id, ErrorCode::AuthFailed).await;
                anyhow::bail!("client {} belum dipasangkan", hello.client_id);
            }
        },
    };

    send_binary(
        &mut ws,
        frame::encode(&HelloAck {
            v: PROTOCOL_VERSION as i64,
            ok: true,
            host_id: Some(host_id.clone()),
            noise: Some(noise::NOISE_PARAMS.to_string()),
            code: None,
        })?,
    )
    .await?;

    // Noise NNpsk0: baca `-> e, psk`, balas `<- e, ee`.
    let mut hs = noise::responder(&psk)?;
    let mut buf = vec![0u8; 65535];

    let msg1 = read_binary(&mut ws).await?;
    if hs.read_message(&msg1, &mut buf).is_err() {
        // PSK salah. Untuk mode pairing ini berarti PIN salah.
        if pairing_mode && ctx.record_pair_failure(&hello.client_id) {
            tracing::warn!("client {} diblokir setelah terlalu banyak PIN salah", hello.client_id);
        }
        reject(&mut ws, &host_id, ErrorCode::AuthFailed).await;
        anyhow::bail!("handshake noise gagal dari {addr}");
    }
    let n = hs.write_message(&[], &mut buf)?;
    send_binary(&mut ws, buf[..n].to_vec()).await?;

    let mut chan = Channel::new(hs.into_transport_mode()?);

    // Sampai sini client terbukti tahu PSK yang benar.
    let token = if pairing_mode {
        ctx.clear_pair_failures(&hello.client_id);
        Some(finish_pairing(ctx, &hello)?)
    } else {
        ctx.update_cfg(|c| c.touch_device(&hello.client_id))?;
        None
    };

    let welcome = HostMsg::Welcome(Welcome {
        host_name: ctx.host_name(),
        os: WelcomeOs::Windows,
        host_id,
        proto: PROTOCOL_VERSION as i64,
        caps: capabilities(ctx).await,
        token: token.map(|t| t.to_vec()),
    });
    send_encrypted(&mut ws, &mut chan, &welcome).await?;
    send_deck(ctx, &mut ws, &mut chan).await?;

    Ok((ws, chan, hello))
}

/// Terbitkan token, simpan ke Credential Manager, catat device di config.
fn finish_pairing(ctx: &Arc<AppCtx>, hello: &Hello) -> anyhow::Result<[u8; TOKEN_LEN]> {
    let token = pairing::random_token();
    TokenStore::save(&hello.client_id, &token)?;

    let name = hello.name.clone().unwrap_or_else(|| "Device".into());
    let now = now_secs();
    let device_name = name.clone();
    ctx.update_cfg(move |c| {
        c.upsert_device(PairedDevice {
            client_id: hello.client_id.clone(),
            name: device_name,
            platform: hello
                .platform
                .map(|p| format!("{p:?}").to_lowercase())
                .unwrap_or_default(),
            paired_at: now,
            last_seen: now,
        })
    })?;

    // Satu PIN untuk satu device. Device berikutnya perlu PIN baru.
    ctx.stop_pairing();
    tracing::info!("device {} ({name}) berhasil dipasangkan", hello.client_id);
    ctx.emit(UiEvent::DevicePaired {
        client_id: hello.client_id.clone(),
        name,
    });
    Ok(token)
}

/// Kapabilitas yang benar-benar sudah jalan.
///
/// Client menyembunyikan UI untuk apa pun yang tidak ada di sini, jadi daftar
/// ini harus jujur: lebih baik fitur tidak muncul daripada muncul lalu gagal.
async fn capabilities(ctx: &Arc<AppCtx>) -> Vec<Capability> {
    let mut caps = vec![Capability::Deck, Capability::Input];
    if ctx.obs.is_live().await {
        caps.push(Capability::Obs);
    }
    caps
}

async fn message_loop(
    ctx: &Arc<AppCtx>,
    ws: &mut Ws,
    chan: &mut Channel,
    client_id: &str,
) -> anyhow::Result<()> {
    let mut events = ctx.subscribe();

    loop {
        let raw = tokio::select! {
            // Config berubah di UI host: dorong layout baru tanpa menunggu
            // client bertanya.
            ev = events.recv() => {
                match ev {
                    Ok(UiEvent::DeckChanged) => send_deck(ctx, ws, chan).await?,
                    Ok(UiEvent::ObsSceneChanged { scene }) => {
                        send_scene_states(ctx, ws, chan, &scene).await?
                    }
                    // Client yang lambat bisa tertinggal; kirim ulang saja
                    // daripada memutus koneksi.
                    Err(RecvError::Lagged(_)) => send_deck(ctx, ws, chan).await?,
                    Err(RecvError::Closed) => anyhow::bail!("bus event tertutup"),
                    Ok(_) => {}
                }
                continue;
            }
            read = tokio::time::timeout(IDLE_TIMEOUT, read_binary(ws)) => match read {
                Ok(Ok(v)) => v,
                Ok(Err(e)) => return Err(e),
                Err(_) => anyhow::bail!("client {client_id} diam melewati batas"),
            },
        };

        let Some(plain) = chan.open(&raw)? else {
            continue; // chunk tengah, tunggu sisanya
        };

        let msg: ClientMsg = match frame::decode(&plain) {
            Ok(m) => m,
            Err(e) => {
                // Pesan tak dikenal diabaikan demi kompatibilitas maju, tapi
                // tetap dicatat supaya bug protokol kelihatan saat debug.
                tracing::debug!("pesan dari {client_id} tidak bisa di-decode: {e}");
                continue;
            }
        };

        match msg {
            ClientMsg::Ping(Ping { ts }) => {
                send_encrypted(ws, chan, &HostMsg::Pong(Ping { ts })).await?;
            }
            ClientMsg::Pong(Ping { ts }) => {
                // Client membalas ping kita: selisihnya adalah RTT.
                if let Some(rtt) = now_millis().checked_sub(ts) {
                    ctx.set_rtt(client_id, rtt.min(u32::MAX as u64) as u32);
                }
            }
            ClientMsg::DeckPress(DeckPress { idx }) => {
                match press_button(ctx, idx).await {
                    // Menekan tombol scene mengubah scene aktif, jadi tombol
                    // toggle lain harus ikut padam saat itu juga.
                    Ok(()) => send_toggle_states(ctx, ws, chan).await?,
                    Err(e) => {
                        tracing::warn!("tombol {idx} gagal: {e}");
                        let code = match e {
                            actions::ActionError::NoSuchButton(_) => ErrorCode::UnknownAction,
                            _ => ErrorCode::ActionFailed,
                        };
                        send_error(ws, chan, code, &e.to_string()).await?;
                    }
                }
            }

            // Aksi dijalankan saat ditekan, bukan saat dilepas, supaya terasa
            // responsif. Release hanya berguna untuk tombol tahan nanti.
            ClientMsg::DeckRelease(_) => {}

            ClientMsg::WantBlob(WantBlob { blob_id }) => {
                match ctx.blobs.load(&blob_id) {
                    Ok((mime, data)) => {
                        let Some(mime) = wire_mime(&mime) else {
                            send_error(ws, chan, ErrorCode::Internal, "tipe blob tak terduga")
                                .await?;
                            continue;
                        };
                        send_encrypted(ws, chan, &HostMsg::Blob(Blob { blob_id, mime, data }))
                            .await?;
                    }
                    Err(e) => {
                        tracing::debug!("blob {blob_id} tidak bisa dibaca: {e}");
                        send_error(ws, chan, ErrorCode::UnknownAction, "ikon tidak ada").await?;
                    }
                }
            }

            ClientMsg::DeckSwitchProfile(DeckSwitchProfile { profile_id }) => {
                let known = ctx.with_cfg(|c| c.deck.profile(&profile_id).is_some());
                if !known {
                    send_error(ws, chan, ErrorCode::UnknownAction, "profil tidak ada").await?;
                    continue;
                }
                ctx.update_cfg(|c| c.deck.active = profile_id.clone())?;
                send_deck(ctx, ws, chan).await?;
            }

            other => {
                // Mode yang belum ada. Katakan apa adanya daripada diam.
                tracing::debug!("pesan {other:?} belum didukung");
                send_error(ws, chan, ErrorCode::CapMissing, "fitur ini belum tersedia di host")
                    .await?;
            }
        }
    }
}

/// Jalankan aksi di balik sebuah tombol.
///
/// Client hanya mengirim indeks; definisi aksinya dicari di sini, dari config
/// host. Itu yang membuat HP tidak bisa menyuruh PC menjalankan apa pun yang
/// belum dipasang user sendiri.
async fn press_button(ctx: &Arc<AppCtx>, idx: u16) -> Result<(), actions::ActionError> {
    let action: Action = ctx
        .with_cfg(|c| {
            c.deck
                .active_profile()
                .and_then(|p| p.button(idx))
                .map(|b| b.action.clone())
        })
        .ok_or(actions::ActionError::NoSuchButton(idx))?;

    tracing::info!("tombol {idx}: {}", action.hint());
    actions::execute(&action, &ctx.obs).await
}

/// Kirim layout profil aktif beserta daftar profil yang tersedia.
async fn send_deck(ctx: &Arc<AppCtx>, ws: &mut Ws, chan: &mut Channel) -> anyhow::Result<()> {
    let (layout, profiles) = ctx.with_cfg(|c| {
        (
            c.deck.active_profile().map(|p| p.to_wire()),
            DeckProfiles {
                profiles: c
                    .deck
                    .profiles
                    .iter()
                    .map(|p| crate::proto_gen::ProfileRef {
                        id: p.id.clone(),
                        name: p.name.clone(),
                    })
                    .collect(),
                active: c.deck.active.clone(),
            },
        )
    });

    send_encrypted(ws, chan, &HostMsg::DeckProfiles(profiles)).await?;
    if let Some(layout) = layout {
        send_encrypted(ws, chan, &HostMsg::DeckLayout(layout)).await?;
    }
    send_toggle_states(ctx, ws, chan).await
}

/// Perbarui semua tombol toggle berdasarkan keadaan sekarang.
async fn send_toggle_states(ctx: &Arc<AppCtx>, ws: &mut Ws, chan: &mut Channel) -> anyhow::Result<()> {
    if !has_toggles(ctx) {
        return Ok(());
    }
    // Satu-satunya sumber state saat ini adalah OBS. Kalau tidak tersambung,
    // semua toggle dianggap padam daripada menebak.
    let scene = ctx.obs.current_scene().await.unwrap_or_default();
    send_scene_states(ctx, ws, chan, &scene).await
}

fn has_toggles(ctx: &Arc<AppCtx>) -> bool {
    ctx.with_cfg(|c| {
        c.deck
            .active_profile()
            .is_some_and(|p| p.buttons.iter().any(|b| b.style == ButtonStyle::Toggle))
    })
}

/// Nyalakan tombol toggle yang scene-nya cocok dengan scene aktif.
async fn send_scene_states(
    ctx: &Arc<AppCtx>,
    ws: &mut Ws,
    chan: &mut Channel,
    scene: &str,
) -> anyhow::Result<()> {
    let states: Vec<(u16, bool)> = ctx.with_cfg(|c| {
        c.deck
            .active_profile()
            .map(|p| {
                p.buttons
                    .iter()
                    .filter(|b| b.style == ButtonStyle::Toggle)
                    .map(|b| match &b.action {
                        Action::ObsScene { scene: target } => (b.idx, target == scene),
                        _ => (b.idx, false),
                    })
                    .collect()
            })
            .unwrap_or_default()
    });

    for (idx, active) in states {
        send_encrypted(ws, chan, &HostMsg::DeckState(DeckState { idx, active })).await?;
    }
    Ok(())
}

fn wire_mime(mime: &str) -> Option<BlobMime> {
    match mime {
        "image/png" => Some(BlobMime::ImagePng),
        "image/jpeg" => Some(BlobMime::ImageJpeg),
        "image/webp" => Some(BlobMime::ImageWebp),
        "image/svg+xml" => Some(BlobMime::ImageSvgXml),
        _ => None,
    }
}

async fn send_error(
    ws: &mut Ws,
    chan: &mut Channel,
    code: ErrorCode,
    msg: &str,
) -> anyhow::Result<()> {
    send_encrypted(
        ws,
        chan,
        &HostMsg::Error(crate::proto_gen::ErrorMsg {
            code,
            msg: msg.to_string(),
        }),
    )
    .await
}

// ── helper I/O ──────────────────────────────────────────────────────────────

async fn read_binary(ws: &mut Ws) -> anyhow::Result<Vec<u8>> {
    loop {
        match ws.next().await {
            Some(Ok(Message::Binary(b))) => return Ok(b.to_vec()),
            // Ping/Pong WebSocket ditangani tungstenite sendiri; teks tidak dipakai.
            Some(Ok(Message::Close(_))) | None => anyhow::bail!("koneksi ditutup"),
            Some(Ok(_)) => continue,
            Some(Err(e)) => return Err(e.into()),
        }
    }
}

async fn send_binary(ws: &mut Ws, data: Vec<u8>) -> anyhow::Result<()> {
    ws.send(Message::binary(data)).await?;
    Ok(())
}

async fn send_encrypted(ws: &mut Ws, chan: &mut Channel, msg: &HostMsg) -> anyhow::Result<()> {
    for part in chan.seal(&frame::encode(msg)?)? {
        ws.send(Message::binary(part)).await?;
    }
    Ok(())
}

/// Kirim penolakan plaintext lalu tutup. Dipakai sebelum channel aman terbentuk.
///
/// Isinya hanya kode error — tidak ada yang rahasia — dan ini jauh lebih
/// berguna buat user daripada koneksi yang putus begitu saja.
async fn reject(ws: &mut Ws, host_id: &str, code: ErrorCode) {
    let ack = HelloAck {
        v: PROTOCOL_VERSION as i64,
        ok: false,
        host_id: Some(host_id.to_string()),
        noise: None,
        code: Some(code),
    };
    if let Ok(bytes) = frame::encode(&ack) {
        let _ = ws.send(Message::binary(bytes)).await;
    }
    let _ = ws.close(None).await;
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
