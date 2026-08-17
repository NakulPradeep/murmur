# Murmur

A fast, private, local-first dictation app for macOS — a Wispr Flow alternative
where **your voice never leaves your Mac**.

Hold a key, speak, release: your words appear in whatever app you're typing in.

## Why Murmur over Wispr Flow

| | Murmur | Wispr Flow |
|---|---|---|
| Where audio goes | Never leaves your Mac | Uploaded to cloud |
| Latency | ~0.2s after release (Metal, model resident in RAM) | 1–2s+ network round trip |
| Price | Free | $12–15/month |
| Number style | **Your choice**: numerals / words / auto | Decided for you |
| Custom vocabulary | Editable replacement rules | Learned, opaque |
| Works offline | Yes | No |

## Usage

- **Hold the dictation key** (default Right Option): push-to-talk. Release to transcribe & insert.
- **Shift + dictation key** (or a quick tap): hands-free recording — no holding.
  Press the key again **or Return** to finish. The stopping Return never reaches your app.
- **Esc**: cancel a recording.
- **Pick any key**: Settings → General → Change… → press the key you want.
  Modifiers, Fn/Globe, F1–F20, arrows, Home/End/Page keys all work; keys that type
  text are refused (they'd stop typing that character system-wide).
- Menu bar icon: state, recent transcriptions (click to copy), settings.

## Formatting options (Settings → Formatting)

- **Numbers**: Numerals ("forty two" → 42) · Words (42 → "forty-two") ·
  Auto (words for zero–nine, numerals for 10+) · Leave as spoken.
  Numerals mode also converts units: "twenty percent" → 20%, "five hundred rupees" → ₹500.
- Filler-word removal (um, uh, hmm), smart capitalization, trailing space chaining.
- Spoken commands: "new line" / "new paragraph"; optional spoken punctuation.
- **Vocabulary**: fix words the model gets wrong (names, jargon, brands).

## Models (Settings → Models)

| Model | Size | Character |
|---|---|---|
| Base (English) | 148 MB | Fastest, great everyday accuracy |
| Small (English) | 488 MB | Balanced |
| Large v3 Turbo | 1.6 GB | Maximum accuracy, all languages |

Models live in `~/Library/Application Support/Murmur/models`.

## Permissions

1. **Accessibility** (System Settings → Privacy & Security → Accessibility):
   lets Murmur paste transcribed text for you and watch the dictation key.
2. **Microphone**: prompted on first dictation.

## Building

```bash
scripts/build-app.sh        # → build/Murmur.app
```

Prereqs: Xcode toolchain; whisper.cpp is vendored and prebuilt once:

```bash
cd vendor/whisper.cpp
cmake -B build -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
      -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 8
```

## Tests

```bash
.build/release/Murmur --selftest                          # formatter engine cases
.build/release/Murmur --transcribe file.aiff --mode words # end-to-end on an audio file
```

## Architecture

- `WhisperEngine` — whisper.cpp context, Metal GPU, model resident in RAM
- `AudioRecorder` — AVAudioEngine → 16 kHz mono float
- `HotkeyManager` — active CGEventTap: any-key trigger, hold/tap/Shift-lock, swallows consumed keys
- `TranscriptFormatter` + `NumberEngine` — deterministic, local formatting rules
- `TextInserter` — paste into frontmost app, then restore your clipboard
- `ModelManager` — download/select models
