import React from "react";
import { AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { Audio } from "@remotion/media";
import { Glyph, Pointer, Ring } from "./Glyph";
import { AKey, anim, clamp01, content, easeOut, mix, smooth, sp } from "./motion";

// Brim, 60 s on "Upbeat" (117.5 bpm, from 0:35 of the track). One pill becomes
// everything; every move is Brim's own spring, every cut lands on the beat.

export const FONT2 = "Inter, -apple-system, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif";
const SEC = "rgba(235,235,245,0.6)";
const TER = "rgba(235,235,245,0.32)";
const FILL = "rgba(255,255,255,0.1)";
const ORANGE = "#FF9F0A";
const GREEN = "#30D158";
const GROUND = "linear-gradient(135deg, #22305C 0%, #3A2C63 55%, #5A2F55 100%)";

const BEAT = 60 / 117.45;
const BAR = BEAT * 4;
const bar = (n: number) => n * BAR;
const beat = (n: number) => n * BEAT;

export const DURATION2 = 60;

// ---------------- timeline ----------------
const T = {
  idle: 0.55,
  live: bar(2),
  split: bar(3.5),
  merge: bar(5) - 0.1,
  drop: bar(6),
  hits: [0, 1, 2, 3, 4, 5].map((i) => bar(6) + beat(i)),
  acts: [0, 1, 2, 3].map((i) => bar(8) + beat(2 * i)),
  pointerIn: bar(10),
  panel: bar(10) + beat(2),
  shelfDrop: bar(12) + beat(2),
  shortcut: bar(13) + beat(1),
  mirror: bar(14),
  prompterClick: bar(15),
  prompter: bar(15) + beat(1),
  lock: bar(17),
  unlock: bar(18),
  notch: bar(18) + 0.25,
  float: bar(19),
  glass: bar(20),
  idle2: bar(21),
  points: [0, 1, 2, 3].map((i) => bar(21) + beat(2 * i)),
  icon: bar(23),
  lockup: bar(24),
};

const W: AKey[] = [
  [0, 12], [T.idle, 200], [T.live, 280], [T.split, 208, sp(0.5, 0.75)], [T.merge, 280],
  [T.drop - 0.2, 396, sp(0.35, 0.82)], [T.acts[0] - 0.2, 280], [T.panel, 576, sp(0.45, 0.85)],
  [T.prompter, 520], [T.lock, 200], [T.notch, 330], [T.float, 280], [T.idle2, 200],
  [T.icon, 240, smooth(0.7)],
];
const H: AKey[] = [
  [0, 12], [T.idle, 54], [T.drop - 0.2, 72, sp(0.35, 0.82)], [T.acts[0] - 0.2, 54], [T.panel, 178, sp(0.45, 0.85)],
  [T.mirror + 0.12, 300], [T.prompterClick + 0.05, 178], [T.prompter, 260], [T.lock, 54], [T.icon, 84.6, smooth(0.7)],
];
const RCAP: AKey[] = [
  [0, 999], [T.drop - 0.2, 26, smooth(0.15)], [T.acts[0] - 0.2, 999, smooth(0.3)], [T.panel, 32, smooth(0.15)],
  [T.prompter, 30], [T.lock, 999, smooth(0.3)],
];
const CAM: AKey[] = [
  [0, 3.1], [T.live, 2.9, sp(0.7, 0.95)], [T.split, 2.7, sp(0.7, 0.95)], [T.drop - 0.2, 2.4, sp(0.5, 0.95)],
  [T.acts[0] - 0.2, 2.8, sp(0.6, 0.95)], [T.panel, 1.82, sp(0.6, 0.95)], [T.mirror, 1.46, sp(0.6, 0.95)],
  [T.prompterClick, 1.82, sp(0.6, 0.95)], [T.prompter, 1.9, sp(0.6, 0.95)], [T.lock, 2.6, sp(0.7, 0.95)],
  [T.notch, 2.8, sp(0.7, 0.95)], [T.idle2, 3.0, sp(0.7, 0.95)], [T.icon, 0.96, smooth(1.2)], [T.lockup, 0.72, smooth(0.9)],
];

type Format = "landscape" | "portrait" | "square";

export const BrimFilm2: React.FC<{ format: Format; atTime?: number; audio?: boolean; hand?: boolean; words?: boolean }> = ({
  format,
  atTime,
  audio = true,
  hand = true,
  words = true,
}) => {
  const frame = useCurrentFrame();
  const { fps, width: VW, height: VH } = useVideoConfig();
  const t = atTime ?? frame / fps;
  const land = format === "landscape";
  const base = land ? VW / 1920 : format === "portrait" ? 0.93 : 0.82;

  const c = anim(t, CAM) * base;
  const w = anim(t, W);
  const h = anim(t, H);
  const notchP = clamp01(sp(0.5, 0.9)(t - T.notch)) * (1 - clamp01(sp(0.5, 0.9)(t - T.float)));
  const r = Math.min(h / 2, anim(t, RCAP));
  const rTop = r * (1 - notchP);

  // where it sits
  const cyBase = VH * (land ? 0.42 : 0.4);
  const lockLift = clamp01(sp(0.6, 0.95)(t - T.lock)) * (1 - clamp01(sp(0.6, 0.95)(t - T.unlock - 0.2))) * VH * (land ? 0.13 : 0.08);
  const lk = clamp01(smooth(0.9)(t - T.lockup));
  const iconCy = VH * (land ? 0.47 : 0.42);
  const lockupX = land ? VW / 2 - 300 * base : VW / 2;
  const lockupY = land ? VH * 0.47 : VH * (format === "portrait" ? 0.4 : 0.36);
  const cx = mix(VW / 2, lockupX, lk);
  let cy = mix(cyBase - lockLift, (h * c) / 2, notchP);
  cy = mix(cy, iconCy, clamp01(smooth(1.2)(t - T.icon)));
  cy = mix(cy, lockupY, lk);

  // the dot, the split, the beat
  const pop = clamp01(sp(0.35, 0.7)(t - 0.08)) * (t < 0.08 ? 0 : 1);
  const spl = clamp01(sp(0.5, 0.72)(t - T.split)) * (1 - clamp01(sp(0.32, 0.9)(t - T.merge)));
  const anchor = t >= T.split - 0.01 && t < T.merge + 0.5 ? 1 - clamp01(sp(0.4, 0.9)(t - T.merge)) : 0;
  const pillX = anchor * (-140 + w / 2);
  const circleX = -140 + w - 27 + 66 * spl;
  const pulse = [...T.hits, ...T.acts].reduce((a, h0) => a + (t >= h0 ? Math.exp(-(t - h0) * 12) * 0.035 : 0), 0);

  // the material: black, glass, clear
  const g1 = clamp01(sp(0.6, 0.95)(t - T.glass - 0.2)) * (1 - clamp01(sp(0.5, 0.95)(t - T.idle2)));
  const g2 = clamp01(sp(0.6, 0.95)(t - T.glass - 1.1)) * (1 - clamp01(sp(0.5, 0.95)(t - T.idle2)));
  const bgA = mix(mix(1, 0.62, g1), 0.24, g2);
  const blur = mix(0, mix(24, 10, g2), g1);

  const S = (x: number, y: number) => [cx + x * c, cy + y * c];
  const [px, py, carry] = pointer(t, c, cx, cy, h, VW, VH);
  const press = [T.shortcut, T.mirror, T.prompterClick].reduce((a, h0) => a + (t >= h0 ? Math.exp(-(t - h0) * 10) : 0), 0);

  const fs = land ? 78 : format === "portrait" ? 74 : 62;
  const textY = VH * (land ? 0.76 : format === "portrait" ? 0.66 : 0.78);

  const iconO = clamp01((t - T.icon - 0.55) / 0.15);
  const iris = clamp01(sp(0.6, 0.9)(t - T.icon - 0.65));
  const iconPx = (240 / 624) * 1024 * c;
  const inset = mix(402 / 1024, 100 / 1024, iris) * 100;
  const insetS = mix(200 / 1024, 100 / 1024, iris) * 100;
  const insetR = (mix(110, 185, iris) / 1024) * iconPx;

  const lockScreen = clamp01(sp(0.6, 0.95)(t - T.lock)) * (1 - clamp01(sp(0.6, 0.95)(t - T.unlock - 0.15)));

  return (
    <AbsoluteFill style={{ background: GROUND, fontFamily: FONT2, overflow: "hidden" }}>
      {audio ? <Audio src={staticFile("soundtrack.wav")} /> : null}

      {/* colour drifting behind the glass */}
      <Bokeh t={t} cx={cx} cy={cy} c={c} />

      {/* the lock screen */}
      <AbsoluteFill style={{ background: "rgba(5,6,14,0.45)", opacity: lockScreen }} />
      <div style={{ position: "absolute", left: 0, right: 0, top: cy + 27 * c + 26 * base, textAlign: "center", opacity: lockScreen, translate: `0px ${(1 - lockScreen) * 24}px` }}>
        <div style={{ fontSize: 34 * base * (land ? 1 : 1.1), fontWeight: 600, color: "rgba(255,255,255,0.85)" }}>Mon 26 Oct</div>
        <div style={{ fontSize: 210 * base * (land ? 1 : 1.1), fontWeight: 700, lineHeight: 0.95, letterSpacing: "-0.02em", color: "rgba(225,232,255,0.8)", textShadow: "0 2px 0 rgba(255,255,255,0.18), 0 10px 40px rgba(0,0,0,0.3)" }}>20:51</div>
      </div>

      {/* the circle that splits off, with its neck */}
      {spl > 0.01 ? (
        <>
          <div style={{ position: "absolute", left: S(pillX + w / 2 - 2, 0)[0], top: cy - (h * c * mix(0.62, 0.14, clamp01(spl))) / 2, width: Math.max(0, (circleX - 27 - (pillX + w / 2) + 4) * c), height: h * c * mix(0.62, 0.14, clamp01(spl)), background: "#000", opacity: spl < 0.8 ? 1 : clamp01(1 - (spl - 0.8) / 0.2) }} />
          <div style={{ position: "absolute", left: S(circleX - 27, 0)[0], top: cy - 27 * c, width: 54 * c, height: 54 * c, borderRadius: "50%", background: "#000", display: "flex", alignItems: "center", justifyContent: "center", boxShadow: "0 20px 50px rgba(0,0,0,0.3)" }}>
            <Layer t={t} a={T.split + 0.25} b={T.merge - 0.05} scale={c} style={{ transformOrigin: "50% 50%" }}>
              <Ring size={48} progress={0.62 - (t - T.split) * 0.004} color={ORANGE}>
                <span style={{ fontSize: 13.5, fontWeight: 700, color: ORANGE, fontVariantNumeric: "tabular-nums" }}>{t < T.split + 1.4 ? "9:56" : "9:55"}</span>
              </Ring>
            </Layer>
          </div>
        </>
      ) : null}

      {/* the island */}
      <div
        style={{
          position: "absolute",
          left: S(pillX - w / 2, 0)[0],
          top: cy - (h * c) / 2,
          width: w * c,
          height: h * c,
          borderRadius: `${rTop * c}px ${rTop * c}px ${r * c}px ${r * c}px`,
          background: `rgba(0,0,0,${bgA})`,
          backdropFilter: blur > 0.5 ? `blur(${blur * base}px) saturate(150%)` : undefined,
          boxShadow: `${g1 > 0.05 ? `inset 0 0 0 ${1.2 * base}px rgba(255,255,255,${0.16 * g1}), ` : ""}0 ${24 * base}px ${60 * base}px rgba(0,0,0,${0.32 * (1 - notchP) * (1 - g2 * 0.7)})`,
          scale: `${pop * (1 + pulse)} ${pop * (1 - pulse * 0.5)}`,
          overflow: "hidden",
          opacity: 1 - iconO,
        }}
      >
        <div style={{ position: "absolute", left: 0, top: 0, width: w, height: h, scale: `${c}`, transformOrigin: "0 0" }}>
          <Islands t={t} w={w} h={h} notch={notchP} />
        </div>
      </div>
      {notchP > 0.02 ? (
        <>
          <Flare x={S(-w / 2, 0)[0]} size={10 * c} o={notchP} side="left" top={cy - (h * c) / 2} />
          <Flare x={S(w / 2, 0)[0]} size={10 * c} o={notchP} side="right" top={cy - (h * c) / 2} />
        </>
      ) : null}

      {/* the icon opens out of the pill */}
      {iconO > 0 ? (
        <div style={{ position: "absolute", left: cx - iconPx / 2, top: cy - iconPx / 2, width: iconPx, height: iconPx, opacity: iconO, clipPath: `inset(${inset}% ${insetS}% ${inset}% ${insetS}% round ${insetR}px)` }}>
          <Img src={staticFile("AppIcon.svg")} style={{ width: "100%", height: "100%" }} />
        </div>
      ) : null}

      {/* the hand, and the file it carries */}
      {hand && t > T.pointerIn - 0.1 && t < T.prompter + 1.0 ? (
        <div style={{ position: "absolute", left: px, top: py, zIndex: 5 }}>
          {carry > 0 ? (
            <div style={{ position: "absolute", left: -14 * base, top: 22 * base, opacity: carry, rotate: "-6deg", scale: `${base * (land ? 1.4 : 1.6)}`, transformOrigin: "0 0" }}>
              <Doc />
            </div>
          ) : null}
          <Pointer size={30 * base * (land ? 1.1 : 1.3)} press={Math.min(1, press)} />
        </div>
      ) : null}

      {words ? <Words t={t} y={textY} size={fs} /> : null}
      <EndCard t={t} land={land} portrait={format === "portrait"} base={base} cx={cx} cy={cy} iconPx={iconPx} VW={VW} />
    </AbsoluteFill>
  );
};

// ---------------- the hand ----------------
const pointer = (t: number, c: number, cx: number, cy: number, h: number, VW: number, VH: number): [number, number, number] => {
  const head = -h / 2 + 32; // header row
  const P = (x: number, y: number) => [cx + x * c, cy + y * c];
  type Stop = [number, () => number[], (d: number) => number];
  const stops: Stop[] = [
    [0, () => [VW * 0.86, VH * 1.08], easeOut(0.01)],
    [T.pointerIn, () => P(70, 12), easeOut(0.7)],
    [T.shelfDrop - 1.2, () => [VW * 0.7, VH * 1.08], smooth(0.4)],
    [T.shelfDrop - 0.7, () => P(150, 30), easeOut(0.6)],
    [T.shortcut - 0.5, () => P(-190, head), smooth(0.45)],
    [T.mirror - 0.45, () => P(120, head), smooth(0.4)],
    [T.prompterClick - 0.45, () => P(154, head), smooth(0.4)],
    [T.prompter + 0.2, () => [VW * 0.95, VH * 1.1], smooth(0.6)],
  ];
  let x = stops[0][1]()[0];
  let y = stops[0][1]()[1];
  for (let i = 1; i < stops.length; i++) {
    const [t0, to, curve] = stops[i];
    if (t < t0) break;
    const p = clamp01(curve(t - t0));
    const [tx, ty] = to();
    x = mix(x, tx, p);
    y = mix(y, ty, p);
  }
  const carry = t > T.shelfDrop - 0.75 && t < T.shelfDrop + 0.02 ? 1 - clamp01((t - T.shelfDrop + 0.08) / 0.1) : 0;
  return [x, y, carry];
};

// ---------------- a content layer with Brim's transition ----------------
const Layer: React.FC<{ t: number; a: number; b?: number; scale?: number; fast?: boolean; children: React.ReactNode; style?: React.CSSProperties }> = ({ t, a, b, scale, fast, children, style }) => {
  const k = content(t, a, b, fast);
  if (!k.visible) return null;
  return (
    <div style={{ ...k.style, ...(scale ? { scale: `${scale * Number(k.style.scale)}` } : {}), ...style }}>{children}</div>
  );
};

// ---------------- what the island shows ----------------
const Islands: React.FC<{ t: number; w: number; h: number; notch: number }> = ({ t, w, h, notch }) => (
  <>
    <Layer t={t} a={T.idle + 0.1} b={T.live} style={abs(w, 54)}>
      <Clock />
    </Layer>
    <Layer t={t} a={T.live} b={T.drop - 0.25} style={abs(w, 54)}>
      <Live t={t} />
    </Layer>
    {T.hits.map((h0, i) => (
      <Layer key={i} t={t} a={h0} b={i < 5 ? T.hits[i + 1] - 0.06 : T.acts[0] - 0.25} fast style={abs(396, 72)}>
        <Banner i={i} t={t} />
      </Layer>
    ))}
    {T.acts.map((a0, i) => (
      <Layer key={`a${i}`} t={t} a={a0} b={i < 3 ? T.acts[i + 1] - 0.06 : T.panel - 0.9} fast style={abs(280, 54)}>
        <Activity i={i} t={t} />
      </Layer>
    ))}
    <Layer t={t} a={T.panel - 0.85} b={T.panel - 0.05} style={abs(280, 54)}>
      <Live t={t} />
    </Layer>
    <Layer t={t} a={T.panel + 0.05} b={T.prompterClick + 0.4} style={abs(576, h)}>
      <Panel t={t} h={h} />
    </Layer>
    <Layer t={t} a={T.prompter + 0.1} b={T.lock - 0.05} style={abs(520, 260)}>
      <Prompter t={t} />
    </Layer>
    <Layer t={t} a={T.lock + 0.15} b={T.notch - 0.05} style={abs(w, 54)}>
      <Lock t={t} w={w} />
    </Layer>
    <Layer t={t} a={T.notch + 0.1} b={T.idle2 - 0.05} style={abs(w, 54)}>
      <Live t={t} wing={notch} />
    </Layer>
    <Layer t={t} a={T.idle2 + 0.05} b={T.icon + 0.5} style={abs(w, 54)}>
      <Clock />
    </Layer>
  </>
);

const abs = (w: number, h: number): React.CSSProperties => ({ position: "absolute", left: 0, top: 0, width: w, height: h });

const Clock: React.FC = () => (
  <div style={{ width: "100%", height: 54, display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 26px", boxSizing: "border-box" }}>
    <span style={{ fontSize: 23, fontWeight: 700, color: "rgba(235,235,245,0.72)", fontVariantNumeric: "tabular-nums" }}>20:16</span>
    <span style={{ display: "flex", alignItems: "center", gap: 5 }}>
      <span style={{ fontSize: 17, fontWeight: 700, color: "#F5F5F7" }}>11°</span>
      <Glyph name="cloudmoon" size={19} sw={1.8} />
    </span>
  </div>
);

const Art: React.FC<{ size: number; radius: number }> = ({ size, radius }) => (
  <div style={{ position: "relative", width: size, height: size, borderRadius: radius, overflow: "hidden", flex: "none", background: "linear-gradient(135deg, #FF7A59, #8A3FD1)" }}>
    <div style={{ position: "absolute", width: size * 0.42, height: size * 0.42, left: size * 0.46, top: size * 0.16, borderRadius: "50%", background: "rgba(255,236,210,0.75)" }} />
    <div style={{ position: "absolute", width: size * 1.3, height: size * 0.7, left: -size * 0.15, top: size * 0.62, borderRadius: "50%", background: "rgba(20,10,40,0.45)" }} />
  </div>
);

/** The waveform bars, moving on the music's beat. */
const Bars: React.FC<{ t: number; size?: number }> = ({ t, size = 25 }) => {
  const rest = [0.36, 0.72, 1.0, 0.56, 0.84, 0.44];
  const ph = (t % BEAT) / BEAT;
  const kick = Math.exp(-ph * 5);
  return (
    <span style={{ display: "flex", gap: 1.9, alignItems: "center", height: size, width: size, justifyContent: "center", flex: "none" }}>
      {rest.map((x, i) => {
        const k = 0.45 + 0.35 * kick + 0.2 * Math.abs(Math.sin(t * (4 + i) + i * 1.7));
        return <span key={i} style={{ width: 2.6, height: size * 0.8 * x * k, borderRadius: 1.3, background: "#FFF" }} />;
      })}
    </span>
  );
};

const Live: React.FC<{ t: number; wing?: number }> = ({ t, wing = 0 }) => (
  <div style={{ width: "100%", height: 54, display: "flex", alignItems: "center", gap: 8, padding: `0 ${15 + wing * 8}px 0 ${11 + wing * 10}px`, boxSizing: "border-box" }}>
    <Art size={32} radius={9} />
    <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
      <span style={{ fontSize: 14, fontWeight: 600, color: "#F5F5F7", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>Neon Tide (Late Mix)</span>
      <span style={{ fontSize: 11, color: SEC, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>Marla Vey, Kites &amp; Co</span>
    </div>
    <Bars t={t} />
  </div>
);

const IconCircle: React.FC<{ name: string; color?: string; bg?: string }> = ({ name, color = "#FFF", bg = "rgba(255,255,255,0.12)" }) => (
  <span style={{ width: 38, height: 38, borderRadius: "50%", background: bg, display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
    <Glyph name={name} size={19} color={color} />
  </span>
);

const Row: React.FC<{ lead: React.ReactNode; title: string; sub: string; subColor?: string; right?: React.ReactNode }> = ({ lead, title, sub, subColor, right }) => (
  <div style={{ width: 396, height: 72, display: "flex", alignItems: "center", gap: 12, padding: "0 17px", boxSizing: "border-box" }}>
    {lead}
    <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 1 }}>
      <span style={{ fontSize: 13, fontWeight: 600, color: "#F5F5F7", whiteSpace: "nowrap" }}>{title}</span>
      <span style={{ fontSize: 12, fontWeight: 500, color: subColor ?? "rgba(245,245,247,0.82)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{sub}</span>
    </div>
    {right}
  </div>
);

const Level: React.FC<{ p: number }> = ({ p }) => (
  <span style={{ display: "block", width: 96, height: 6, borderRadius: 3, background: "rgba(255,255,255,0.18)", overflow: "hidden", flex: "none" }}>
    <span style={{ display: "block", width: 96 * p, height: 6, borderRadius: 3, background: "#FFF" }} />
  </span>
);

const Banner: React.FC<{ i: number; t: number }> = ({ i, t }) => {
  const h0 = T.hits[i];
  const grow = clamp01(sp(0.45, 0.9)(t - h0 - 0.05));
  const now = <span style={{ alignSelf: "flex-start", marginTop: 18, fontSize: 11, color: TER }}>now</span>;
  const small = (p: number, glyph: string, label: string) => (
    <span style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 2 }}>
      <Ring size={30} progress={p} color={GREEN} width={3}>
        <Glyph name={glyph} size={13} color={glyph === "bolt" ? GREEN : "#FFF"} sw={2} />
      </Ring>
      <span style={{ fontSize: 9.5, fontWeight: 600, color: SEC }}>{label}</span>
    </span>
  );
  switch (i) {
    case 0:
      return (
        <Row
          lead={<span style={{ width: 38, height: 38, borderRadius: 9, background: "linear-gradient(180deg, #5BE584, #1DB954)", display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}><Glyph name="chat" size={22} sw={2.2} /></span>}
          title="Giulia"
          sub="Are we still on for dinner tonight?"
          subColor={SEC}
          right={now}
        />
      );
    case 1:
      return <Row lead={<IconCircle name="speakerwave" />} title="Volume" sub="Mac mini Speakers" right={<Level p={mix(0.2, 0.62, grow)} />} />;
    case 2:
      return <Row lead={<IconCircle name="sunmax" />} title="LU28R55" sub="Level 14" right={<Level p={mix(0.7, 0.88, grow)} />} />;
    case 3:
      return <Row lead={<IconCircle name="keylight" />} title="Keyboard Backlight" sub="Level 4" right={<Level p={mix(0.43, 0.57, grow)} />} />;
    case 4:
      return <Row lead={<IconCircle name="micslash" color="rgba(235,235,245,0.75)" />} title="Microphone" sub="Muted" right={now} />;
    default:
      return (
        <Row
          lead={<IconCircle name="airpods" />}
          title="AirPods Pro"
          sub="Nearby"
          right={<span style={{ display: "flex", gap: 8, marginTop: 4 }}>{small(0.8, "bolt", "80%")}{small(0.9, "case", "90%")}</span>}
        />
      );
  }
};

const Activity: React.FC<{ i: number; t: number }> = ({ i, t }) => {
  const row = (lead: React.ReactNode, title: string, trail: string, color: string) => (
    <div style={{ width: 280, height: 54, display: "flex", alignItems: "center", gap: 8, padding: "0 19px 0 11px", boxSizing: "border-box" }}>
      {lead}
      <span style={{ flex: 1, minWidth: 0, fontSize: 15, fontWeight: 600, color: "#F5F5F7", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{title}</span>
      <span style={{ fontSize: 15, fontWeight: 600, color, fontVariantNumeric: "tabular-nums" }}>{trail}</span>
    </div>
  );
  if (i === 0)
    return row(
      <span style={{ width: 32, height: 32, borderRadius: 7, background: "#FFF", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", flex: "none" }}>
        <span style={{ fontSize: 6.5, fontWeight: 700, color: "#FF3B30", lineHeight: 1 }}>MON</span>
        <span style={{ fontSize: 15, color: "#1C1C1E", lineHeight: 1 }}>26</span>
      </span>,
      "Design review",
      "in 12 min",
      "#FF8A80",
    );
  if (i === 1) {
    const s = 252 + Math.floor((t - T.acts[1]) * 1);
    return row(
      <span style={{ width: 32, height: 32, borderRadius: "50%", background: GREEN, display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}><Glyph name="phone" size={16} sw={2.1} /></span>,
      "Video call",
      `0${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`,
      GREEN,
    );
  }
  if (i === 2)
    return row(
      <span style={{ width: 32, height: 32, borderRadius: 7, background: "#FFF", display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}><Glyph name="checklist" size={19} color={ORANGE} sw={2.2} /></span>,
      "Pay the rent",
      "in 15 min",
      SEC,
    );
  const p = 0.35 + clamp01((t - T.acts[3]) / 0.9) * 0.5;
  return row(
    <Ring size={32} progress={p} color="#64B5FF" width={3}><Glyph name="arrowdown" size={14} color="#64B5FF" sw={2.4} /></Ring>,
    "Project-final.zip",
    `${Math.round(p * 100)}%`,
    "#64B5FF",
  );
};

const HBtn: React.FC<{ name: string; active?: number; gs?: number }> = ({ name, active = 0, gs = 13 }) => (
  <span style={{ width: 26, height: 26, borderRadius: "50%", background: `rgba(255,255,255,${0.1 + 0.16 * active})`, display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
    <Glyph name={name} size={gs} color="rgba(235,235,245,0.85)" />
  </span>
);

const Panel: React.FC<{ t: number; h: number }> = ({ t, h }) => {
  const sc = (c1: string, c2: string, g: string, hot = 0) => (
    <span style={{ width: 26, height: 26, borderRadius: "50%", background: `linear-gradient(180deg, ${c1}, ${c2})`, display: "flex", alignItems: "center", justifyContent: "center", flex: "none", boxShadow: hot > 0.01 ? `0 0 0 ${3 * hot}px rgba(255,190,90,${0.45 * hot})` : undefined }}>
      <Glyph name={g} size={13} sw={2.1} />
    </span>
  );
  const shortcutHot = t >= T.shortcut ? Math.exp(-(t - T.shortcut) * 2.2) : 0;
  const mirrorOn = t >= T.mirror && t < T.prompterClick ? 1 : 0;
  const shelfIn = t >= T.shelfDrop;
  return (
    <div style={{ width: 576, height: h, padding: 19, boxSizing: "border-box", display: "flex", flexDirection: "column" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 6, height: 26, flex: "none" }}>
        <span style={{ width: 16, height: 16, borderRadius: 4, background: "linear-gradient(180deg, #FF6A88, #E0245E)" }} />
        <span style={{ fontSize: 11, fontWeight: 500, color: SEC }}>Music</span>
        <span style={{ display: "flex", gap: 6, marginLeft: 6 }}>
          {sc("#D29E3B", "#A45724", "sunmax", shortcutHot)}
          {sc("#7188EC", "#4954D1", "calendar")}
          {sc("#CE7CA9", "#A04160", "walk")}
        </span>
        <span style={{ flex: 1 }} />
        <span style={{ display: "flex", gap: 8 }}>
          <HBtn name="personsq" active={mirrorOn} />
          <HBtn name="alignleft" active={t >= T.prompterClick ? 1 : 0} />
          <HBtn name="sunmax" />
          <HBtn name="cupsaucer" gs={14} />
          <HBtn name="timer" />
        </span>
      </div>
      <div style={{ display: "flex", gap: 16, flex: 1, marginTop: 8, minHeight: 0 }}>
        <div style={{ flex: 1, paddingTop: 6, position: "relative" }}>
          <Layer t={t} a={T.panel + 0.05} b={T.mirror + 0.05}>
            <Player t={t} />
          </Layer>
          <Layer t={t} a={T.mirror + 0.15} b={T.prompterClick}>
            <Mirror />
          </Layer>
        </div>
        <div style={{ width: 1, background: "rgba(255,255,255,0.09)" }} />
        <div style={{ width: 207, display: "flex", flexDirection: "column", gap: 6 }}>
          {shelfIn ? (
            <Layer t={t} a={T.shelfDrop}>
              <Shelf />
            </Layer>
          ) : null}
          <Note />
          {!shelfIn || h > 200 ? <TimerRow /> : null}
        </div>
      </div>
    </div>
  );
};

const Player: React.FC<{ t: number }> = ({ t }) => (
  <div style={{ display: "flex", gap: 14 }}>
    <Art size={84} radius={12} />
    <div style={{ width: 200, display: "flex", flexDirection: "column" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span style={{ flex: 1, fontSize: 13.5, fontWeight: 700, color: "#F5F5F7", whiteSpace: "nowrap" }}>Neon Tide (Late Mix)</span>
        <Glyph name="star" size={14} color={SEC} sw={1.6} />
      </div>
      <span style={{ fontSize: 12, color: SEC, marginBottom: 10 }}>Marla Vey, Kites &amp; Co</span>
      <span style={{ display: "block", width: 200, height: 4, borderRadius: 2, background: "rgba(255,255,255,0.18)", overflow: "hidden" }}>
        <span style={{ display: "block", width: 200 * (0.26 + (t - T.panel) * 0.008), height: 4, background: "#FFF" }} />
      </span>
      <span style={{ display: "flex", justifyContent: "space-between", fontSize: 9, fontWeight: 500, color: TER, marginTop: 4 }}>
        <span>0:34</span>
        <span>-1:39</span>
      </span>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", width: 156, marginLeft: 22, marginTop: 9 }}>
        <Glyph name="shuffle" size={13} color={SEC} sw={1.8} />
        <Glyph name="back" size={19} />
        <Glyph name="pause" size={22} />
        <Glyph name="fwd" size={19} />
        <Glyph name="repeat" size={13} color={SEC} sw={1.8} />
      </div>
    </div>
  </div>
);

const Mirror: React.FC = () => (
  <div style={{ position: "relative", width: 236, height: 236, borderRadius: 14, overflow: "hidden", background: "linear-gradient(180deg, #4B5C74, #26303F)" }}>
    <span style={{ position: "absolute", left: "50%", top: 52, width: 80, height: 80, marginLeft: -40, borderRadius: "50%", background: "#8E9DB4" }} />
    <span style={{ position: "absolute", left: "50%", top: 146, width: 168, height: 140, marginLeft: -84, borderRadius: "50%", background: "#8E9DB4" }} />
  </div>
);

const Note: React.FC = () => (
  <div style={{ display: "flex", gap: 9, alignItems: "center", padding: "7px 9px", borderRadius: 10, background: "rgba(255,255,255,0.08)" }}>
    <span style={{ width: 26, height: 26, borderRadius: 6, background: "linear-gradient(180deg, #5BE584, #1DB954)", display: "flex", alignItems: "center", justifyContent: "center", flex: "none" }}>
      <Glyph name="chat" size={15} sw={2.2} />
    </span>
    <div style={{ flex: 1, display: "flex", flexDirection: "column" }}>
      <div style={{ display: "flex", justifyContent: "space-between" }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: "#F5F5F7" }}>Giulia</span>
        <span style={{ fontSize: 10, color: TER }}>20:10</span>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between" }}>
        <span style={{ fontSize: 11, color: SEC }}>Are we still on for dinner?</span>
      </div>
    </div>
  </div>
);

const TimerRow: React.FC = () => (
  <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "0 8px", height: 30, borderRadius: 10, background: "rgba(255,255,255,0.08)" }}>
    <Glyph name="timer" size={14} color={ORANGE} sw={2} />
    <span style={{ flex: 1, fontSize: 12, fontWeight: 700, color: "#F5F5F7" }}>Timer</span>
    <span style={{ fontSize: 13, fontWeight: 700, color: ORANGE, fontVariantNumeric: "tabular-nums" }}>9:41</span>
  </div>
);

const Doc: React.FC = () => (
  <span style={{ position: "relative", display: "block", width: 24, height: 30, borderRadius: 3, background: "#F2F2F4", boxShadow: "0 6px 14px rgba(0,0,0,0.35)" }}>
    <span style={{ position: "absolute", right: 0, top: 0, width: 7, height: 7, background: "#CFCFD4", borderRadius: "0 3px 0 2px" }} />
    <span style={{ position: "absolute", left: 4, right: 4, top: 10, height: 1.5, background: "#C7C7CC" }} />
    <span style={{ position: "absolute", left: 4, right: 7, top: 14, height: 1.5, background: "#C7C7CC" }} />
    <span style={{ position: "absolute", left: 0, right: 0, bottom: 3, textAlign: "center", fontSize: 5.5, fontWeight: 800, color: "#FF453A" }}>PDF</span>
  </span>
);

const Shelf: React.FC = () => (
  <div style={{ padding: "8px 10px 8px", borderRadius: 12, background: "rgba(255,255,255,0.07)", display: "flex", flexDirection: "column", gap: 5 }}>
    <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
      <span style={{ flex: 1, fontSize: 11, fontWeight: 600, color: SEC }}>Shelf</span>
      <span style={{ height: 20, padding: "0 8px", borderRadius: 10, background: FILL, color: "#F5F5F7", fontSize: 11, fontWeight: 600, display: "flex", alignItems: "center" }}>AirDrop</span>
      <span style={{ height: 20, padding: "0 8px", borderRadius: 10, background: FILL, color: "#F5F5F7", fontSize: 11, fontWeight: 600, display: "flex", alignItems: "center" }}>Clear</span>
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <Doc />
      <span style={{ fontSize: 10.5, fontWeight: 600, color: "#F5F5F7" }}>Draft.pdf</span>
    </div>
  </div>
);

const SCRIPT = [
  "Hi everyone, and thanks for joining.",
  "",
  "Today I want to show you a small app",
  "I've been building for the Mac. It's called",
  "Brim, and it lives at the top of your screen.",
  "",
  "Most of us glance up there a hundred",
  "times a day.",
];

const Prompter: React.FC<{ t: number }> = ({ t }) => {
  const FS = 22;
  const LH = FS * 1.64;
  const reading = 260 / 3;
  // the script glides as you speak, word by word
  const scroll = anim(t, [[0, 0], [T.prompter + 0.9, 2, sp(0.9, 1)], [T.prompter + 1.9, 3, sp(0.9, 1)], [T.prompter + 2.9, 4, sp(0.9, 1)]]);
  const fade = "linear-gradient(180deg, transparent 0%, transparent 9%, #000 24%, #000 72%, transparent 97%)";
  return (
    <div style={{ position: "relative", width: 520, height: 260 }}>
      <div style={{ position: "absolute", inset: 0, WebkitMaskImage: fade, maskImage: fade }}>
        {SCRIPT.map((ln, i) =>
          ln ? (
            <div key={i} style={{ position: "absolute", left: 26, top: reading - LH * 0.55 + (i - scroll) * LH, fontSize: FS, fontWeight: 700, color: "#FFF", whiteSpace: "nowrap", lineHeight: `${LH}px`, letterSpacing: "-0.01em" }}>
              {ln}
            </div>
          ) : null,
        )}
      </div>
      <div style={{ position: "absolute", left: 9, top: reading - 8 }}>
        <Glyph name="play" size={12} color={ORANGE} />
      </div>
      <div style={{ position: "absolute", left: 18, right: 18, top: 12, display: "flex", alignItems: "center" }}>
        <span style={{ height: 24, padding: "0 8px", display: "flex", alignItems: "center", gap: 2 }}>
          {[0.6, 1, 0.8, 0.5].map((x, i) => (
            <span key={i} style={{ width: 2.5, height: 3 + 6 * x * (0.4 + 0.6 * Math.abs(Math.sin(t * 7 + i * 1.3))), borderRadius: 1.25, background: ORANGE }} />
          ))}
        </span>
        <span style={{ flex: 1 }} />
        <span style={{ height: 24, padding: "0 9px", borderRadius: 12, background: "rgba(255,255,255,0.08)", fontSize: 13, fontWeight: 700, color: "rgba(255,255,255,0.85)", display: "flex", alignItems: "center", fontVariantNumeric: "tabular-nums" }}>
          {`1:0${Math.max(3, 6 - Math.floor(t - T.prompter))}`}
        </span>
      </div>
      <div style={{ position: "absolute", left: "50%", top: 6, width: 5, height: 5, marginLeft: -2.5, borderRadius: "50%", background: ORANGE }} />
      <div style={{ position: "absolute", left: 32, top: 249, width: 456, height: 4, borderRadius: 2, background: "rgba(255,255,255,0.15)" }}>
        <div style={{ width: 4 + 456 * Math.max(0, (t - T.prompter) * 0.045), height: 4, borderRadius: 2, background: "rgba(255,255,255,0.75)" }} />
      </div>
    </div>
  );
};

const Lock: React.FC<{ t: number; w: number }> = ({ t, w }) => {
  const open = clamp01(sp(0.4, 0.75)(t - T.unlock));
  return (
    <div style={{ width: w, height: 54, display: "flex", alignItems: "center", justifyContent: "center" }}>
      <svg width={22} height={22} viewBox="0 0 24 24" fill="none" stroke="#FFF" strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round">
        <rect x={6.5} y={11} width={11} height={9.5} rx={1.5} fill="#FFF" />
        <path d="M8.8 11V8.2a3.2 3.2 0 0 1 6.4 0V11" style={{ transformOrigin: "15.2px 11px", rotate: `${open * 38}deg`, translate: `0px ${-open * 1.2}px` }} />
      </svg>
    </div>
  );
};

const Flare: React.FC<{ x: number; size: number; o: number; side: "left" | "right"; top: number }> = ({ x, size, o, side, top }) => (
  <svg width={size} height={size} viewBox="0 0 10 10" style={{ position: "absolute", left: side === "left" ? x - size + 0.5 : x - 0.5, top, opacity: o }}>
    <path d={side === "left" ? "M0 0 L10 0 L10 10 Q10 0 0 0 Z" : "M10 0 L0 0 L0 10 Q0 0 10 0 Z"} fill="#000" />
  </svg>
);

/** Soft colour that drifts behind the island while it turns to glass. */
const Bokeh: React.FC<{ t: number; cx: number; cy: number; c: number }> = ({ t, cx, cy, c }) => {
  const o = clamp01((t - T.glass) / 0.4) * (1 - clamp01((t - T.idle2 - 0.2) / 0.5));
  if (o <= 0) return null;
  const k = t - T.glass;
  const blob = (dx: number, dy: number, r: number, col: string) => (
    <div style={{ position: "absolute", left: cx + dx * c - r * c, top: cy + dy * c - r * c, width: 2 * r * c, height: 2 * r * c, borderRadius: "50%", background: col, filter: `blur(${14 * c}px)`, opacity: o * 0.85 }} />
  );
  return (
    <>
      {blob(-120 + k * 55, 4, 46, "rgba(255,138,91,0.75)")}
      {blob(130 - k * 50, -4, 42, "rgba(79,195,255,0.7)")}
    </>
  );
};

// ---------------- words ----------------
type Line = { text: string; a: number; b: number; hard?: boolean; big?: boolean };
const LINES: Line[] = [
  { text: "The top of your screen.", a: 0.75, b: 3.7 },
  { text: "Now playing.", a: T.live + 0.3, b: T.split - 0.2 },
  { text: "Two things at once.", a: T.split + 0.35, b: T.merge - 0.1 },
  ...["Notifications.", "Volume.", "Brightness.", "Backlight.", "Microphone.", "AirPods."].map((text, i) => ({
    text,
    a: T.hits[i],
    b: i < 5 ? T.hits[i + 1] : T.acts[0] - 0.15,
    hard: true,
  })),
  ...["Meetings.", "Calls.", "Reminders.", "Downloads."].map((text, i) => ({
    text,
    a: T.acts[i],
    b: i < 3 ? T.acts[i + 1] : T.panel - 0.8,
    hard: true,
  })),
  { text: "Everything, one hover away.", a: T.panel + 0.25, b: T.shelfDrop - 1.25 },
  { text: "Drop files on it.", a: T.shelfDrop - 0.9, b: T.shortcut - 0.55 },
  { text: "Your Shortcuts, one click away.", a: T.shortcut - 0.35, b: T.mirror - 0.3 },
  { text: "A mirror before every call.", a: T.mirror + 0.2, b: T.prompterClick - 0.1 },
  { text: "A teleprompter under the camera.", a: T.prompter + 0.15, b: T.prompter + 1.75 },
  { text: "It follows your voice.", a: T.prompter + 1.95, b: T.lock - 0.15 },
  { text: "Even on the lock screen.", a: T.lock + 0.3, b: T.unlock - 0.1 },
  { text: "In the notch.", a: T.notch + 0.35, b: T.float - 0.1 },
  { text: "Or floating.", a: T.float + 0.2, b: T.glass - 0.15 },
  { text: "From black to clear glass.", a: T.glass + 0.2, b: T.idle2 - 0.1 },
  ...["Free.", "No account. No tracking.", "Asks only for what it needs.", "Native, and light on your Mac."].map((text, i) => ({
    text,
    a: T.points[i],
    b: i < 3 ? T.points[i + 1] : T.icon - 0.1,
    hard: true,
    big: true,
  })),
];

const Words: React.FC<{ t: number; y: number; size: number }> = ({ t, y, size }) => {
  const line = LINES.find((l) => t >= l.a - 0.02 && t < (l.hard ? l.b : l.b + 0.3));
  if (!line) return null;
  const ws = line.text.split(" ");
  const out = line.hard ? 0 : clamp01((t - line.b) / 0.3);
  const fs = line.big ? size * 1.12 : size;
  return (
    <div
      style={{
        position: "absolute",
        left: "6%",
        right: "6%",
        top: y,
        display: "flex",
        flexWrap: "wrap",
        justifyContent: "center",
        gap: `0 ${fs * 0.26}px`,
        fontSize: fs,
        fontWeight: 700,
        letterSpacing: "-0.025em",
        lineHeight: 1.08,
        color: "#FFF",
        opacity: 1 - out,
        filter: out > 0 ? `blur(${out * 6}px)` : undefined,
      }}
    >
      {ws.map((wd, i) => {
        const p = clamp01(sp(0.4, 0.9)(t - line.a - (line.hard ? 0 : i * 0.07)));
        return (
          <span key={i} style={{ opacity: clamp01(p * 1.4), filter: `blur(${(1 - clamp01(p)) * 6}px)`, translate: `0px ${(1 - p) * fs * 0.3}px`, display: "inline-block" }}>
            {wd}
          </span>
        );
      })}
    </div>
  );
};

const EndCard: React.FC<{ t: number; land: boolean; portrait: boolean; base: number; cx: number; cy: number; iconPx: number; VW: number }> = ({
  t,
  land,
  portrait,
  base,
  cx,
  cy,
  iconPx,
  VW,
}) => {
  if (t < T.lockup) return null;
  const word = clamp01(sp(0.45, 0.9)(t - T.lockup - 0.15));
  const tag = clamp01(sp(0.45, 0.9)(t - T.lockup - 0.6));
  const free = clamp01(sp(0.45, 0.9)(t - bar(25)));
  const iconVisible = iconPx * (824 / 1024);
  const markSize = land ? 170 * base : portrait ? 150 : 120;
  const left = land ? cx + iconVisible / 2 + 56 * base : 0;
  const top = land ? cy - markSize * 0.66 : cy + iconVisible / 2 + 40 * base;
  const tr = (p: number): React.CSSProperties => ({ opacity: p, filter: `blur(${(1 - p) * 6}px)`, translate: `0px ${(1 - p) * 24}px` });
  return (
    <div style={{ position: "absolute", left, width: land ? undefined : VW, top, display: "flex", flexDirection: "column", alignItems: land ? "flex-start" : "center", textAlign: land ? "left" : "center" }}>
      <span style={{ fontSize: markSize, fontWeight: 800, letterSpacing: "-0.045em", color: "#FFF", lineHeight: 1, ...tr(word) }}>Brim</span>
      <span style={{ fontSize: markSize * 0.24, fontWeight: 600, color: "rgba(235,235,245,0.78)", marginTop: markSize * 0.12, maxWidth: land ? undefined : VW * 0.86, ...tr(tag) }}>
        The top of your screen, put to work.
      </span>
      <span style={{ fontSize: markSize * 0.17, fontWeight: 600, color: "rgba(235,235,245,0.55)", marginTop: markSize * 0.1, ...tr(free) }}>Free for macOS, on GitHub</span>
    </div>
  );
};
