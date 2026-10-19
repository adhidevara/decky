# Decky

Ubah HP atau tablet jadi *control surface* untuk PC — macro deck, trackpad, dan keyboard penuh — lewat Wi-Fi lokal atau kabel USB.

**Local-first.** Tidak ada cloud, tidak ada akun, tidak ada telemetri. Satu-satunya tujuan koneksi adalah PC yang kamu pilih sendiri.

> Status: **pra-alpha**, dalam pengembangan aktif. Belum ada rilis biner.

---

## Daftar isi

- [Apa yang sudah jalan](#apa-yang-sudah-jalan)
- [Arsitektur](#arsitektur)
- [Protokol](#protokol)
- [Keamanan](#keamanan)
- [Menjalankan dari sumber](#menjalankan-dari-sumber)
- [Pemakaian](#pemakaian)
- [Konfigurasi](#konfigurasi)
- [Pengembangan](#pengembangan)
- [Pemecahan masalah](#pemecahan-masalah)
- [Peta jalan](#peta-jalan)
- [Lisensi](#lisensi)

---

## Apa yang sudah jalan

### Mode Deck

Grid tombol makro yang bisa diatur dari PC. Tujuh jenis aksi:

| Aksi | Kegunaan |
|---|---|
| `launch_app` | Jalankan aplikasi |
| `open_url` | Buka tautan atau berkas |
| `hotkey` | Kirim kombinasi tombol |
| `text` | Ketik teks |
| `media_key` | Play/pause, next, volume, mute |
| `run_script` | Jalankan perintah |
| `obs_scene` | Ganti scene OBS lewat obs-websocket v5 |

Tombol punya label, warna, dan ikon. Tombol bergaya **toggle** mengikuti scene OBS yang sedang aktif. Beberapa profil bisa disimpan dan ditukar dari HP.

Mengedit layout di PC langsung terlihat di HP — tidak perlu menyambung ulang.

### Mode Trackpad

| Gestur | Hasil |
|---|---|
| Satu jari geser | Gerakkan kursor |
| Ketuk | Klik kiri |
| Ketuk dua jari | Klik kanan |
| Ketuk tiga jari | Klik tengah |
| Dua jari geser | Scroll |
| Cubit | Zoom (Ctrl + roda) |
| Tekan-tahan lalu geser | Seret |

Plus baris tombol mouse eksplisit dan kolom teks.

### Mode Keyboard

QWERTY penuh dengan **modifier lengket**: sekali tekan berlaku untuk satu tombol berikutnya, dua kali tekan mengunci sampai dimatikan. Tanpa penguncian, kombinasi seperti `Ctrl+Shift+Esc` mustahil dilakukan satu tangan di layar sentuh.

Tombol `Fn` memunculkan F1–F12 beserta Insert, Home, End, PgUp, PgDn. `Esc` permanen di kiri atas. Ada juga bar kombinasi siap pakai (Copy, Paste, Undo, Alt+Tab, dan seterusnya) dan kolom teks yang mengirim Unicode apa adanya untuk input panjang.

---

## Arsitektur

```
PC (Windows)                                 Android
┌──────────────────────────────┐             ┌────────────────────┐
│ Decky Host                   │             │ Decky Client       │
│                              │   Wi-Fi     │                    │
│ Tauri v2 + Rust              │◄───────────►│ Flutter            │
│ SvelteKit (UI konfigurasi)   │   / USB     │                    │
│ tray icon                    │             │ Deck · Trackpad ·  │
│                              │             │ Keyboard           │
└──────────────────────────────┘             └────────────────────┘
```

```
decky/
├─ protocol/        Skema pesan — sumber kebenaran, di-codegen ke Rust + Dart
│  ├─ schema/       decky-v1.json
│  └─ codegen/      generate.mjs
├─ host/            Aplikasi desktop
│  ├─ src/          UI konfigurasi (SvelteKit)
│  └─ src-tauri/    Server, injeksi input, aksi (Rust)
├─ client/          Aplikasi Android (Flutter)
└─ docs/            PROTOCOL.md, PLAN.md
```

### Satu sumber kebenaran untuk protokol

`protocol/schema/decky-v1.json` mendefinisikan setiap pesan. Dari situ `generate.mjs` menghasilkan struct Rust (`serde`) dan class Dart sekaligus, jadi tidak ada field yang diketik dua kali di dua bahasa.

```bash
node protocol/codegen/generate.mjs
```

---

## Protokol

```
┌────────────────────────────────────────┐
│ 4. Envelope  { v, t, id?, d }          │  aplikasi
├────────────────────────────────────────┤
│ 3. MessagePack                         │  serialisasi
├────────────────────────────────────────┤
│ 2. Noise NNpsk0 (ChaChaPoly + SHA256)  │  enkripsi + autentikasi
├────────────────────────────────────────┤
│ 1. WebSocket biner over TCP            │  transport
└────────────────────────────────────────┘
```

- **Discovery:** mDNS, service `_decky._tcp.local`, port 8787
- **USB:** `adb reverse`, dipasang otomatis oleh host saat kabel tercolok
- `TCP_NODELAY` aktif — Nagle menahan paket kecil, persis pola trafik trackpad
- Payload di atas 64 KB dipecah di lapisan transport; lapisan aplikasi tidak melihatnya

Spesifikasi lengkap: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

---

## Keamanan

**Pairing.** Host menampilkan PIN 6 digit yang berlaku 60 detik. Dari PIN itu diturunkan PSK (HKDF-SHA256, di-salt dengan id host dan id client) untuk handshake Noise. Lima percobaan gagal per device dalam 10 menit memicu jeda 15 menit.

**Sesi.** Setelah pairing sukses, host menerbitkan token 32 byte. Token disimpan di **Windows Credential Manager** di sisi host dan **Android Keystore** di sisi client — tidak pernah di berkas konfigurasi.

**Batas yang disengaja.** Client hanya mengirim **indeks tombol**. Definisi aksi tidak pernah menyeberang, dan petunjuk yang dikirim ke HP sengaja kabur:

```rust
Action::RunScript { command: "deploy.sh", args: ["--token=rahasia"] }
  → yang dikirim ke HP: "Jalankan perintah"
```

HP yang dibajak hanya bisa menekan tombol yang sudah kamu pasang sendiri — tidak bisa membuat tombol baru atau menjalankan perintah sembarangan.

**Jaringan.** Installer menambahkan aturan Windows Firewall untuk port 8787, dibatasi ke profil *private* dan *domain*. Di jaringan publik Decky sengaja tidak terjangkau.

Trafik memakai `ws://`, bukan `wss://`. Itu disengaja: isinya sudah dienkripsi di lapisan Noise, dan sertifikat TLS tidak ada artinya untuk alamat RFC1918 yang berubah-ubah dan tidak punya nama domain.

---

## Menjalankan dari sumber

### Prasyarat

| Alat | Versi | Catatan |
|---|---|---|
| Rust | stable | lewat [rustup](https://rustup.rs) |
| MSVC Build Tools | 2022 | beban kerja "Desktop development with C++" |
| Node.js | 20+ | |
| Flutter | 3.x stable | |
| JDK | 17 atau 21 | |
| Android SDK | API 34+ | platform-tools dan cmdline-tools |

### Host

```bash
cd host && npm install && npm run tauri dev
```

> Build **debug** memuat dev server Vite, jadi harus lewat `npm run tauri dev`.
> Menjalankan `target/debug/decky-host.exe` langsung akan menampilkan jendela kosong.

Untuk biner yang berdiri sendiri:

```bash
cd host && npm run tauri build
```

### Client

```bash
cd client && flutter run
```

Atau pasang APK-nya:

```bash
cd client && flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

---

## Pemakaian

1. Jalankan Decky Host di PC. Ikonnya muncul di tray.
2. Buka Decky di HP. Host yang satu Wi-Fi akan muncul sendiri; kalau kabel tercolok, pilih **USB**.
3. Di PC, klik **Mulai pairing**. Masukkan PIN-nya di HP.
4. Selesai. Sambungan berikutnya tidak perlu PIN lagi.

Menata tombol deck dilakukan di jendela host: klik petak mana pun di grid, isi label, warna, ikon, dan aksinya. Untuk hotkey ada tombol **Rekam** — tekan kombinasinya dan langsung tercatat.

---

## Konfigurasi

`%APPDATA%\com.decky.host\config.json`

```jsonc
{
  "host_name": "ADHIDEVARA",
  "port": 8787,
  "pointer": {
    "sensitivity": 1.6,      // pengali dasar gerakan kursor
    "acceleration": 1.0,     // 0 mematikan akselerasi
    "scroll_speed": 1.0,
    "natural_scroll": false
  },
  "obs": {
    "enabled": false,
    "host": "127.0.0.1",
    "port": 4455,
    "password": ""
  }
}
```

Ikon tombol disimpan di `blobs/` dalam folder yang sama, dialamatkan oleh hash isinya.

---

## Pengembangan

```bash
# Test host
cd host/src-tauri && cargo test          # 77 test

# Test client
cd client && flutter test                # 56 test

# Pemeriksaan statis
cd client && flutter analyze
cd host && npm run check

# Regenerate tipe protokol setelah mengubah skema
node protocol/codegen/generate.mjs
```

### Uji interop

`client/test/interop_test.dart` menjalankan host Rust sungguhan lewat `cargo run --example interop_host`, lalu melakukan pairing penuh: Hello, handshake Noise, Welcome, layout deck, sampai ping/pong.

Ini bukan pelengkap. Unit test di satu bahasa saja tidak bisa menangkap handshake yang tidak cocok — dan itulah jenis bug yang baru terlihat saat perangkat sungguhan sudah di tangan orang.

```bash
cd client && flutter test test/interop_test.dart

# Lewati kalau toolchain Rust tidak tersedia
cd client && flutter test --exclude-tags interop
```

### Catatan untuk kontributor

**Nama di skema bertabrakan dengan tipe bawaan.** Flutter sudah memiliki `Text`, `Key`, `KeyEvent`, `TextInput`, dan `ButtonStyle`. Beberapa definisi sudah diganti namanya karena itu (`ErrorMsg`, `KeyEvent`, `TextInput`, `ButtonDisplayStyle`), tapi di berkas UI protokol diimpor dengan prefix — mengganti nama setiap kali bentrok adalah permainan yang tidak akan selesai.

**Logika yang menentukan rasa dipisah dari widget.** Mesin keadaan gestur dan layout keyboard berdiri sendiri supaya bisa diuji tanpa Flutter binding. Di situlah rasa trackpad ditentukan, dan test satu-satunya cara menjaganya tetap begitu.

---

## Pemecahan masalah

**HP menemukan host tapi koneksinya timeout.**
Windows Firewall memblokir port masuk. Installer memasang aturannya; kalau menjalankan dari sumber, pasang sendiri di PowerShell sebagai Administrator:

```bash
netsh advfirewall firewall add rule name="Decky Host" dir=in action=allow protocol=TCP localport=8787 profile=private
```

**Host tidak muncul sama sekali di daftar.**
Sebagian jaringan memblokir multicast. Colok kabel USB dan pilih **USB** — jalur itu tidak memakai mDNS. Pastikan USB debugging aktif.

**Jendela host kosong.**
Build debug memuat dev server Vite. Jalankan lewat `npm run tauri dev`, bukan langsung ke binernya.

**Gauge suhu tidak ada.**
Windows tidak punya API suhu resmi tanpa driver. Decky membacanya lewat LibreHardwareMonitor kalau terpasang, dan menyembunyikan gauge-nya kalau tidak — lebih baik tidak ada daripada menampilkan angka palsu.

---

## Peta jalan

| Fase | Isi | Status |
|---|---|---|
| 0 | Fondasi, protokol, codegen | ✅ selesai |
| 1 | Transport, pairing, tray, jembatan USB | ✅ selesai |
| 2 | Mode Deck, aksi, ikon, toggle OBS | ✅ selesai |
| 3 | Trackpad dan keyboard | ✅ selesai |
| 4 | System monitor (CPU, RAM, GPU, suhu, jaringan) | belum |
| 5 | Music & Lyrics | belum |
| 6 | Desk clock dan pemolesan | belum |
| 7 | Packaging, code signing, rilis | belum |

Rencana lengkap beserta alasan di balik keputusan teknisnya: [`docs/PLAN.md`](docs/PLAN.md).

### Yang belum terverifikasi

- **Latency belum diukur.** Target < 30 ms Wi-Fi dan < 10 ms USB. Trackpad terasa benar saat dipakai, tapi belum ada angka.
- **Baru diuji di satu perangkat** (Huawei BTK-W09, Android 12) dan satu PC Windows 11.
- **macOS dan iOS belum dikerjakan.** Protokolnya netral platform, tapi injeksi input dan integrasi media khusus Windows.

---

## Lisensi

MIT — lihat [`LICENSE`](LICENSE).
