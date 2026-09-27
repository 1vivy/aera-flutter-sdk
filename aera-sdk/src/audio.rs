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

pub struct AudioOutput {
    stream: UnixStream,
}

impl AudioOutput {
    /// Connects to the bridge. Fails outside AERA, or when the bridge is not
    /// running.
    pub fn connect() -> io::Result<AudioOutput> {
        let stream = connect_abstract(SOCKET_NAME).map_err(|error| {
            if error.kind() == io::ErrorKind::ConnectionRefused {
                // AERA starts the bridge with the app; it exits when the
                // phone's audio stack fails to start (aera-audio-bootstrap).
                io::Error::new(
                    io::ErrorKind::ConnectionRefused,
                    "AERA's audio bridge is not running, so recovery has no speaker output right now",
                )
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
        let mut output = AudioOutput { stream };
        let hello: Vec<u8> = HELLO.iter().flat_map(|w| w.to_le_bytes()).collect();
        output.stream.write_all(&hello)?;
        Ok(output)
    }

    /// Writes interleaved stereo samples (left, right, left, ...). Blocks
    /// while the bridge's buffer is full, which paces playback.
    pub fn write(&mut self, samples: &[i16]) -> io::Result<()> {
        let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        self.stream.write_all(&bytes)
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
        let mut output = AudioOutput { stream };
        output.stream.write_all(&HELLO.iter().flat_map(|w| w.to_le_bytes()).collect::<Vec<_>>()).unwrap();
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
