//! Device basics readable from inside the jail. `/proc` shows only the app's
//! own processes and `/sys` is absent, so these come from system calls the
//! jail allows.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceInfo {
    /// Kernel release, e.g. `6.6.30-android15-8`.
    pub kernel: String,
    pub machine: String,
    pub cpu_count: u32,
    pub total_ram_bytes: u64,
    pub free_ram_bytes: u64,
    pub uptime_seconds: u64,
}

fn field(raw: &[libc::c_char]) -> String {
    let bytes: Vec<u8> = raw.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

pub fn info() -> DeviceInfo {
    let mut name: libc::utsname = unsafe { std::mem::zeroed() };
    let mut sys: libc::sysinfo = unsafe { std::mem::zeroed() };
    unsafe {
        libc::uname(&mut name);
        libc::sysinfo(&mut sys);
    }
    let unit = sys.mem_unit.max(1) as u64;
    DeviceInfo {
        kernel: field(&name.release),
        machine: field(&name.machine),
        cpu_count: std::thread::available_parallelism().map_or(1, |n| n.get() as u32),
        total_ram_bytes: sys.totalram as u64 * unit,
        free_ram_bytes: sys.freeram as u64 * unit,
        uptime_seconds: sys.uptime.max(0) as u64,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn reads_something_plausible() {
        let info = super::info();
        assert!(!info.kernel.is_empty());
        assert!(info.cpu_count >= 1);
        assert!(info.total_ram_bytes > info.free_ram_bytes);
    }
}
