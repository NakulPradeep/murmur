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

/**
 * Timeline, in seconds. Everything downstream is derived from these, so the
 * film is exactly as long as it has something to say — the first cut ran 22 s
 * for 8 s of content and held one still frame for the last thirteen.
 */
export const BEATS = {
  title: 0.2,
  subtitle: 0.65,
  parakeetIn: 1.6,
  whisperIn: 1.9,
  raceStart: 2.6,
  verdictGap: 0.75, // after the slower engine finally lands
  lockupGap: 0.75, // after the verdict line
  taglineGap: 1.35, // after the verdict line
  readHold: 2.6, // time to actually read the sign-off
  fadeOut: 0.8,
};

const raceEnd = BEATS.raceStart + MEASURED.whisper.decode;
const verdictAtSec = raceEnd + BEATS.verdictGap;
const signOffDone = verdictAtSec + BEATS.taglineGap;
export const TOTAL_SECONDS = signOffDone + BEATS.readHold + BEATS.fadeOut;

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
  const s = (sec: number) => Math.round(sec * fps);

  // Both engines start together; the clock is the whole story.
  const raceStart = s(BEATS.raceStart);
  const verdictAt = s(verdictAtSec);

  const fadeOut = interpolate(
    frame,
    [s(TOTAL_SECONDS - BEATS.fadeOut), s(TOTAL_SECONDS)],
    [1, 0],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );

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
          <FadeIn at={s(BEATS.title)}>
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
          <FadeIn at={s(BEATS.subtitle)}>
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
          <Sequence from={s(BEATS.parakeetIn)} layout="none">
            <FadeIn at={0} fill>
              <div style={{ display: "flex", flex: 1, minHeight: 0 }}>
                <EnginePanel
                  label="Parakeet"
                  sublabel={MEASURED.parakeet.size}
                  decodeSeconds={MEASURED.parakeet.decode}
                  transcript={MEASURED.transcript}
                  startFrame={raceStart - s(BEATS.parakeetIn)}
                  accent={theme.green}
                  winner
                />
              </div>
            </FadeIn>
          </Sequence>

          <Sequence from={s(BEATS.whisperIn)} layout="none">
            <FadeIn at={0} fill>
              <div style={{ display: "flex", flex: 1, minHeight: 0 }}>
                <EnginePanel
                  label="Whisper Turbo"
                  sublabel={MEASURED.whisper.size}
                  decodeSeconds={MEASURED.whisper.decode}
                  transcript={MEASURED.transcript}
                  startFrame={raceStart - s(BEATS.whisperIn)}
                  accent={theme.warm}
                />
              </div>
            </FadeIn>
          </Sequence>
        </div>

        {/* Verdict — staggered, so the sign-off arrives as three beats
            rather than one block that then sits there. */}
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

            <FadeIn at={s(BEATS.lockupGap)}>
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
                {/* Live, so the end card keeps a pulse while it is held. */}
                <Waveform width={300} height={40} active />
              </div>
            </FadeIn>

            <FadeIn at={s(BEATS.taglineGap)}>
              <div
                style={{
                  fontFamily: theme.mono,
                  fontSize: 27,
                  color: theme.green,
                  letterSpacing: 3,
                  marginTop: 18,
                }}
              >
                FREE · NO SIGN-IN · OPEN SOURCE
              </div>
            </FadeIn>
          </div>
        </Sequence>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
