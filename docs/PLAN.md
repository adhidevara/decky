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

### Fase 0 — Fondasi ✅ selesai

- [x] Init repo, `.gitignore`, README, lisensi
- [x] Spesifikasi protokol (`docs/PROTOCOL.md`)
- [x] `protocol/schema/decky-v1.json` + codegen ke Rust (`serde`) dan Dart
- [x] Scaffold `host/` (Tauri v2 + SvelteKit + TypeScript)
- [x] Scaffold `client/` (Flutter)

### Fase 1 — Transport + Pairing

**Host — selesai.** Server WebSocket (`tokio` + `tokio-tungstenite`), framing MessagePack (`rmp-serde`), mDNS (`mdns-sd`), Noise NNpsk0 (`snow`), alur PIN + rate limit, token di Windows Credential Manager, chunking untuk payload > 64 KB, `TCP_NODELAY`, idle timeout, ping/pong + RTT.

**Client — transport selesai.** Noise NNpsk0 ditulis tangan di Dart (tidak ada paket yang terawat), framing + chunking, discovery mDNS, token di Android Keystore, reconnect exponential backoff, UI pairing + status.

Interop dibuktikan oleh `client/test/interop_test.dart`: test itu menjalankan host Rust sungguhan lewat `cargo run --example interop_host`, lalu melakukan pairing penuh. Unit test di satu bahasa saja tidak bisa menangkap ketidakcocokan handshake.

**Diuji di perangkat fisik** (Huawei BTK-W09, Android 12): discovery mDNS menemukan host tanpa diberi IP, pairing PIN lewat USB berhasil, token tersimpan, grid deck tampil, dan tombol benar-benar menjalankan aksi di PC.

**Fase 1 selesai.** Tray icon menampilkan jumlah device terhubung dan menyediakan jalan pintas pairing; host memasang `adb reverse` sendiri saat kabel tercolok; installer NSIS memasang aturan Windows Firewall untuk port 8787, dibatasi ke profil private dan domain.

**Verifikasi:** HP menemukan PC otomatis; pairing PIN sukses; matikan Wi-Fi → reconnect sendiri tanpa pairing ulang; RTT `ping`/`pong` tampil di UI.

### Fase 2 — Mode Deck

**Selesai.** Registry aksi (`launch_app`, `open_url`, `hotkey`, `text`, `media_key`, `run_script`, `obs_scene`), injeksi keyboard lewat `SendInput`, pemetaan W3C `KeyboardEvent.code` ke virtual-key Windows, layout grid + profil tersimpan di config, editor grid di UI host dengan perekam hotkey, dan grid di HP dengan haptic.

Perubahan layout didorong ke HP yang sedang terhubung lewat bus event, jadi mengedit tombol di PC langsung terlihat di HP tanpa menyambung ulang.

Batas keamanan yang disengaja: client hanya mengirim **indeks** tombol. Definisi aksi tidak pernah menyeberang, dan `action_hint` yang dikirim ke HP sengaja kabur ("Jalankan perintah", bukan isi perintahnya). HP yang dibajak hanya bisa menekan tombol yang sudah dipasang user.

Ikon dialamatkan oleh hash isinya: host menyimpan di `blobs/<id>.<ext>`, client meminta lewat `want_blob` sekali lalu meng-cache ke disk selamanya — id yang sama selalu berarti byte yang sama, jadi tidak perlu kedaluwarsa. Ikon yatim dibersihkan saat tombol melepasnya.

Tombol `toggle` mengikuti scene OBS yang sedang aktif, dipantau dengan polling dua detik. Polling lebih sederhana daripada stream event obs-websocket dan tahan terhadap OBS yang ditutup lalu dibuka lagi — justru kasus yang paling sering terjadi. Polling berhenti sendiri saat tidak ada HP terhubung.

**Diuji di perangkat fisik:** tombol "Notepad" menjalankan Notepad di PC, tombol media diterima `SendInput` tanpa penolakan.

**Sisa:**

- [ ] Verifikasi independen efek hotkey (peluncuran aplikasi sudah terbukti; untuk `SendInput` yang terbukti baru bahwa OS menerimanya)

**Verifikasi:** tombol buka Notepad, tombol hotkey `Ctrl+Shift+M`, tombol ganti scene OBS — semua trigger dari HP.

### Fase 3 — Input & Trackpad

- Host: `SendInput` via crate `windows` (`MOUSEEVENTF_MOVE` relatif), klik, scroll, kurva akselerasi yang bisa disetel, keyboard Unicode + modifier
- Client: 1 jari gerak, tap klik kiri, 2 jari scroll, tap 2 jari klik kanan; coalescing delta 60–120 Hz; keyboard overlay

**Verifikasi:** target latency tekan→gerak **< 30 ms Wi-Fi, < 10 ms USB**, diukur, bukan dikira-kira.

### Fase 4 — System Monitor

**Terpasang.** CPU (agregat dan per inti), memori, throughput jaringan dan disk lewat `sysinfo`; GPU NVIDIA lewat `nvml-wrapper`. Client menampilkan sparkline satu menit terakhir untuk CPU, GPU, dan jaringan.

Semua angka dilaporkan sebagai **laju per detik**, bukan total kumulatif. Menghitung selisih di sisi HP berarti angka pertama setelah menyambung selalu salah, dan tiap client harus menemukan ulang aritmetika yang sama.

Langganan bersifat per koneksi: tiap HP meminta interval dan daftar metriknya sendiri, dan host tidak mengambil sampel apa pun sebelum ada yang meminta. Menutup layar monitor mengirim `monitor_unsub` — mengambil sampel untuk grafik yang tidak dilihat siapa pun membuang CPU host sekaligus baterai HP.

Sensor diperiksa sekali saat start, lalu diumumkan sebagai kapabilitas. Sekali saja memang disengaja: perangkat keras tidak berubah di tengah sesi, dan memeriksanya ulang tiap koneksi berarti menunggu NVML setiap kali HP menyambung. Di mesin pengembangan ini hasilnya suhu CPU tidak terbaca, GPU dan suhu GPU terbaca. Client menyembunyikan apa yang tidak diumumkan — gauge kosong lebih buruk daripada gauge yang tidak ada.

**Sisa:**

- [ ] Suhu CPU lewat LibreHardwareMonitor. Windows tidak punya API suhu resmi tanpa driver, dan `Components` milik `sysinfo` kembali kosong tanpa itu.
- [ ] GPU selain NVIDIA. AMD dan Intel tidak punya padanan sesederhana NVML.
- [ ] Bandingkan angkanya dengan Task Manager di bawah beban.

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
