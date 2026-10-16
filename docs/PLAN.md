# Decky — Rencana Pengembangan

## Konteks

Decky mengubah HP jadi *control surface* untuk komputer desktop, setara [WingDeck](https://wing-deck.com/). Host jalan di PC, client di HP, terhubung lewat Wi-Fi lokal atau USB — tanpa cloud, tanpa akun.

**Keputusan yang sudah dikunci:**

- Target MVP: **Windows host + Android client**. macOS/iOS menyusul setelah protokol stabil.
- Stack: **host Tauri v2 + Rust**, **client Flutter**.
- Kelima mode dikerjakan: Deck, Trackpad, System Monitor, Music & Lyrics, Desk Clock.

**Target hasil:** installer Windows + portable (< 10 MB) dan APK Android, dipasangkan lewat PIN, langsung bisa dipakai.

## Prinsip

1. **Local-first.** Nol dependensi cloud. Satu-satunya trafik keluar adalah pencarian lirik online, dan itu *opt-in, mati secara default*.
2. **Protokol duluan.** `protocol/` adalah sumber kebenaran; host dan client generate tipe dari situ. Tidak ada field yang diketik dua kali.
3. **Degradasi anggun.** Kapabilitas yang tidak tersedia (mis. suhu CPU) disembunyikan, bukan diisi angka palsu.
4. **Latency adalah fitur.** Trackpad yang terasa lambat = produk gagal, seberapa pun lengkap fiturnya.

## Roadmap

### Fase 0 — Fondasi ✅ sedang berjalan

- [x] Init repo, `.gitignore`, README, lisensi
- [x] Spesifikasi protokol (`docs/PROTOCOL.md`)
- [ ] `protocol/schema/decky-v1.json` + codegen ke Rust (`serde`) dan Dart
- [ ] Scaffold `host/` (Tauri + SvelteKit + TypeScript)
- [ ] Scaffold `client/` (Flutter)

**Verifikasi:** `cargo build` dan `flutter build apk --debug` sukses; tipe hasil codegen kompilasi di kedua sisi.

### Fase 1 — Transport + Pairing ⟵ fase paling kritis

- Host: server WebSocket (`tokio` + `tokio-tungstenite`), framing MessagePack (`rmp-serde`), publikasi mDNS (`mdns-sd`), handshake Noise (`snow`), alur PIN, simpan token via DPAPI
- Client: discovery, layar pairing, `flutter_secure_storage`, reconnect exponential backoff, indikator status koneksi
- Host UI: window konfigurasi minimal + tray icon dengan jumlah device terhubung

**Verifikasi:** HP menemukan PC otomatis; pairing PIN sukses; matikan Wi-Fi → reconnect sendiri tanpa pairing ulang; RTT `ping`/`pong` tampil di UI.

### Fase 2 — Mode Deck

- Host: registry aksi — `launch_app`, `hotkey`, `text`, `open_url`, `media_key`, `run_script`, `obs_scene` (`obws`, obs-websocket v5)
- Host: layout grid N×M, profil, label + ikon, persist sebagai JSON, editor drag & drop di UI Tauri
- Client: render grid, haptic + feedback visual, cache ikon by `blob_id`

**Verifikasi:** tombol buka Notepad, tombol hotkey `Ctrl+Shift+M`, tombol ganti scene OBS — semua trigger dari HP.

### Fase 3 — Input & Trackpad

- Host: `SendInput` via crate `windows` (`MOUSEEVENTF_MOVE` relatif), klik, scroll, kurva akselerasi yang bisa disetel, keyboard Unicode + modifier
- Client: 1 jari gerak, tap klik kiri, 2 jari scroll, tap 2 jari klik kanan; coalescing delta 60–120 Hz; keyboard overlay

**Verifikasi:** target latency tekan→gerak **< 30 ms Wi-Fi, < 10 ms USB**, diukur, bukan dikira-kira.

### Fase 4 — System Monitor

- Host: `sysinfo` (CPU, RAM, disk, network), `nvml-wrapper` untuk GPU NVIDIA
- Suhu: WMI namespace `root\LibreHardwareMonitor` kalau LHM terpasang; kalau tidak, cap `monitor.cpu_temp` tidak diumumkan dan UI-nya hilang
- Streaming `monitor_tick` sesuai interval subscribe (default 1 detik)
- Client: gauge radial + sparkline, layout landscape

**Verifikasi:** beri beban CPU, angka di HP cocok dengan Task Manager.

### Fase 5 — Music & Lyrics

- Host: `GlobalSystemMediaTransportControlsSessionManager` (GSMTC) lewat `windows-rs` — metadata, artwork, posisi, dan command transport. Jalan untuk Spotify, YouTube di browser, dan player apa pun yang lapor ke SMTC
- Lirik: file `.lrc` di samping file musik atau cache lokal. Provider online (LRCLIB) **opt-in**
- Artwork di-cache di host, dikirim sebagai `blob`

**Verifikasi:** putar lagu → metadata + artwork muncul, tombol next jalan, `.lrc` bergulir sesuai posisi.

### Fase 6 — Desk Clock + Polish

- Client: flip clock landscape, wake lock, proteksi burn-in
- Lintas mode: tema gelap/terang, onboarding, layar error yang jelas, hemat baterai saat idle

**Verifikasi:** HP nyala semalaman di mode clock tanpa crash dan tanpa panas berlebih.

### Fase 7 — Packaging & Rilis

- Windows: installer NSIS + portable lewat bundler Tauri
- Android: APK + AAB, keystore signing
- Windows Firewall: minta izin inbound saat pertama jalan
- Halaman rilis: versi, ukuran file, checksum SHA-256

**Code signing:** tanpa sertifikat OV, SmartScreen akan memperingatkan. Entah beli sertifikat atau sediakan halaman instruksi "Run anyway".

## Keputusan Teknis

| Topik | Pilihan | Alasan |
|---|---|---|
| Serialisasi | MessagePack | Delta pointer ratusan kali/detik; JSON boros |
| Enkripsi | Noise `NNpsk0` (`snow`) | Tanpa CA, cocok untuk LAN, PSK dari token pairing |
| USB | `adb reverse` | Jauh lebih sederhana dari AOA, latency setara |
| Injeksi input | `SendInput` via `windows-rs` | Kontrol penuh atas event relatif |
| Suhu | LibreHardwareMonitor via WMI, opsional | Windows tidak punya API suhu resmi tanpa driver |
| Media | GSMTC | API resmi, jalan untuk semua player besar sekaligus |
| UI host | SvelteKit di Tauri | Bundle kecil, sesuai target < 10 MB |

## Risiko

1. **Latency trackpad** — risiko terbesar. Mitigasi: benchmark RTT sejak Fase 1, coalescing di client, `TCP_NODELAY`, kuras buffer input tiap frame.
2. **Sensor suhu Windows** — sering tidak tersedia. Mitigasi: degradasi anggun lewat sistem cap.
3. **SmartScreen / antivirus** — aplikasi yang meng-*inject* input kerap ditandai. Mitigasi: dokumentasi jelas, pertimbangkan code signing sebelum rilis publik.
4. **Kebijakan Play Store** — kontrol input jarak jauh kadang disorot. Mitigasi: deskripsi listing gamblang; semua injeksi terjadi di PC, bukan di HP.
5. **Lisensi lirik** — jangan bundel atau *scrape* lirik berhak cipta. Mitigasi: default `.lrc` milik user sendiri; provider online opt-in.
6. **Scope creep** — lima mode itu banyak. Mitigasi: Fase 1–3 sudah produk yang layak rilis; Fase 4–6 menyusul sebagai v0.2 dan v0.3.

## Verifikasi Menyeluruh

1. `cd host && npm run tauri dev` → app jalan, tray muncul, mDNS terpublikasi
2. `cd client && flutter run` di HP fisik satu Wi-Fi → host muncul, pairing sukses
3. Checklist verifikasi tiap fase di atas
4. Jalur USB: `adb reverse tcp:8787 tcp:8787`, matikan Wi-Fi HP, pastikan masih terhubung
5. Ketahanan: 2 HP sekaligus, PC sleep→wake, HP ganti jaringan, restart host — semua reconnect tanpa pairing ulang
6. Rilis: install dari NSIS di VM bersih, pastikan tidak ada runtime yang hilang
