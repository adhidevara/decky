//! Ikon tray: status ringkas dan jalan pintas tanpa membuka jendela.
//!
//! Decky adalah aplikasi yang hidup di latar belakang — jendelanya hanya
//! dibutuhkan saat menata tombol. Tray-lah yang menjawab "masih jalan tidak?"
//! dan "HP-ku tersambung tidak?" tanpa user perlu mencari jendelanya.

use std::sync::Arc;
use tauri::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::{TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Runtime as TauriRuntime};

use crate::state::AppCtx;

const ID_SHOW: &str = "show";
const ID_PAIR: &str = "pair";
const ID_QUIT: &str = "quit";

/// Pasang ikon tray dan kembalikan pegangannya.
///
/// Pegangan itu harus disimpan: menjatuhkannya menghapus ikon dari tray.
pub fn install<R: TauriRuntime>(
    app: &AppHandle<R>,
    ctx: Arc<AppCtx>,
) -> tauri::Result<TrayIcon<R>> {
    let menu = Menu::with_items(
        app,
        &[
            &MenuItem::with_id(app, ID_SHOW, "Buka Decky", true, None::<&str>)?,
            &MenuItem::with_id(app, ID_PAIR, "Mulai pairing", true, None::<&str>)?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(app, ID_QUIT, "Keluar", true, None::<&str>)?,
        ],
    )?;

    let tray = TrayIconBuilder::with_id("decky")
        .tooltip(tooltip(0))
        .menu(&menu)
        // Menu klik-kiri dimatikan supaya klik kiri bisa dipakai membuka
        // jendela, seperti kebiasaan aplikasi tray di Windows.
        .show_menu_on_left_click(false)
        .on_menu_event({
            let ctx = ctx.clone();
            move |app, event| on_menu(app, &ctx, event)
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { .. } = event {
                show_window(tray.app_handle());
            }
        })
        .build(app)?;

    Ok(tray)
}

/// Perbarui tooltip dengan jumlah device yang terhubung.
pub fn update<R: TauriRuntime>(app: &AppHandle<R>, connected: usize) {
    if let Some(tray) = app.tray_by_id("decky") {
        if let Err(e) = tray.set_tooltip(Some(tooltip(connected))) {
            tracing::warn!("gagal memperbarui tooltip tray: {e}");
        }
    }
}

fn tooltip(connected: usize) -> String {
    match connected {
        0 => "Decky — tidak ada device terhubung".to_string(),
        1 => "Decky — 1 device terhubung".to_string(),
        n => format!("Decky — {n} device terhubung"),
    }
}

fn on_menu<R: TauriRuntime>(app: &AppHandle<R>, ctx: &Arc<AppCtx>, event: MenuEvent) {
    match event.id().as_ref() {
        ID_SHOW => show_window(app),
        ID_PAIR => {
            ctx.start_pairing();
            // PIN-nya ada di jendela, jadi jendelanya harus ikut muncul —
            // kalau tidak, user melihat PIN berjalan mundur tanpa tahu di mana.
            show_window(app);
        }
        ID_QUIT => app.exit(0),
        other => tracing::debug!("item tray tidak dikenal: {other}"),
    }
}

fn show_window<R: TauriRuntime>(app: &AppHandle<R>) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
}

#[cfg(test)]
mod tests {
    use super::tooltip;

    #[test]
    fn tooltip_menjamakkan_dengan_benar() {
        assert!(tooltip(0).contains("tidak ada device"));
        assert!(tooltip(1).contains("1 device"));
        assert!(tooltip(5).contains("5 device"));
    }
}
