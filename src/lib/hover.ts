import { subtreeTransitionMs } from "./frame";

/**
 * After a hover animation has (almost) fully played, leaving snaps the icon back
 * instantly instead of rewinding it; leaving mid-animation still rewinds smoothly.
 */
export function snapBackRef(el: HTMLElement | null) {
  if (!el) return;
  let enteredAt = 0;
  let longest = 0;
  const enter = () => {
    enteredAt = performance.now();
    requestAnimationFrame(() => (longest = subtreeTransitionMs(el)));
  };
  const leave = () => {
    if (performance.now() - enteredAt < longest * 0.88) return;
    el.classList.add("snap-back");
    void el.offsetWidth;
    el.classList.remove("snap-back");
  };
  el.addEventListener("pointerenter", enter);
  el.addEventListener("pointerleave", leave);
  return () => {
    el.removeEventListener("pointerenter", enter);
    el.removeEventListener("pointerleave", leave);
  };
}

/** Pointer-enter plays the `flourishing:` animation to completion, even on a brief hover. */
export function flourishRef(el: HTMLElement | null) {
  if (!el) return;
  let timer = 0;
  const play = () => {
    clearTimeout(timer);
    el.classList.add("flourish");
    requestAnimationFrame(() => (timer = window.setTimeout(() => el.classList.remove("flourish"), subtreeTransitionMs(el))));
  };
  el.addEventListener("pointerenter", play);
  return () => {
    clearTimeout(timer);
    el.removeEventListener("pointerenter", play);
  };
}
