import { Easing } from "remotion";

export type Ease = (x: number) => number;

// Curves chosen by what each move is: snaps land fast, holds ease both ends,
// landings spring a little past and settle.
export const snap: Ease = Easing.bezier(0.16, 1, 0.3, 1);
export const inOut: Ease = Easing.bezier(0.65, 0, 0.35, 1);
export const easeIn: Ease = Easing.bezier(0.55, 0, 1, 0.45);
export const spring: Ease = (p) => {
  if (p <= 0) return 0;
  if (p >= 1) return 1;
  return 1 - Math.exp(-5.2 * p) * Math.cos(2 * Math.PI * 0.82 * p) * (1 - p * 0.15);
};
export const linear: Ease = (p) => p;

/** A track of keys: [time, value, ease used to arrive at this key]. */
export type Key = [number, number, Ease?];

export const track = (t: number, keys: Key[]): number => {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [t1, v1, e] = keys[i];
    const [t0, v0] = keys[i - 1];
    if (t <= t1) {
      const p = t1 === t0 ? 1 : (t - t0) / (t1 - t0);
      return v0 + (v1 - v0) * (e ?? inOut)(p);
    }
  }
  return keys[keys.length - 1][1];
};

/** 0 to 1 over [a, b] with an ease, clamped. */
export const ramp = (t: number, a: number, b: number, e: Ease = snap) =>
  t <= a ? 0 : t >= b ? 1 : e((t - a) / (b - a));

/** Visible from a to b with fade lengths fi and fo. */
export const window = (t: number, a: number, b: number, fi = 0.25, fo = 0.25) =>
  Math.min(ramp(t, a, a + fi, snap), 1 - ramp(t, b - fo, b, inOut));

export const mix = (a: number, b: number, p: number) => a + (b - a) * p;
