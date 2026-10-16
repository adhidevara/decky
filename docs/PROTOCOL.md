# Decky Wire Protocol v1

Spesifikasi komunikasi antara **host** (PC) dan **client** (HP). Ini sumber kebenaran — host Rust dan client Dart dua-duanya generate tipe dari `protocol/schema/decky-v1.json`.

## 1. Lapisan

```
┌──────────────────────────────────────────┐
│ 4. Envelope  { v, t, id?, d }            │  ← aplikasi
├──────────────────────────────────────────┤
│ 3. MessagePack                           │  ← serialisasi
├──────────────────────────────────────────┤
│ 2. Noise NNpsk0 (ChaChaPoly + SHA256)      │  ← enkripsi + auth
├──────────────────────────────────────────┤
│ 1. WebSocket binary over TCP             │  ← transport
└──────────────────────────────────────────┘
```

Port default host: **8787** (TCP). Endpoint: `ws://<host>:8787/ws`.
`TCP_NODELAY` **wajib aktif** di kedua sisi — Nagle merusak latency trackpad.

## 2. Discovery

**mDNS/DNS-SD**, service type `_decky._tcp.local`.

TXT record:

| Key | Contoh | Arti |
|---|---|---|
| `v` | `1` | versi protokol tertinggi yang didukung |
| `name` | `DESKTOP-ADHI` | nama host untuk ditampilkan |
| `os` | `windows` | `windows` \| `macos` \| `linux` |
| `id` | `a3f9…` | host UUID stabil (persist di config) |

Fallback: user ketik IP manual kalau jaringan blokir multicast.

## 3. Handshake

### 3.1 Frame pra-enkripsi

Frame pertama dari client dikirim **plaintext** sebagai WebSocket binary — hanya berisi niat koneksi, tidak ada data sensitif:

```json
{ "v": 1, "mode": "pair" | "session", "client_id": "<uuid>" }
```

Host balas plaintext:

```json
{ "v": 1, "ok": true, "noise": "Noise_NNpsk0_25519_ChaChaPoly_SHA256" }
```

Kalau `v` tidak kompatibel → host balas `{ "ok": false, "code": "proto_version" }` lalu tutup.

### 3.2 PSK

| Mode | PSK |
|---|---|
| `pair` | `HKDF-SHA256(ikm = PIN_ascii, salt = host_id \|\| client_id, info = "decky-pair-v1", len = 32)` |
| `session` | token pairing 32 byte apa adanya |

PIN = 6 digit acak, ditampilkan di layar host, berlaku **60 detik**, sekali pakai.

### 3.3 Noise

Pola `NNpsk0` (2 pesan handshake, `-> e, psk` lalu `<- e, ee`). PSK salah → handshake gagal di sisi penerima; tidak ada oracle yang membocorkan PIN mana yang benar selain gagal/berhasil.

Rate limit pairing: **5 percobaan per client_id per 10 menit**, lalu backoff 15 menit. Host juga tutup listener pairing otomatis setelah PIN kedaluwarsa.

### 3.4 Setelah handshake

Semua frame berikutnya = ciphertext Noise berisi MessagePack envelope.

Satu pesan Noise maksimal 65535 byte termasuk tag 16 byte, jadi plaintext efektif 65519 byte. Payload yang lebih besar — ikon deck, album art — dipecah di lapisan transport, **sebelum** dienkripsi. Tiap potongan diawali satu byte flag:

```text
[u8 flag][potongan payload…]      flag: 0 = potongan terakhir, 1 = masih ada lanjutan
```

Penerima menumpuk potongan sampai melihat flag `0`, lalu memproses hasil gabungannya sebagai satu envelope. Batas rakitan 8 MB; melewati itu koneksi ditutup. Lapisan aplikasi tidak pernah melihat mekanisme ini.

Mode `pair` → host kirim `welcome` yang berisi `token` (32 byte). Client simpan di Android Keystore, host simpan hash-nya + metadata device. Koneksi berikutnya pakai mode `session`.

## 4. Envelope

```
{ v: u8, t: string, id?: u32, d: map }
```

- `v` — versi protokol (1)
- `t` — tipe pesan
- `id` — hanya untuk pola request/response; response pakai `id` yang sama
- `d` — payload spesifik tipe

Frame yang tidak dikenal **diabaikan diam-diam** (forward compatibility). Field tidak dikenal di dalam `d` juga diabaikan.

## 5. Katalog Pesan

### 5.1 Umum (dua arah)

| `t` | `d` | Catatan |
|---|---|---|
| `ping` | `{ ts: u64 }` | ts = monotonic ms pengirim |
| `pong` | `{ ts: u64 }` | echo `ts` apa adanya → RTT = now − ts |
| `error` | `{ code: string, msg: string }` | lihat §7 |

Client kirim `ping` tiap 5 detik. Tidak ada `pong` dalam 15 detik → anggap mati, reconnect.

### 5.2 Host → Client

| `t` | `d` |
|---|---|
| `welcome` | `{ host_name, os, host_id, proto: 1, caps: [string], token?: bytes }` |
| `deck_layout` | `{ profile_id, name, cols, rows, buttons: [Button] }` |
| `deck_state` | `{ idx: u16, active: bool }` |
| `deck_profiles` | `{ profiles: [{ id, name }], active: string }` |
| `monitor_tick` | `{ ts: u64, cpu: f32, cpu_per_core?: [f32], mem_used: u64, mem_total: u64, net_rx: u64, net_tx: u64, disk_r: u64, disk_w: u64, cpu_temp?: f32, gpu?: Gpu }` |
| `media_state` | `{ playing: bool, title, artist, album, duration_ms, position_ms, pos_at: u64, art_id?: string, app?: string }` |
| `lyrics` | `{ track_key: string, source: "lrc_file" \| "cache" \| "online", lines: [{ t_ms: u32, text: string }] }` |
| `blob` | `{ blob_id: string, mime: string, data: bytes }` |

`Button` = `{ idx: u16, label: string, icon_id?: string, color?: string, style?: "normal" \| "toggle", action_hint?: string }`

`Gpu` = `{ name: string, util?: f32, mem_used?: u64, mem_total?: u64, temp?: f32 }`

**Catatan `media_state.position_ms`**: posisi di-*snapshot* pada `pos_at` (monotonic host ms). Client ekstrapolasi sendiri saat `playing == true` supaya lirik tetap mulus tanpa host harus push tiap frame.

**Catatan `blob`**: dipakai untuk ikon deck dan album art. Client cache by `blob_id` (= hash konten), jadi tidak dikirim ulang.

### 5.3 Client → Host

| `t` | `d` |
|---|---|
| `deck_press` | `{ idx: u16 }` |
| `deck_release` | `{ idx: u16 }` |
| `deck_switch_profile` | `{ profile_id: string }` |
| `pointer_move` | `{ e: [[i16, i16], …], dt: u16 }` |
| `pointer_button` | `{ btn: 0\|1\|2, down: bool }` |
| `scroll` | `{ dx: i16, dy: i16 }` |
| `key` | `{ code: string, down: bool, mods: u8 }` |
| `text` | `{ s: string }` |
| `monitor_sub` | `{ interval_ms: u16, want: [string] }` |
| `monitor_unsub` | `{}` |
| `media_cmd` | `{ cmd: "toggle"\|"play"\|"pause"\|"next"\|"prev"\|"seek", arg?: i64 }` |
| `want_blob` | `{ blob_id: string }` |

**Aturan keras — pointer**: client **tidak pernah** kirim koordinat absolut. Hanya delta relatif, di-*coalesce* per frame (60–120 Hz) ke dalam satu `pointer_move`. `dt` = ms sejak batch sebelumnya, dipakai host untuk kurva akselerasi yang konsisten lintas refresh rate.

`mods` bitmask: `1` Shift, `2` Ctrl, `4` Alt, `8` Meta/Win.

`code` memakai nama [W3C `KeyboardEvent.code`](https://www.w3.org/TR/uievents-code/) (`KeyA`, `Enter`, `ArrowLeft`, `F5`, …) supaya netral antar platform.

## 6. Capabilities

`welcome.caps` memberi tahu client apa yang host dukung. Client **harus** menyembunyikan UI untuk kapabilitas yang tidak ada — jangan tampilkan gauge kosong atau angka palsu.

| Cap | Arti |
|---|---|
| `deck` | mode Deck tersedia |
| `input` | injeksi pointer/keyboard tersedia |
| `monitor` | metrik dasar (CPU/RAM/net/disk) |
| `monitor.cpu_temp` | suhu CPU terbaca (butuh LibreHardwareMonitor di Windows) |
| `monitor.gpu` | metrik GPU terbaca |
| `monitor.gpu_temp` | suhu GPU terbaca |
| `media` | kontrol & metadata media |
| `media.seek` | seek didukung oleh sesi media aktif |
| `lyrics` | host bisa menyuplai lirik |
| `obs` | koneksi obs-websocket aktif |

## 7. Kode Error

| `code` | Arti |
|---|---|
| `proto_version` | versi protokol tidak kompatibel |
| `auth_failed` | PSK salah / token dicabut |
| `pair_expired` | PIN kedaluwarsa |
| `pair_throttled` | terlalu banyak percobaan |
| `unknown_action` | `deck_press` ke tombol yang tidak ada |
| `action_failed` | aksi dieksekusi tapi gagal (mis. aplikasi tidak ditemukan) |
| `cap_missing` | client minta fitur yang tidak didukung host |
| `internal` | kesalahan tak terduga di host |

## 8. Transport USB (Android)

1. Host polling `adb devices` tiap 2 detik.
2. Device baru terdeteksi → host jalankan `adb -s <serial> reverse tcp:8787 tcp:8787`.
3. Client coba `ws://127.0.0.1:8787/ws` **lebih dulu** sebelum mDNS. Kalau konek → jalur USB, latency < 5 ms.
4. Device dicabut → host hapus reverse tunnel.

Tidak perlu AOA untuk MVP. AOA (tanpa ADB, tanpa USB debugging) dicatat sebagai peningkatan pasca-v1.

## 9. Aturan Versioning

- `v` naik hanya untuk perubahan **breaking**.
- Menambah `t` baru, field baru di `d`, atau cap baru = **non-breaking**, tidak menaikkan `v`.
- Host dukung `v` saat ini dan satu versi di bawahnya.
- Client dengan `v` lebih tinggi dari host → turun ke `v` host kalau masih dalam jangkauan, kalau tidak tampilkan "update host".
