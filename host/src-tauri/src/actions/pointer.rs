//! Penghalusan gerakan pointer: sensitivitas, akselerasi, dan sisa pecahan.
//!
//! Dipisah dari injeksi input supaya bisa diuji tanpa menggerakkan kursor
//! mesin yang menjalankan test.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct PointerTuning {
    /// Pengali dasar. 1.0 berarti satu piksel layar per satu piksel sentuhan.
    pub sensitivity: f32,
    /// Seberapa kuat gerakan cepat dipercepat. 0 mematikan akselerasi.
    pub acceleration: f32,
    /// Pengali untuk scroll dua jari.
    pub scroll_speed: f32,
    /// Balik arah scroll, seperti "natural scrolling" di macOS.
    pub natural_scroll: bool,
}

impl Default for PointerTuning {
    fn default() -> Self {
        Self {
            sensitivity: 1.6,
            acceleration: 1.0,
            scroll_speed: 1.0,
            natural_scroll: false,
        }
    }
}

/// Mengubah delta sentuhan jadi gerakan kursor.
///
/// Menyimpan sisa pecahan antar batch. Tanpa itu, gerakan jari yang pelan —
/// yang per frame menghasilkan kurang dari satu piksel — akan dibulatkan ke
/// nol terus-menerus dan kursor diam saja. Justru di situ presisi paling
/// dibutuhkan.
#[derive(Debug, Default)]
pub struct PointerAccumulator {
    rest_x: f32,
    rest_y: f32,
}

impl PointerAccumulator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Hitung gerakan kursor untuk satu batch delta.
    ///
    /// `dt_ms` adalah jarak waktu sejak batch sebelumnya, dipakai untuk
    /// menaksir kecepatan. Mengandalkan besar delta saja tidak cukup: HP 120 Hz
    /// mengirim delta setengah dari HP 60 Hz untuk gerakan fisik yang sama.
    pub fn step(&mut self, deltas: &[(i16, i16)], dt_ms: u16, tuning: &PointerTuning) -> (i32, i32) {
        let (sum_x, sum_y) = deltas
            .iter()
            .fold((0f32, 0f32), |(x, y), (dx, dy)| (x + *dx as f32, y + *dy as f32));

        if sum_x == 0.0 && sum_y == 0.0 {
            return (0, 0);
        }

        let gain = tuning.sensitivity * accel_factor(sum_x, sum_y, dt_ms, tuning.acceleration);

        let moved_x = sum_x * gain + self.rest_x;
        let moved_y = sum_y * gain + self.rest_y;

        let out_x = moved_x.trunc();
        let out_y = moved_y.trunc();
        self.rest_x = moved_x - out_x;
        self.rest_y = moved_y - out_y;

        (out_x as i32, out_y as i32)
    }

    /// Buang sisa pecahan. Dipanggil saat jari diangkat, supaya gerakan
    /// berikutnya tidak diawali dorongan dari sentuhan sebelumnya.
    pub fn reset(&mut self) {
        self.rest_x = 0.0;
        self.rest_y = 0.0;
    }
}

/// Pengali akselerasi berdasarkan kecepatan, dibatasi agar tetap terkendali.
///
/// Bentuknya sengaja landai dan punya langit-langit: kurva yang terlalu agresif
/// membuat kursor terasa liar dan mustahil diarahkan ke target kecil.
fn accel_factor(dx: f32, dy: f32, dt_ms: u16, strength: f32) -> f32 {
    if strength <= 0.0 {
        return 1.0;
    }

    // dt 0 berarti dua batch tiba dalam milidetik yang sama; anggap satu frame
    // 60 Hz daripada membagi dengan nol.
    let dt = if dt_ms == 0 { 16.0 } else { dt_ms as f32 };
    let distance = (dx * dx + dy * dy).sqrt();
    let speed = distance / dt; // piksel sentuhan per milidetik

    // Di bawah ambang ini gerakan dianggap "mengarahkan", bukan "menyapu",
    // dan dibiarkan 1:1 supaya tetap presisi.
    const SLOW: f32 = 0.35;
    const MAX: f32 = 3.0;

    if speed <= SLOW {
        return 1.0;
    }
    (1.0 + (speed - SLOW) * strength).min(MAX)
}

/// Ubah delta scroll jadi satuan roda mouse Windows (1 klik = 120).
pub fn scroll_clicks(dx: i16, dy: i16, tuning: &PointerTuning) -> (i32, i32) {
    const WHEEL_DELTA: f32 = 120.0;
    // Satu "klik" roda kira-kira sejauh 40 piksel usapan; angka ini yang
    // membuat satu usapan jempol terasa seperti beberapa baris teks.
    const PIXELS_PER_CLICK: f32 = 40.0;

    let direction = if tuning.natural_scroll { -1.0 } else { 1.0 };
    let scale = tuning.scroll_speed * direction * WHEEL_DELTA / PIXELS_PER_CLICK;

    ((dx as f32 * scale) as i32, (dy as f32 * scale) as i32)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tuning() -> PointerTuning {
        PointerTuning {
            sensitivity: 1.0,
            acceleration: 0.0,
            scroll_speed: 1.0,
            natural_scroll: false,
        }
    }

    #[test]
    fn tanpa_gerakan_tidak_ada_keluaran() {
        let mut acc = PointerAccumulator::new();
        assert_eq!(acc.step(&[], 16, &tuning()), (0, 0));
        assert_eq!(acc.step(&[(0, 0)], 16, &tuning()), (0, 0));
    }

    #[test]
    fn delta_dijumlahkan_dalam_satu_batch() {
        let mut acc = PointerAccumulator::new();
        assert_eq!(acc.step(&[(3, 0), (4, 0), (-2, 1)], 16, &tuning()), (5, 1));
    }

    #[test]
    fn sisa_pecahan_terkumpul_bukan_hilang() {
        let mut acc = PointerAccumulator::new();
        let t = PointerTuning {
            sensitivity: 0.5,
            ..tuning()
        };

        // Tiap langkah menghasilkan 0.5 piksel: dibulatkan sendiri-sendiri
        // hasilnya selalu nol, dan kursor tidak akan pernah bergerak.
        assert_eq!(acc.step(&[(1, 0)], 16, &t), (0, 0));
        assert_eq!(acc.step(&[(1, 0)], 16, &t), (1, 0));
        assert_eq!(acc.step(&[(1, 0)], 16, &t), (0, 0));
        assert_eq!(acc.step(&[(1, 0)], 16, &t), (1, 0));
    }

    #[test]
    fn reset_membuang_sisa() {
        let mut acc = PointerAccumulator::new();
        let t = PointerTuning {
            sensitivity: 0.5,
            ..tuning()
        };
        acc.step(&[(1, 0)], 16, &t);
        acc.reset();
        assert_eq!(acc.step(&[(1, 0)], 16, &t), (0, 0), "sisa harusnya sudah hilang");
    }

    #[test]
    fn sensitivitas_menskalakan_gerakan() {
        let mut acc = PointerAccumulator::new();
        let t = PointerTuning {
            sensitivity: 2.0,
            ..tuning()
        };
        assert_eq!(acc.step(&[(10, -5)], 16, &t), (20, -10));
    }

    #[test]
    fn akselerasi_nol_berarti_satu_banding_satu() {
        assert_eq!(accel_factor(100.0, 0.0, 16, 0.0), 1.0);
    }

    #[test]
    fn gerakan_pelan_tidak_dipercepat() {
        // 3 piksel per 16 ms = 0.19 px/ms, di bawah ambang.
        assert_eq!(accel_factor(3.0, 0.0, 16, 1.0), 1.0);
    }

    #[test]
    fn gerakan_cepat_dipercepat_tapi_dibatasi() {
        let sedang = accel_factor(20.0, 0.0, 16, 1.0);
        let cepat = accel_factor(200.0, 0.0, 16, 1.0);
        assert!(sedang > 1.0, "gerakan cepat harus dipercepat, dapat {sedang}");
        assert!(cepat <= 3.0, "akselerasi harus punya langit-langit, dapat {cepat}");
        assert!(cepat >= sedang);
    }

    #[test]
    fn dt_nol_tidak_membuat_pembagian_dengan_nol() {
        let f = accel_factor(10.0, 0.0, 0, 1.0);
        assert!(f.is_finite() && f >= 1.0);
    }

    #[test]
    fn refresh_rate_lebih_tinggi_tidak_mengubah_rasa() {
        // Gerakan fisik sama: 20 px dalam 32 ms, dilaporkan sebagai satu batch
        // 60 Hz atau dua batch 120 Hz.
        let sekali = accel_factor(20.0, 0.0, 32, 1.0);
        let dua_kali = accel_factor(10.0, 0.0, 16, 1.0);
        assert!(
            (sekali - dua_kali).abs() < 0.01,
            "kecepatan harus dihitung dari jarak dibagi waktu, bukan dari besar delta saja"
        );
    }

    #[test]
    fn scroll_diubah_ke_satuan_roda() {
        let t = tuning();
        let (_, dy) = scroll_clicks(0, 40, &t);
        assert_eq!(dy, 120, "usapan 40 piksel harusnya satu klik roda");
    }

    #[test]
    fn natural_scroll_membalik_arah() {
        let normal = scroll_clicks(0, 40, &tuning());
        let natural = scroll_clicks(
            0,
            40,
            &PointerTuning {
                natural_scroll: true,
                ..tuning()
            },
        );
        assert_eq!(natural.1, -normal.1);
    }
}
