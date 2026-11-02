import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { BrimFilm, FONT } from "./Film";

const GROUND = "linear-gradient(135deg, #22305C 0%, #3A2C63 55%, #5A2F55 100%)";

// Feature images for the README: the film held on each feature's beat.
export const FEATURES = [
  { id: "music", t: 5.2 },
  { id: "timer", t: 7.5 },
  { id: "notifications", t: 8.6 },
  { id: "panel", t: 12.4 },
  { id: "teleprompter", t: 15.7 },
  { id: "lock", t: 18.4 },
  { id: "notch", t: 21.6 },
];

export const FeatureStill: React.FC<{ id: string }> = ({ id }) => {
  const f = FEATURES.find((x) => x.id === id)!;
  return (
    <BrimFilm format="landscape" sound={false} atTime={f.t} hand={false} />
  );
};

/** README header: the name and the panel. */
export const Hero: React.FC = () => (
  <AbsoluteFill style={{ background: GROUND, fontFamily: FONT }}>
    <BrimFilm format="landscape" sound={false} words={false} cyFrac={0.66} camMul={1.0} atTime={12.4} hand={false} />
    <div style={{ position: "absolute", left: 0, right: 0, top: 150, display: "flex", flexDirection: "column", alignItems: "center", gap: 18 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 36 }}>
        <Img src={staticFile("AppIcon.svg")} style={{ width: 190, height: 190, margin: -18 }} />
        <span style={{ fontSize: 170, fontWeight: 800, letterSpacing: "-0.045em", color: "#FFF", lineHeight: 1 }}>Brim</span>
      </div>
      <span style={{ fontSize: 56, fontWeight: 600, color: "rgba(235,235,245,0.75)", letterSpacing: "-0.015em" }}>The top of your screen, put to work.</span>
    </div>
  </AbsoluteFill>
);

/** GitHub's social preview, 1280 x 640. */
export const Social: React.FC = () => (
  <AbsoluteFill style={{ background: GROUND, fontFamily: FONT, display: "flex", flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 40 }}>
    <Img src={staticFile("AppIcon.svg")} style={{ width: 330, height: 330, margin: -30 }} />
    <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
      <span style={{ fontSize: 132, fontWeight: 800, letterSpacing: "-0.045em", color: "#FFF", lineHeight: 1 }}>Brim</span>
      <span style={{ fontSize: 38, fontWeight: 600, color: "rgba(235,235,245,0.75)", letterSpacing: "-0.01em", lineHeight: 1.2 }}>
        A Dynamic Island for your Mac.
        <br />
        Notifications, music, timers and more.
      </span>
    </div>
  </AbsoluteFill>
);
