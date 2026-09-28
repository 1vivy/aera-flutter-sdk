//! A shared speaker that stays connected and mixes sounds.
//!
//! Opening an [`AudioOutput`](crate::audio::AudioOutput) starts the phone's
//! stock player each time, which costs a noticeable delay, and AERA's bridge
//! stops the player half a second after the app disconnects, which can cut
//! the end of a sound. [`Speaker`] keeps one connection open while sounds
//! play (and for a moment after, so quick taps reuse it), mixes overlapping
//! sounds, and reconnects when the bridge comes back.

use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::audio::{AudioOutput, SAMPLE_RATE};

/// 10 ms of stereo audio.
const CHUNK: usize = (SAMPLE_RATE as usize / 100) * 2;
/// How long to keep the connection after the last sound ends.
const LINGER: Duration = Duration::from_secs(3);

#[derive(Default)]
struct State {
    /// Sounds still playing: interleaved stereo samples and how far along.
    sounds: Vec<(Arc<[i16]>, usize)>,
    /// The last connection error, cleared on success.
    error: Option<String>,
}

pub struct Speaker {
    state: Mutex<State>,
    wake: Condvar,
}

impl Speaker {
    /// The app's speaker. Its thread starts on first use.
    pub fn global() -> &'static Speaker {
        static SPEAKER: OnceLock<&'static Speaker> = OnceLock::new();
        SPEAKER.get_or_init(|| {
            let speaker: &'static Speaker = Box::leak(Box::new(Speaker { state: Mutex::default(), wake: Condvar::new() }));
            std::thread::Builder::new()
                .name("aera-speaker".into())
                .spawn(move || speaker.run())
                .expect("start speaker thread");
            speaker
        })
    }

    /// Plays interleaved stereo samples, mixed with whatever is playing.
    /// Returns at once. Fails with the reason if the speaker could not be
    /// reached the last time it was tried.
    pub fn play(&self, samples: Vec<i16>) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        state.sounds.push((samples.into(), 0));
        self.wake.notify_one();
        match state.error.take() {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    /// Plays and waits until connected (or failed), so the caller learns
    /// whether the speaker is reachable.
    pub fn play_checked(&self, samples: Vec<i16>) -> Result<(), String> {
        self.play(samples)?;
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut state = self.state.lock().unwrap();
        while state.error.is_none() && !state.sounds.is_empty() && state.sounds.iter().all(|(_, at)| *at == 0) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            state = self.wake.wait_timeout(state, left.min(Duration::from_millis(20))).unwrap().0;
        }
        match state.error.take() {
            Some(error) => {
                state.sounds.clear();
                Err(error)
            }
            None => Ok(()),
        }
    }

    /// Stops every sound.
    pub fn stop(&self) {
        self.state.lock().unwrap().sounds.clear();
    }

    fn run(&self) {
        let mut output: Option<AudioOutput> = None;
        let mut idle_since: Option<Instant> = None;
        let mut chunk = vec![0i16; CHUNK];
        loop {
            {
                let mut state = self.state.lock().unwrap();
                while state.sounds.is_empty() && output.is_none() {
                    state = self.wake.wait(state).unwrap();
                }
            }
            if output.is_none() {
                match AudioOutput::connect() {
                    Ok(connected) => output = Some(connected),
                    Err(error) => {
                        let mut state = self.state.lock().unwrap();
                        state.error = Some(error.to_string());
                        state.sounds.clear();
                        self.wake.notify_all();
                        continue;
                    }
                }
            }
            {
                let mut state = self.state.lock().unwrap();
                mix(&mut state.sounds, &mut chunk);
                if state.sounds.is_empty() {
                    let since = *idle_since.get_or_insert_with(Instant::now);
                    if since.elapsed() > LINGER {
                        output = None;
                        idle_since = None;
                        continue;
                    }
                } else {
                    idle_since = None;
                }
            }
            // Blocks while the speaker is full, which paces the loop.
            if let Err(error) = output.as_mut().unwrap().write(&chunk) {
                output = None;
                self.state.lock().unwrap().error = Some(format!("the speaker connection closed: {error}"));
            }
            self.wake.notify_all();
        }
    }
}

/// Mixes the next chunk of every sound into `out` (silence when none),
/// dropping sounds that have finished.
fn mix(sounds: &mut Vec<(Arc<[i16]>, usize)>, out: &mut [i16]) {
    let mut sum = vec![0i32; out.len()];
    for (samples, at) in sounds.iter_mut() {
        let end = (*at + out.len()).min(samples.len());
        for (slot, &sample) in sum.iter_mut().zip(&samples[*at..end]) {
            *slot += sample as i32;
        }
        *at = end;
    }
    sounds.retain(|(samples, at)| *at < samples.len());
    for (slot, value) in out.iter_mut().zip(sum) {
        *slot = value.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mixes_and_clamps_then_drops_finished_sounds() {
        let mut sounds = vec![(Arc::from(vec![30_000i16; 4]), 0), (Arc::from(vec![10_000i16; 8]), 0)];
        let mut out = [0i16; 4];
        mix(&mut sounds, &mut out);
        assert_eq!(out, [i16::MAX; 4]);
        assert_eq!(sounds.len(), 1);
        mix(&mut sounds, &mut out);
        assert_eq!(out, [10_000; 4]);
        assert!(sounds.is_empty());
        mix(&mut sounds, &mut out);
        assert_eq!(out, [0; 4]);
    }

    #[test]
    fn reports_an_unreachable_speaker() {
        // No bridge on a PC (and no stock player), so connecting fails.
        let speaker = Speaker::global();
        assert!(speaker.play_checked(crate::audio::tone(440.0, 50, 0.1)).is_err());
    }
}
