import {
  AbsoluteFill,
  interpolate,
  Sequence,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { theme, MEASURED } from "./theme";
import { EnginePanel } from "./EnginePanel";
import { Waveform } from "./Waveform";

const FadeIn: React.FC<{
  at: number;
  children: React.ReactNode;
  y?: number;
  fill?: boolean;
}> = ({ at, children, y = 24, fill }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - at, fps, config: { damping: 200 } });
  return (
    <div
      style={{
        opacity: p,
        transform: `translateY(${(1 - p) * y}px)`,
        ...(fill ? { flex: 1, display: "flex", minHeight: 0 } : {}),
      }}
    >
      {children}
    </div>
  );
};

export const Comparison: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Both engines start together; the clock is the whole story.
  const raceStart = Math.round(2.6 * fps);
  const verdictAt = Math.round((2.6 + MEASURED.whisper.decode + 0.9) * fps);

  const fadeOut = interpolate(frame, [21.2 * fps, 22 * fps], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill style={{ background: theme.bg, opacity: fadeOut }}>
      {/* Quiet green bloom, matching the launch film. */}
      <AbsoluteFill
        style={{
          background:
            "radial-gradient(60% 38% at 50% 42%, rgba(61,220,151,0.10), transparent 70%)",
        }}
      />

      <AbsoluteFill
        style={{
          padding: "110px 70px",
          display: "flex",
          flexDirection: "column",
          gap: 40,
        }}
      >
        {/* Setup */}
        <div style={{ textAlign: "center" }}>
          <FadeIn at={6}>
            <div
              style={{
                fontFamily: theme.sans,
                fontSize: 62,
                fontWeight: 600,
                color: theme.ink,
                letterSpacing: -1,
              }}
            >
              Same {MEASURED.clipSeconds}s of speech.
            </div>
          </FadeIn>
          <FadeIn at={20}>
            <div
              style={{
                fontFamily: theme.sans,
                fontSize: 36,
                color: theme.dim,
                marginTop: 12,
              }}
            >
              Same MacBook. Both offline.
            </div>
          </FadeIn>
        </div>

        {/* The race */}
        <div style={{ flex: 1, display: "flex", flexDirection: "column", gap: 30 }}>
          <Sequence from={Math.round(1.6 * fps)} layout="none">
            <FadeIn at={0} fill>
              <div style={{ display: "flex", flex: 1, minHeight: 0 }}>
                <EnginePanel
                  label="Parakeet"
                  sublabel={MEASURED.parakeet.size}
                  decodeSeconds={MEASURED.parakeet.decode}
                  transcript={MEASURED.transcript}
                  startFrame={raceStart - Math.round(1.6 * fps)}
                  accent={theme.green}
                  winner
                />
              </div>
            </FadeIn>
          </Sequence>

          <Sequence from={Math.round(1.9 * fps)} layout="none">
            <FadeIn at={0} fill>
              <div style={{ display: "flex", flex: 1, minHeight: 0 }}>
                <EnginePanel
                  label="Whisper Turbo"
                  sublabel={MEASURED.whisper.size}
                  decodeSeconds={MEASURED.whisper.decode}
                  transcript={MEASURED.transcript}
                  startFrame={raceStart - Math.round(1.9 * fps)}
                  accent={theme.warm}
                />
              </div>
            </FadeIn>
          </Sequence>
        </div>

        {/* Verdict */}
        <Sequence from={verdictAt} layout="none">
          <div style={{ textAlign: "center" }}>
            <FadeIn at={0}>
              <div
                style={{
                  fontFamily: theme.sans,
                  fontSize: 52,
                  fontWeight: 600,
                  color: theme.ink,
                }}
              >
                Identical words. One tenth the wait.
              </div>
            </FadeIn>
            <FadeIn at={14}>
              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 18,
                  marginTop: 34,
                }}
              >
                <div
                  style={{
                    fontFamily: theme.sans,
                    fontSize: 96,
                    fontWeight: 200,
                    color: theme.ink,
                    letterSpacing: 6,
                  }}
                >
                  Murmur
                </div>
                <Waveform width={220} height={30} />
                <div
                  style={{
                    fontFamily: theme.mono,
                    fontSize: 27,
                    color: theme.green,
                    letterSpacing: 3,
                  }}
                >
                  FREE · NO SIGN-IN · OPEN SOURCE
                </div>
              </div>
            </FadeIn>
          </div>
        </Sequence>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
