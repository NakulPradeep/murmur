import { useCurrentFrame, useVideoConfig } from "remotion";
import { theme } from "./theme";

/**
 * The voice mark from the launch film and the app icon.
 * `active` drives whether it animates or sits flat.
 */
export const Waveform: React.FC<{
  bars?: number;
  width?: number;
  height?: number;
  color?: string;
  active?: boolean;
  seed?: number;
}> = ({
  bars = 21,
  width = 260,
  height = 48,
  color = theme.green,
  active = true,
  seed = 0,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;

  return (
    <div style={{ display: "flex", alignItems: "center", gap: 4, height }}>
      {new Array(bars).fill(0).map((_, i) => {
        const rel = (i - (bars - 1) / 2) / ((bars - 1) / 2);
        const envelope = Math.cos(rel * 1.35) ** 2;
        const wobble = active
          ? 0.3 + 0.7 * (0.5 + 0.5 * Math.sin(t * 5.2 + i * 0.55 + seed))
          : 0.22;
        const h = Math.max(4, wobble * envelope * height);
        return (
          <div
            key={i}
            style={{
              width: width / bars - 4,
              height: h,
              borderRadius: 999,
              background: color,
              opacity: active ? 1 : 0.35,
            }}
          />
        );
      })}
    </div>
  );
};
