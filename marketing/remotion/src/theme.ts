/** Shared with the launch film so the two read as one campaign. */
export const theme = {
  bg: "#08090B",
  ink: "#F3F4F6",
  dim: "#808691",
  faint: "#3A3E46",
  green: "#3DDC97",
  warm: "#F8916E",
  sans: '-apple-system, "SF Pro Display", "Helvetica Neue", sans-serif',
  mono: '"SF Mono", ui-monospace, Menlo, monospace',
} as const;

/**
 * Measured on an M2 with `Murmur --bench`, 11.1 s of technical speech.
 * These are the real figures; nothing here is dramatised.
 */
export const MEASURED = {
  clipSeconds: 11.1,
  parakeet: { name: "Parakeet TDT v3", decode: 0.25, size: "1.2 GB" },
  whisper: { name: "Whisper Large v3 Turbo", decode: 2.62, size: "1.6 GB" },
  transcript:
    "Kiran asked whether the Parakeet model in Murmur outperforms Whisper on Xcode and Kubernetes terminology.",
} as const;
