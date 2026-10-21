// Preloaded <audio> elements are handed out once, then a fresh one is created.
const clamp = (v: number) => Math.min(1, Math.max(0, v));
const pool = new Map<string, HTMLAudioElement>();

export function preloadSound(src: string) {
  if (!("Audio" in globalThis)) return null;
  let a = pool.get(src);
  if (!a) {
    a = new Audio(src);
    a.preload = "auto";
    a.load();
    pool.set(src, a);
  }
  return a;
}

export function takeSound(src: string) {
  if (!("Audio" in globalThis)) return null;
  const a = pool.get(src) ?? new Audio(src);
  pool.delete(src);
  return a;
}

export function playSound(src: string, { volume = 1 } = {}) {
  const a = takeSound(src);
  if (!a) return null;
  a.volume = clamp(volume);
  a.play()?.catch(() => {});
  return a;
}

/** Linear volume ramp; returns a cancel function. */
export function fadeVolume(a: HTMLAudioElement | null, from: number, to: number, ms: number) {
  if (!a) return () => {};
  const start = performance.now();
  let raf = 0;
  a.volume = clamp(from);
  const step = (t: number) => {
    const p = Math.min(1, (t - start) / ms);
    a.volume = clamp(from + (to - from) * p);
    if (p < 1) raf = requestAnimationFrame(step);
  };
  raf = requestAnimationFrame(step);
  return () => cancelAnimationFrame(raf);
}
