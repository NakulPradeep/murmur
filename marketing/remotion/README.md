# Murmur — motion graphics

Remotion project for Murmur's videos. Written in React, so a change is a CSS
edit rather than a coordinate calculation.

```bash
npm install
npm start          # live preview at localhost:3000 — scrub the timeline
npm run render     # -> out/comparison.mp4
```

## Compositions

- **Comparison** (22 s, 1080×1920) — Parakeet against Whisper Turbo on the same
  clip, with the clocks running in real time.

## The numbers are real

Everything in `src/theme.ts` under `MEASURED` came from
`Murmur --bench` on an M2 over 11.1 s of technical speech. The timers on screen
run at true speed, so the gap the viewer waits through is the gap that was
measured. If you re-benchmark on different hardware, update that one object and
the video follows.

## Notes

`<Sequence>` wraps its children in an `AbsoluteFill` unless you pass
`layout="none"`. Without it, flex children collapse onto each other at the
origin — which is exactly what happened the first time this was built.
