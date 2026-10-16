# Decky

Ubah HP jadi *control surface* untuk PC. Macro deck, trackpad, monitor sistem, kontrol musik, dan jam meja — semuanya lewat Wi-Fi lokal atau kabel USB.

**Local-first.** Tidak ada cloud, tidak ada akun, tidak ada telemetri. Semua trafik kontrol tetap di jaringan lokal kamu.

> Status: **pra-alpha**, dalam pengembangan aktif. Belum ada rilis.

## Lima Mode

| Mode | Fungsi |
|---|---|
| **Deck** | Grid tombol: jalankan aplikasi, kirim hotkey, ketik teks, ganti scene OBS |
| **Trackpad** | Kontrol pointer multi-touch + keyboard, latency rendah |
| **Monitor** | CPU, RAM, GPU, suhu, throughput network dan disk |
| **Music** | Kontrol playback + metadata + lirik sinkron |
| **Clock** | Flip clock landscape untuk layar idle |

## Arsitektur

```
PC (Windows)                        Android
┌────────────────────┐              ┌──────────────┐
│ Decky Host         │   Wi-Fi      │ Decky Client │
│ Tauri v2 + Rust    │◄────────────►│   Flutter    │
│ SvelteKit (config) │   / USB      │              │
└────────────────────┘              └──────────────┘
```

Keamanan: pairing PIN sekali, lalu setiap sesi dienkripsi Noise `NNpsk0` dengan token 32 byte. Token disimpan di DPAPI (host) dan Android Keystore (client).

Detail wire format: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).
Roadmap: [`docs/PLAN.md`](docs/PLAN.md).

## Struktur Repo

```
decky/
├─ protocol/   # skema pesan — sumber kebenaran, di-codegen ke Rust + Dart
├─ host/       # aplikasi desktop (Tauri + Rust + SvelteKit)
├─ client/     # aplikasi Android (Flutter)
└─ docs/
```

## Prasyarat Build

| Alat | Versi |
|---|---|
| Rust | stable (lewat rustup) |
| Node.js | 20+ |
| Flutter | 3.x stable |
| JDK | 17 atau 21 |
| Android SDK | platform-tools + API 34+ |
| MSVC Build Tools | untuk target `x86_64-pc-windows-msvc` |

## Menjalankan

```bash
cd host && npm install && npm run tauri dev
```

```bash
cd client && flutter run
```

## Lisensi

MIT — lihat [`LICENSE`](LICENSE).
