import type { Ref, RefObject } from "react";

/** Run after the next paint (two animation frames). */
export const nextFrame = (cb: () => void) =>
  requestAnimationFrame(() => requestAnimationFrame(cb));

export const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Longest transition (duration + delay) currently applied to an element, in ms. */
export function transitionMs(el: Element) {
  const { transitionDuration, transitionDelay } = getComputedStyle(el);
  const delays = transitionDelay.split(", ");
  return transitionDuration.split(", ").reduce((max, d, i) => {
    const ms = (parseFloat(d) + parseFloat(delays[i % delays.length])) * 1000;
    return Number.isFinite(ms) ? Math.max(max, ms) : max;
  }, 0);
}

/** Longest transition among an element's descendants, in ms. */
export const subtreeTransitionMs = (el: Element) =>
  [...el.querySelectorAll("*")].reduce(
    (max, c) => Math.max(max, transitionMs(c)),
    0,
  );

/** Combine refs; always returns a cleanup so React 19 detaches through it. */
export function mergeRefs<T>(...refs: (Ref<T> | undefined)[]) {
  return (el: T | null) => {
    const cleanups: (() => void)[] = [];
    for (const r of refs) {
      if (!r) continue;
      if (typeof r === "function") {
        const c = r(el);
        cleanups.push(typeof c === "function" ? c : () => r(null));
      } else {
        (r as RefObject<T | null>).current = el;
        cleanups.push(() => ((r as RefObject<T | null>).current = null));
      }
    }
    return () => cleanups.forEach((c) => c());
  };
}
