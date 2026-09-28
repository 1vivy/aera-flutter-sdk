//! Speaker output through AERA's audio bridge.
//!
//! AERA starts `aera-audio-bridge --browser-audio` next to the browser slot.
//! It listens on the abstract Unix socket `aera-browser-audio-v1`, accepts a
//! 16-byte hello (`"APRA"` magic, rate, channels, bits) and then raw
//! little-endian PCM: 48 kHz, 2 channels, 16 bits. This is the same stream
//! AERA Browser's GStreamer sink sends (`gst_aera_audio_sink.c`).

use std::io::{self, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;

pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: u32 = 2;
const SOCKET_NAME: &[u8] = b"aera-browser-audio-v1";
const HELLO: [u32; 4] = [0x4152_5041, SAMPLE_RATE, CHANNELS, 16];

/// Where the PCM goes.
enum Sink {
    /// AERA's audio bridge (the browser slot's jailed UID).
    Bridge(UnixStream),
    /// The phone's stock player, driven directly (root recovery modules).
    Direct(direct::Player),
}

pub struct AudioOutput {
    sink: Sink,
}

impl AudioOutput {
    /// Connects to the speaker. Fails outside AERA, or when AERA's audio
    /// bridge is not running.
    ///
    /// Root processes (recovery modules on AERA's generic plugin host) cannot
    /// use the bridge, which only serves the browser and media UIDs, so they
    /// play through the phone's stock player the way the bridge does.
    pub fn connect() -> io::Result<AudioOutput> {
        if unsafe { libc::geteuid() } == 0 && direct::available() {
            return Ok(AudioOutput { sink: Sink::Direct(direct::Player::start()?) });
        }
        let stream = connect_abstract(SOCKET_NAME).map_err(|error| {
            if error.kind() == io::ErrorKind::ConnectionRefused {
                io::Error::new(io::ErrorKind::ConnectionRefused, bridge_diagnosis())
            } else {
                error
            }
        })?;
        // Like AERA Browser, only talk to a root-owned endpoint.
        let mut peer: libc::ucred = unsafe { std::mem::zeroed() };
        let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let fd = std::os::fd::AsRawFd::as_raw_fd(&stream);
        let ok = unsafe {
            libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_PEERCRED, (&mut peer as *mut libc::ucred).cast(), &mut size)
        } == 0;
        if !ok || peer.uid != 0 {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "audio bridge is not owned by root"));
        }
        // A small send buffer keeps what is queued ahead of the speaker, and
        // so the delay before a new sound, short.
        let buffer: libc::c_int = 32 * 1024;
        unsafe {
            libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_SNDBUF, (&buffer as *const libc::c_int).cast(), std::mem::size_of::<libc::c_int>() as libc::socklen_t);
        }
        let mut stream = stream;
        let hello: Vec<u8> = HELLO.iter().flat_map(|w| w.to_le_bytes()).collect();
        stream.write_all(&hello)?;
        Ok(AudioOutput { sink: Sink::Bridge(stream) })
    }

    /// Writes interleaved stereo samples (left, right, left, ...). Blocks
    /// while the speaker's buffer is full, which paces playback.
    pub fn write(&mut self, samples: &[i16]) -> io::Result<()> {
        let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        match &mut self.sink {
            Sink::Bridge(stream) => stream.write_all(&bytes),
            Sink::Direct(player) => player.write(samples),
        }
    }
}

/// Why nothing answered on the bridge socket, as precisely as the jail lets
/// us tell.
fn bridge_diagnosis() -> String {
    // Abstract sockets of this network namespace, listed with a leading '@'.
    let listed = std::fs::read_to_string("/proc/net/unix")
        .ok()
        .map(|table| table.lines().any(|line| line.ends_with("@aera-browser-audio-v1")));
    match listed {
        Some(true) => "AERA's audio bridge is busy with another app; try again when it finishes".into(),
        Some(false) | None => "AERA's audio bridge is not running (os error 111). AERA starts it with the app and it quits when \
             another app's audio bridge already holds the speaker or the phone's audio fails to start. \
             Close other apps in Recents, then reopen this one"
            .into(),
    }
}

/// The phone's stock audio path, driven the way `aera-audio-bridge` drives it
/// (AERA-Recovery/android_device_oneplus_dodge-AERA, `audio/aera_audio_bridge.cpp`):
/// start the DSP with `aera-audio-bootstrap`, then stream a WAV through a
/// FIFO into the stock `agmplay`. Needs root; the jail cannot do this.
mod direct {
    use std::fs::File;
    use std::io::{self, Write};
    use std::path::Path;
    use std::process::{Child, Command};

    const BOOTSTRAP: &str = "/system/bin/aera-audio-bootstrap";
    const AGMPLAY: &str = "/mnt/aera-stock/vendor/bin/agmplay";
    const VOLUME: &str = "/tmp/aera-audio-volume";

    pub fn available() -> bool {
        Path::new(BOOTSTRAP).exists() && Path::new(AGMPLAY).exists()
    }

    pub struct Player {
        fifo: File,
        path: String,
        child: Child,
        volume: i32,
        written: u64,
    }

    /// AERA's volume setting, in percent (the bridge's default is 30).
    fn volume() -> i32 {
        std::fs::read_to_string(VOLUME).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(30).clamp(0, 100)
    }

    impl Player {
        pub fn start() -> io::Result<Player> {
            let status = Command::new(BOOTSTRAP).status()?;
            if !status.success() {
                return Err(io::Error::other(format!("the phone's audio failed to start ({BOOTSTRAP} {status})")));
            }
            let path = format!("/tmp/aera-flutter-audio-{}", std::process::id());
            let _ = std::fs::remove_file(&path);
            let c_path = std::ffi::CString::new(path.clone()).unwrap();
            if unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) } != 0 {
                return Err(io::Error::last_os_error());
            }
            // Read-write, so opening never waits for the player.
            let fifo = std::fs::OpenOptions::new().read(true).write(true).open(&path)?;
            let child = Command::new(AGMPLAY)
                .args([&path, "-D", "100", "-d", "100", "-c", "2", "-r", "48000", "-b", "16", "-i", "MI2S-LPAIF-RX-SECONDARY"])
                .env("LD_LIBRARY_PATH", "/vendor/aera-audio-abi:/mnt/aera-stock/vendor/lib64:/vendor/lib64:/system/lib64")
                .env("ANDROID_ROOT", "/system")
                .env("ANDROID_DATA", "/data")
                .spawn()?;
            let mut player = Player { fifo, path, child, volume: volume(), written: 0 };
            player.fifo.write_all(&wav_header())?;
            Ok(player)
        }

        pub fn write(&mut self, samples: &[i16]) -> io::Result<()> {
            // Pick up volume changes about every half second, like the bridge.
            let frames = samples.len() as u64 / 2;
            if self.written / 24_000 != (self.written + frames) / 24_000 {
                self.volume = volume();
            }
            self.written += frames;
            let bytes: Vec<u8> = samples
                .iter()
                .flat_map(|&s| ((s as i32 * self.volume / 100) as i16).to_le_bytes())
                .collect();
            self.fifo.write_all(&bytes)
        }
    }

    impl Drop for Player {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
            let _ = std::fs::remove_file(&self.path);
        }
    }

    /// A streaming WAV header with open-ended sizes, as the bridge writes.
    pub fn wav_header() -> [u8; 44] {
        let mut h = [0u8; 44];
        h[0..4].copy_from_slice(b"RIFF");
        h[4..8].copy_from_slice(&0x7fff_f024u32.to_le_bytes());
        h[8..16].copy_from_slice(b"WAVEfmt ");
        h[16..20].copy_from_slice(&16u32.to_le_bytes());
        h[20..22].copy_from_slice(&1u16.to_le_bytes());
        h[22..24].copy_from_slice(&2u16.to_le_bytes());
        h[24..28].copy_from_slice(&48_000u32.to_le_bytes());
        h[28..32].copy_from_slice(&(48_000u32 * 4).to_le_bytes());
        h[32..34].copy_from_slice(&4u16.to_le_bytes());
        h[34..36].copy_from_slice(&16u16.to_le_bytes());
        h[36..40].copy_from_slice(b"data");
        h[40..44].copy_from_slice(&0x7fff_f000u32.to_le_bytes());
        h
    }
}

fn connect_abstract(name: &[u8]) -> io::Result<UnixStream> {
    unsafe {
        let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let owned = OwnedFd::from_raw_fd(fd);
        let mut address: libc::sockaddr_un = std::mem::zeroed();
        address.sun_family = libc::AF_UNIX as libc::sa_family_t;
        for (i, byte) in name.iter().enumerate() {
            address.sun_path[i + 1] = *byte as libc::c_char;
        }
        let length = (std::mem::size_of::<libc::sa_family_t>() + 1 + name.len()) as libc::socklen_t;
        if libc::connect(fd, (&address as *const libc::sockaddr_un).cast(), length) != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(UnixStream::from(owned))
    }
}

/// A sine tone as interleaved stereo samples, for testing the speaker.
pub fn tone(frequency_hz: f32, milliseconds: u32, volume: f32) -> Vec<i16> {
    let frames = (SAMPLE_RATE as u64 * milliseconds as u64 / 1000) as usize;
    let amplitude = (volume.clamp(0.0, 1.0) * i16::MAX as f32) as f32;
    let mut samples = Vec::with_capacity(frames * 2);
    for i in 0..frames {
        let t = i as f32 / SAMPLE_RATE as f32;
        let value = (amplitude * (2.0 * std::f32::consts::PI * frequency_hz * t).sin()) as i16;
        samples.push(value);
        samples.push(value);
    }
    samples
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::AsRawFd;

    #[test]
    fn sends_hello_then_pcm() {
        // Stand in for aera-audio-bridge with an abstract listener.
        let name = format!("aera-sdk-test-{}", std::process::id());
        let listener = unsafe {
            let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
            let mut address: libc::sockaddr_un = std::mem::zeroed();
            address.sun_family = libc::AF_UNIX as libc::sa_family_t;
            for (i, b) in name.bytes().enumerate() {
                address.sun_path[i + 1] = b as libc::c_char;
            }
            let length = (std::mem::size_of::<libc::sa_family_t>() + 1 + name.len()) as libc::socklen_t;
            assert_eq!(libc::bind(fd, (&address as *const libc::sockaddr_un).cast(), length), 0);
            assert_eq!(libc::listen(fd, 1), 0);
            OwnedFd::from_raw_fd(fd)
        };
        let stream = connect_abstract(name.as_bytes()).unwrap();
        let mut stream = stream;
        stream.write_all(&HELLO.iter().flat_map(|w| w.to_le_bytes()).collect::<Vec<_>>()).unwrap();
        let mut output = AudioOutput { sink: Sink::Bridge(stream) };
        output.write(&[1, -1]).unwrap();
        drop(output);
        let client = unsafe { libc::accept(listener.as_raw_fd(), std::ptr::null_mut(), std::ptr::null_mut()) };
        let mut received = Vec::new();
        unsafe { UnixStream::from_raw_fd(client) }.read_to_end(&mut received).unwrap();
        assert_eq!(&received[..4], &0x4152_5041u32.to_le_bytes());
        assert_eq!(&received[16..], &[1, 0, 0xff, 0xff]);
    }

    #[test]
    fn tone_has_expected_length() {
        assert_eq!(tone(440.0, 10, 0.5).len(), 480 * 2);
    }
}
