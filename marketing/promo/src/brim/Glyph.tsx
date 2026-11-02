import React from "react";

// Stand-ins for the SF Symbols Brim uses (drawn, not Apple's).
const STROKE: Record<string, string> = {
  personsq:
    "M4.5 4h15a.5.5 0 0 1 .5.5v15a.5.5 0 0 1-.5.5h-15a.5.5 0 0 1-.5-.5v-15a.5.5 0 0 1 .5-.5z M12 12a2.6 2.6 0 1 0 0-5.2a2.6 2.6 0 1 0 0 5.2 M7.5 17.5c.9-2.2 2.5-3.2 4.5-3.2s3.6 1 4.5 3.2",
  alignleft: "M4 6h16 M4 10h11 M4 14h16 M4 18h11",
  sunmax:
    "M12 8.2a3.8 3.8 0 1 0 0 7.6a3.8 3.8 0 1 0 0-7.6 M12 2.5v2 M12 19.5v2 M5.3 5.3l1.4 1.4 M17.3 17.3l1.4 1.4 M2.5 12h2 M19.5 12h2 M5.3 18.7l1.4-1.4 M17.3 6.7l1.4-1.4",
  cupsaucer: "M6 8h10v4.5a4 4 0 0 1-4 4h-2a4 4 0 0 1-4-4z M16 9.5h1.3a2 2 0 0 1 0 4H16 M3.5 19h17",
  timer: "M12 5.5a7.5 7.5 0 1 0 7.5 7.5 M12 13l3.2-3.2 M12 5.5V3.5",
  shuffle:
    "M3 7h3.5c2 0 3.2 1 4.3 2.8l2.4 4.4C14.3 16 15.5 17 17.5 17H21 M18 14l3 3-3 3 M3 17h3.5c1.4 0 2.4-.5 3.2-1.4 M14.3 8.4C15.1 7.5 16.1 7 17.5 7H21 M18 4l3 3-3 3",
  repeat: "M4 12V9.5A2.5 2.5 0 0 1 6.5 7H20 M17 4l3 3-3 3 M20 12v2.5a2.5 2.5 0 0 1-2.5 2.5H4 M7 20l-3-3 3-3",
  star: "M12 3.5l2.6 5.3 5.8.8-4.2 4.1 1 5.8L12 16.8l-5.2 2.7 1-5.8-4.2-4.1 5.8-.8z",
  cloudmoon:
    "M15.5 4.5a4 4 0 0 0 4 5.6 4 4 0 0 1-3 1.4 M7.5 19.5h9a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.4 2.8 2.8 0 0 0 .3 5.6z",
  speakerwave: "M4 9.5h3.5l4.5-4v13l-4.5-4H4z M15.5 9.5a3.5 3.5 0 0 1 0 5 M18 7a7 7 0 0 1 0 10",
  airpods:
    "M7 4a3 3 0 0 0-3 3c0 1.7 1.3 3 3 3h.5v8a1.2 1.2 0 0 0 2.4 0V7.5A3.5 3.5 0 0 0 7 4z M17 4a3 3 0 0 1 3 3c0 1.7-1.3 3-3 3h-.5v8a1.2 1.2 0 0 1-2.4 0V7.5A3.5 3.5 0 0 1 17 4z",
  case: "M5 8.5h14v8a3 3 0 0 1-3 3H8a3 3 0 0 1-3-3z M5 8.5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2 M11 11.5h2",
  bolt: "M13 2.5 5 13.5h6l-1 8 8-11h-6l1-8z",
  chat: "M4 5h16v11H9l-5 4z",
  waveform: "M4 10v4 M8 7v10 M12 4v16 M16 8v8 M20 10v4",
  pencil: "M5 19h14 M7 15.5l9-9 2.5 2.5-9 9H7z",
  back2: "M18 6l-6 6 6 6 M12 6l-6 6 6 6",
  fwd2: "M6 6l6 6-6 6 M12 6l6 6-6 6",
  xmark: "M7 7l10 10 M17 7 7 17",
  keylight: "M4.5 17.5h15 M8 17.5a4 4 0 0 1 8 0 M12 7.5v2.3 M6.6 9.8l1.5 1.5 M17.4 9.8l-1.5 1.5 M4.2 14h2 M17.8 14h2",
  micslash: "M9.5 9V5a2.5 2.5 0 0 1 5 0v6 M14.2 12.3A2.5 2.5 0 0 1 9.5 11 M6 11a6 6 0 0 0 9.8 4.6 M18 11c0 .7-.1 1.3-.3 1.9 M12 17v3.5 M4 4l16 16",
  calendar: "M4.5 6h15v14h-15z M4.5 10h15 M8.5 3.5v4 M15.5 3.5v4",
  walk: "M13.5 4.5a1.5 1.5 0 1 0 0-.01 M9 21l2.5-6.5 3 3V21 M7.5 12.5l2.5-4h4l2.5 4 M12 8.5l-1 6",
  phone: "M5.5 4h3.5l1.8 4.5-2.3 1.4a10 10 0 0 0 5.6 5.6l1.4-2.3 4.5 1.8v3.5a1.8 1.8 0 0 1-1.8 1.8A15.2 15.2 0 0 1 3.7 5.8 1.8 1.8 0 0 1 5.5 4z",
  checklist: "M10 7h10 M10 12h10 M10 17h10 M4 7l1.5 1.5L8 6 M4 12l1.5 1.5L8 11 M4 17l1.5 1.5L8 16",
  arrowdown: "M12 5v13 M6.5 12.5 12 18l5.5-5.5",
};
const FILL: Record<string, string> = {
  back: "M11.5 6v12L3 12z M21 6v12l-8.5-6z",
  fwd: "M12.5 6v12L21 12z M3 6v12l8.5-6z",
  play: "M7.5 5v14l11.5-7z",
  pause: "M7 5h3.6v14H7z M13.4 5H17v14h-3.4z",
};

export const Glyph: React.FC<{ name: string; size: number; color?: string; sw?: number; style?: React.CSSProperties }> = ({
  name,
  size,
  color = "#FFFFFF",
  sw = 1.9,
  style,
}) => {
  if (FILL[name]) {
    return (
      <svg width={size} height={size} viewBox="0 0 24 24" style={{ display: "block", flex: "none", ...style }}>
        <path d={FILL[name]} fill={color} />
      </svg>
    );
  }
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke={color}
      strokeWidth={sw}
      strokeLinecap="round"
      strokeLinejoin="round"
      style={{ display: "block", flex: "none", ...style }}
    >
      <path d={STROKE[name]} />
    </svg>
  );
};

/** A progress ring, drawn on the circle's edge like Brim's EdgeRing. */
export const Ring: React.FC<{ size: number; progress: number; color: string; width?: number; children?: React.ReactNode }> = ({
  size,
  progress,
  color,
  width,
  children,
}) => {
  const w = width ?? Math.max(3, size * 0.075);
  const r = size / 2 - w / 2;
  const c = 2 * Math.PI * r;
  return (
    <div style={{ position: "relative", width: size, height: size, flex: "none" }}>
      <svg width={size} height={size} style={{ position: "absolute", inset: 0, rotate: "-90deg" }}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeOpacity={0.25} strokeWidth={w} />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          stroke={color}
          strokeWidth={w}
          strokeLinecap="round"
          strokeDasharray={`${c * Math.max(0.001, Math.min(1, progress))} ${c}`}
        />
      </svg>
      <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center" }}>
        {children}
      </div>
    </div>
  );
};

/** A pointer arrow (a generic one, not Apple's cursor). */
export const Pointer: React.FC<{ size: number; press: number }> = ({ size, press }) => (
  <svg width={size} height={size * 1.5} viewBox="0 0 20 30" style={{ display: "block", scale: `${1 - press * 0.12}` }}>
    <path
      d="M2 2 L2 23 L7.2 18.2 L10.8 26.5 L14.2 25 L10.7 17 L17.5 17 Z"
      fill="#111214"
      stroke="#FFFFFF"
      strokeWidth={1.6}
      strokeLinejoin="round"
    />
  </svg>
);
