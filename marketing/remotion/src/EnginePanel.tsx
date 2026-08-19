import { interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { theme } from "./theme";
import { Waveform } from "./Waveform";

/**
 * One recognizer racing the clock.
 *
 * The timer runs in real time and freezes the instant that engine finished, so
 * the gap on screen is the gap that was measured — the viewer is watching the
 * benchmark, not a dramatisation of it.
 */
export const EnginePanel: React.FC<{
  label: string;
  sublabel: string;
  decodeSeconds: number;
  transcript: string;
  startFrame: number;
  accent: string;
  winner?: boolean;
}> = ({
  label,
  sublabel,
  decodeSeconds,
  transcript,
  startFrame,
  accent,
  winner,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const elapsed = Math.max(0, (frame - startFrame) / fps);
  const done = elapsed >= decodeSeconds;
  const shown = Math.min(elapsed, decodeSeconds);

  // Text reveals over ~0.3 s once the engine returns, so the moment reads.
  const revealFrames = 0.3 * fps;
  const finishedAt = startFrame + decodeSeconds * fps;
  const reveal = interpolate(frame, [finishedAt, finishedAt + revealFrames], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        flex: 1,
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        gap: 26,
        padding: "0 56px",
        borderRadius: 32,
        border: `1px solid ${done ? accent + "44" : theme.faint + "66"}`,
        background: done ? accent + "0C" : "transparent",
        transition: "none",
      }}
    >
      <div style={{ display: "flex", alignItems: "baseline", gap: 14 }}>
        <span
          style={{
            fontFamily: theme.sans,
            fontSize: 40,
            fontWeight: 600,
            color: theme.ink,
          }}
        >
          {label}
        </span>
        <span style={{ fontFamily: theme.sans, fontSize: 26, color: theme.dim }}>
          {sublabel}
        </span>
      </div>

      <Waveform active={!done} color={done ? accent : theme.faint} width={300} />

      <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
        <span
          style={{
            fontFamily: theme.mono,
            fontSize: 92,
            fontWeight: 600,
            color: done ? accent : theme.dim,
            fontVariantNumeric: "tabular-nums",
          }}
        >
          {shown.toFixed(2)}s
        </span>
        {done && winner && (
          <span
            style={{
              fontFamily: theme.mono,
              fontSize: 26,
              color: accent,
              border: `1px solid ${accent}66`,
              borderRadius: 999,
              padding: "6px 16px",
            }}
          >
            10× FASTER
          </span>
        )}
      </div>

      <div
        style={{
          fontFamily: theme.sans,
          fontSize: 27,
          lineHeight: 1.45,
          color: theme.ink,
          opacity: reveal,
          minHeight: 118,
        }}
      >
        {reveal > 0 ? transcript : ""}
      </div>
    </div>
  );
};
