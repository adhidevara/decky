//! Pengambilan metrik sistem.
//!
//! Semua angka dilaporkan sebagai **laju per detik**, bukan total kumulatif.
//! Client menampilkan grafik yang bergerak, dan menghitung selisih di sisi HP
//! berarti angka pertama setelah menyambung selalu salah.

use std::time::Instant;
use sysinfo::{Components, Disks, MemoryRefreshKind, Networks, System};

use crate::proto_gen::{Gpu, MonitorSubWantItem as Want, MonitorTick};

/// Apa saja yang perlu diambil. Client meminta hanya yang ditampilkannya,
/// supaya baterai HP dan CPU host tidak terbuang untuk angka yang tidak dilihat.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Wanted {
    pub cpu: bool,
    pub per_core: bool,
    pub memory: bool,
    pub network: bool,
    pub disk: bool,
    pub gpu: bool,
    pub temperature: bool,
}

impl Default for Wanted {
    fn default() -> Self {
        Self {
            cpu: true,
            per_core: false,
            memory: true,
            network: true,
            disk: true,
            gpu: true,
            temperature: true,
        }
    }
}

impl Wanted {
    /// Terjemahkan daftar `want` dari protokol.
    ///
    /// Daftar kosong berarti "semua yang ada" — client yang tidak menyebutkan
    /// apa-apa tetap mendapat sesuatu yang berguna.
    pub fn from_list(list: &[Want]) -> Self {
        if list.is_empty() {
            return Self::default();
        }
        let has = |w: Want| list.contains(&w);
        Self {
            // Meminta per-inti tanpa agregatnya tidak masuk akal, dan
            // memisahkan keduanya hanya membuat grafik utama kosong.
            cpu: has(Want::Cpu) || has(Want::CpuPerCore),
            per_core: has(Want::CpuPerCore),
            memory: has(Want::Mem),
            network: has(Want::Net),
            disk: has(Want::Disk),
            gpu: has(Want::Gpu),
            temperature: has(Want::Temp),
        }
    }
}

/// Kapabilitas yang benar-benar terbaca di mesin ini.
#[derive(Debug, Clone, Copy, Default)]
pub struct Available {
    pub cpu_temp: bool,
    pub gpu: bool,
    pub gpu_temp: bool,
}

pub struct Monitor {
    system: System,
    networks: Networks,
    disks: Disks,
    components: Components,
    nvml: Option<nvml_wrapper::Nvml>,
    last_sample: Option<Instant>,
}

impl Monitor {
    pub fn new() -> Self {
        // NVML hanya ada kalau driver NVIDIA terpasang. Kartu AMD dan Intel
        // tidak punya padanan yang sesederhana ini, jadi untuk sekarang
        // metrik GPU memang khusus NVIDIA.
        let nvml = match nvml_wrapper::Nvml::init() {
            Ok(n) => Some(n),
            Err(e) => {
                tracing::info!("metrik GPU tidak tersedia ({e})");
                None
            }
        };

        Self {
            system: System::new_all(),
            networks: Networks::new_with_refreshed_list(),
            disks: Disks::new_with_refreshed_list(),
            components: Components::new_with_refreshed_list(),
            nvml,
            last_sample: None,
        }
    }

    /// Apa yang bisa dibaca di mesin ini, untuk diumumkan sebagai kapabilitas.
    ///
    /// Diperiksa sungguhan, bukan ditebak: client menyembunyikan UI untuk
    /// kapabilitas yang tidak diumumkan, dan gauge kosong lebih buruk daripada
    /// gauge yang tidak ada.
    pub fn probe(&mut self) -> Available {
        self.components.refresh(true);
        let cpu_temp = self.cpu_temperature().is_some();

        let (gpu, gpu_temp) = match self.gpu_sample() {
            Some(g) => (true, g.temp.is_some()),
            None => (false, false),
        };

        Available {
            cpu_temp,
            gpu,
            gpu_temp,
        }
    }

    /// Ambil satu cuplikan.
    pub fn sample(&mut self, want: Wanted) -> MonitorTick {
        let now = Instant::now();
        let elapsed = self
            .last_sample
            .map(|t| now.duration_since(t).as_secs_f64())
            // Cuplikan pertama tidak punya pembanding. Satu detik adalah
            // tebakan yang membuat angkanya masuk akal, bukan tak hingga.
            .filter(|s| *s > 0.001)
            .unwrap_or(1.0);
        self.last_sample = Some(now);

        if want.cpu {
            self.system.refresh_cpu_all();
        }
        if want.memory {
            self.system
                .refresh_memory_specifics(MemoryRefreshKind::nothing().with_ram());
        }

        let (net_rx, net_tx) = if want.network {
            self.networks.refresh(true);
            let (rx, tx) = self
                .networks
                .iter()
                .fold((0u64, 0u64), |(rx, tx), (_, data)| {
                    (rx + data.received(), tx + data.transmitted())
                });
            (per_second(rx, elapsed), per_second(tx, elapsed))
        } else {
            (0, 0)
        };

        let (disk_r, disk_w) = if want.disk {
            self.disks.refresh(true);
            let (r, w) = self.disks.iter().fold((0u64, 0u64), |(r, w), disk| {
                let usage = disk.usage();
                (r + usage.read_bytes, w + usage.written_bytes)
            });
            (per_second(r, elapsed), per_second(w, elapsed))
        } else {
            (0, 0)
        };

        let cpu_temp = if want.temperature {
            self.components.refresh(false);
            self.cpu_temperature()
        } else {
            None
        };

        MonitorTick {
            ts: now_millis(),
            cpu: if want.cpu {
                self.system.global_cpu_usage()
            } else {
                0.0
            },
            cpu_per_core: want.per_core.then(|| {
                self.system
                    .cpus()
                    .iter()
                    .map(sysinfo::Cpu::cpu_usage)
                    .collect()
            }),
            mem_used: if want.memory {
                self.system.used_memory()
            } else {
                0
            },
            mem_total: if want.memory {
                self.system.total_memory()
            } else {
                0
            },
            net_rx,
            net_tx,
            disk_r,
            disk_w,
            cpu_temp,
            gpu: want.gpu.then(|| self.gpu_sample()).flatten(),
        }
    }

    /// Suhu CPU, kalau ada sensor yang melaporkannya.
    ///
    /// Windows tidak punya API suhu resmi tanpa driver. Yang terbaca di sini
    /// datang dari LibreHardwareMonitor atau sejenisnya kalau kebetulan
    /// berjalan; kalau tidak, hasilnya memang kosong.
    fn cpu_temperature(&self) -> Option<f32> {
        self.components
            .iter()
            .filter(|c| {
                let label = c.label().to_ascii_lowercase();
                label.contains("cpu") || label.contains("package") || label.contains("core")
            })
            .filter_map(sysinfo::Component::temperature)
            // Beberapa sensor per inti; yang menarik adalah yang paling panas.
            .fold(None, |max: Option<f32>, t| Some(max.map_or(t, |m| m.max(t))))
    }

    fn gpu_sample(&self) -> Option<Gpu> {
        let nvml = self.nvml.as_ref()?;
        let device = nvml.device_by_index(0).ok()?;

        let memory = device.memory_info().ok();
        Some(Gpu {
            name: device.name().unwrap_or_else(|_| "GPU".into()),
            util: device
                .utilization_rates()
                .ok()
                .map(|u| u.gpu as f32),
            mem_used: memory.as_ref().map(|m| m.used),
            mem_total: memory.as_ref().map(|m| m.total),
            temp: device
                .temperature(nvml_wrapper::enum_wrappers::device::TemperatureSensor::Gpu)
                .ok()
                .map(|t| t as f32),
        })
    }
}

impl Default for Monitor {
    fn default() -> Self {
        Self::new()
    }
}

/// Ubah jumlah byte dalam satu selang jadi laju per detik.
fn per_second(bytes: u64, elapsed_secs: f64) -> u64 {
    if elapsed_secs <= 0.0 {
        return 0;
    }
    (bytes as f64 / elapsed_secs).round() as u64
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn daftar_kosong_berarti_semuanya() {
        let w = Wanted::from_list(&[]);
        assert!(w.cpu && w.memory && w.network && w.disk && w.gpu && w.temperature);
    }

    #[test]
    fn hanya_yang_diminta_yang_diambil() {
        let w = Wanted::from_list(&[Want::Cpu, Want::Mem]);
        assert!(w.cpu);
        assert!(w.memory);
        assert!(!w.network);
        assert!(!w.disk);
        assert!(!w.gpu);
        assert!(!w.temperature);
    }

    #[test]
    fn per_core_juga_menyalakan_cpu() {
        let w = Wanted::from_list(&[Want::CpuPerCore]);
        assert!(w.cpu);
        assert!(w.per_core);
    }

    #[test]
    fn yang_tidak_disebut_tidak_diambil() {
        let w = Wanted::from_list(&[Want::Net]);
        assert!(w.network);
        assert!(!w.cpu && !w.memory && !w.disk && !w.gpu && !w.temperature);
    }

    #[test]
    fn laju_dihitung_dari_selang_waktu() {
        assert_eq!(per_second(1000, 1.0), 1000);
        assert_eq!(per_second(1000, 2.0), 500);
        assert_eq!(per_second(1000, 0.5), 2000);
    }

    #[test]
    fn selang_nol_tidak_membuat_pembagian_dengan_nol() {
        assert_eq!(per_second(1000, 0.0), 0);
        assert_eq!(per_second(1000, -1.0), 0);
    }

    #[test]
    fn cuplikan_berisi_angka_yang_masuk_akal() {
        let mut m = Monitor::new();
        let tick = m.sample(Wanted::default());

        assert!(tick.ts > 0);
        assert!((0.0..=100.0).contains(&tick.cpu), "cpu di luar rentang: {}", tick.cpu);
        assert!(tick.mem_total > 0, "total memori harus terbaca");
        assert!(
            tick.mem_used <= tick.mem_total,
            "terpakai {} melebihi total {}",
            tick.mem_used,
            tick.mem_total
        );
    }

    #[test]
    fn yang_tidak_diminta_tidak_diisi() {
        let mut m = Monitor::new();
        let tick = m.sample(Wanted {
            cpu: true,
            per_core: false,
            memory: false,
            network: false,
            disk: false,
            gpu: false,
            temperature: false,
        });

        assert_eq!(tick.mem_total, 0);
        assert_eq!(tick.net_rx, 0);
        assert_eq!(tick.disk_r, 0);
        assert!(tick.gpu.is_none());
        assert!(tick.cpu_per_core.is_none());
    }

    #[test]
    fn per_core_melaporkan_tiap_inti() {
        let mut m = Monitor::new();
        let tick = m.sample(Wanted {
            per_core: true,
            ..Wanted::default()
        });

        let cores = tick.cpu_per_core.expect("per-inti diminta");
        assert!(!cores.is_empty());
        assert!(cores.iter().all(|c| (0.0..=100.0).contains(c)));
    }

    #[test]
    fn probe_tidak_panik_tanpa_perangkat_keras_khusus() {
        // Mesin CI tidak punya GPU NVIDIA maupun sensor suhu. Yang diuji di
        // sini adalah bahwa ketiadaan itu dilaporkan, bukan membuat crash.
        let mut m = Monitor::new();
        let available = m.probe();
        if !available.gpu {
            assert!(!available.gpu_temp, "suhu GPU mustahil ada tanpa GPU");
        }
    }
}
