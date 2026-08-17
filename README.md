# Murmur

A fast, private, local-first dictation app for macOS — a Wispr Flow alternative
where **your voice never leaves your Mac**.

Hold a key, speak, release: your words appear in whatever app you're typing in.

## Why Murmur

| | Murmur | Wispr Flow |
|---|---|---|
| Where audio goes | Never leaves your Mac | Uploaded to the cloud |
| Speed | ~0.25 s for 11 s of speech (44× realtime) | 1–2 s+ network round trip |
| Price | Free | $12–15/month |
| Works offline | Yes | No |
| Your vocabulary | Fed to the recognizer *and* fixed afterwards | Learned, opaque |
| Number style | Your choice: numerals / words / auto | Decided for you |

## Speech engines

Murmur ships two recognizers behind one interface and picks the best installed
model automatically.

| Model | Size | Speed | Notes |
|---|---|---|---|
| **Parakeet TDT v3** (default) | 1.2 GB | 44× realtime | NVIDIA's transducer. Best accuracy, fastest, and does not hallucinate on silence. 25 European languages. |
| Whisper Large v3 Turbo | 1.6 GB | 4–6× realtime | Matches Parakeet's accuracy but far slower. Worth it only for the 99-language coverage. |
| Whisper Small / Base (English) | 488 / 148 MB | 34–47× realtime | Small footprint; noticeably weaker on names and jargon. |

Measured on an M2 over 11 s of technical speech:

```
Parakeet v3        0.25s decode   44x realtime   perfect
Whisper Turbo      2.62s decode    4x realtime   perfect
Whisper Base       0.32s decode   34x realtime   "Cuba needs" for "Kubernetes"
```

Models live in `~/Library/Application Support/Murmur/models` and are downloaded
from Settings → Speech.

## Getting your words right

This is where most of the felt quality lives, and Murmur attacks it twice:

1. **Before decoding** — your vocabulary is injected into the recognizer as a
   decoding hint. On the small English model this alone turned
   *"Mermerout performs whisper on Xcode and Cuba needs terminology"* into
   *"Murmur outperforms Whisper on Xcode and Kubernetes terminology"*.
2. **After decoding** — a phonetic matcher rewrites near-misses back to what you
   meant, across word boundaries the recognizer split differently:
   *"clawed code"* → *"Claude Code"*, *"ex code"* → *"Xcode"*,
   *"swift u i"* → *"SwiftUI"*. It is confidence-aware, so words the recognizer
   was sure about are held to a higher bar and ordinary language is left alone.

Add your names, companies, and jargon under Settings → Vocabulary.

## Usage

- **Hold the dictation key** (default Right Option): push-to-talk. Release to
  transcribe and insert.
- **Shift + dictation key**, or a quick tap: hands-free recording. Press the key
  again or Return to finish. The stopping Return never reaches your app.
- **Esc**: cancel — including mid-transcription.
- **Pick any key**: Settings → General → Change… Modifiers, Fn/Globe, F1–F20,
  arrows, and spare mouse buttons all work. Keys that type text are refused.
- Menu bar icon: state, recent dictations (click to copy), settings.

Murmur keeps the half-second of audio *before* you pressed the key, so the first
syllable survives even if you start talking early, and waits a beat after you
release so the final consonant isn't clipped.

## Formatting (Settings → Formatting)

- **Numbers**: numerals ("forty two" → 42) · words (42 → "forty-two") ·
  auto (words below ten, numerals from 10) · leave as spoken. Numerals mode also
  handles units: "twenty percent" → 20%, "five hundred rupees" → ₹500.
- **Spoken corrections**: "ship it Friday, no wait, Monday" → "ship it Monday".
  Retracts as many words as the correction replaces, and never crosses a
  sentence boundary.
- Filler removal, stutter collapsing, smart capitalization, trailing space.
- Spoken commands: "new line" / "new paragraph"; optional spoken punctuation.

## AI polish (optional, off by default)

With Apple Intelligence enabled, Murmur can run the transcript through the
**on-device** model to tidy speech into prose. It stays on your Mac, costs about
a second, and never replaces the deterministic result if the model refuses or
drifts — your words are never lost to it.

## Permissions

1. **Accessibility** (System Settings → Privacy & Security → Accessibility) —
   lets Murmur type for you and watch the dictation key.
2. **Microphone** — prompted on first dictation.

If Murmur is listed under Accessibility but still can't type, remove it with the
− button and add it back; macOS drops the grant when an app is rebuilt.

## Building

```bash
scripts/build-app.sh        # → build/Murmur.app
```

Prereqs: Xcode toolchain. whisper.cpp is vendored and prebuilt once:

```bash
cd vendor/whisper.cpp
cmake -B build -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
      -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 8
```

## Command line

```bash
.build/release/Murmur --selftest                    # 49 formatter/phonetic/vocabulary cases
.build/release/Murmur --bench audio.wav             # time every installed model
.build/release/Murmur --transcribe audio.wav \
    --model parakeet --vocab "Kiran,Xcode,Claude Code"
```

## Architecture

```
key press ─► AudioRecorder ─► EngineRouter ─► RefinementPipeline ─► TextInserter
             pre-roll,         Parakeet or      vocabulary match,     accessibility
             route recovery    Whisper          format, corrections   or paste
```

- `Engines/` — `TranscriptionEngine` protocol, Whisper and Parakeet backends,
  and the router that keeps exactly one model resident and serializes decodes.
- `Audio/` — one persistent resampler for the whole session (a converter per
  buffer would click at every seam), rolling pre-roll, route-change recovery.
- `Refine/` — phonetic matcher, deterministic formatter, number engine, and the
  optional on-device polish.
- `Input/` — the event tap and the insertion strategies.

### Two things measurement changed

- **Audio normalization was removed.** Transcribing the same clip at 1×, 0.1× and
  0.03× gain (RMS 0.17 → 0.005) produced identical text. Normalizing buys nothing
  and boosting a quiet room lifts noise toward speech level, which is a known way
  to make Whisper hallucinate.
- **Cloud transcription was declined.** The best free-tier option serves the same
  `whisper-large-v3-turbo` benchmarked above — 4.6% word error rate against local
  Parakeet's 4.5%, plus a network round-trip. Paid APIs are genuinely better
  (~3.3%), so the engine layer stays pluggable, but nothing depends on one.
