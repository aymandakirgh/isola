import { getSvgPath } from "figma-squircle";

export type Radii = {
  topLeft: number;
  topRight: number;
  bottomRight: number;
  bottomLeft: number;
};

const SMOOTHING = 0.65;

export const squirclePath = (width: number, height: number, r: Radii) =>
  getSvgPath({
    width,
    height,
    topLeftCornerRadius: r.topLeft,
    topRightCornerRadius: r.topRight,
    bottomRightCornerRadius: r.bottomRight,
    bottomLeftCornerRadius: r.bottomLeft,
    cornerSmoothing: SMOOTHING,
    preserveSmoothing: true,
  });

const px = (v: string) => {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : Number.MAX_SAFE_INTEGER;
};
const radiiOf = (s: CSSStyleDeclaration): Radii => ({
  topLeft: px(s.borderTopLeftRadius),
  topRight: px(s.borderTopRightRadius),
  bottomRight: px(s.borderBottomRightRadius),
  bottomLeft: px(s.borderBottomLeftRadius),
});

// Absolute M/L coordinates shifted by d (figma-squircle's curves are relative).
const offset = (path: string, d: number) =>
  path.replace(
    /([ML]) (-?[\d.]+) (-?[\d.]+)/g,
    (_, c, x, y) => `${c} ${+x + d} ${+y + d}`,
  );

type El = HTMLElement & { _radius?: string };

function clear(el: El) {
  el.style.clipPath = "";
  if (el._radius !== undefined) {
    el.style.borderRadius = el._radius;
    delete el._radius;
  }
}

function apply(el: El, ring?: number) {
  if (el._radius !== undefined) el.style.borderRadius = el._radius;
  const s = getComputedStyle(el);
  const w = parseFloat(s.width);
  const h = parseFloat(s.height);
  if (!w || !h) return;
  const r = radiiOf(s);
  const values = Object.values(r);
  // Tiny radii or a true circle: plain border-radius already looks right.
  if (
    values.every((v) => v < 2) ||
    (Math.abs(w - h) <= 1 && values.every((v) => v >= Math.min(w, h) / 2 - 0.5))
  )
    return clear(el);
  el._radius ??= el.style.borderRadius;
  el.style.borderRadius = "0";
  if (!ring) {
    el.style.clipPath = `path('${squirclePath(w, h, r)}')`;
    return;
  }
  const inner: Radii = {
    topLeft: Math.max(0, r.topLeft - ring),
    topRight: Math.max(0, r.topRight - ring),
    bottomRight: Math.max(0, r.bottomRight - ring),
    bottomLeft: Math.max(0, r.bottomLeft - ring),
  };
  const hole = offset(squirclePath(w - ring * 2, h - ring * 2, inner), ring);
  el.style.clipPath = `path(evenodd, '${squirclePath(w, h, r)} ${hole}')`;
}

// Apply without animating: a transitioning border-radius would fight the clip.
function applyNow(el: El, ring?: number) {
  if (!/\ball\b|border-radius/.test(getComputedStyle(el).transitionProperty))
    return apply(el, ring);
  const prev = el.style.transitionProperty;
  el.style.transitionProperty = "none";
  apply(el, ring);
  void el.offsetHeight;
  el.style.transitionProperty = prev;
}

// One shared ResizeObserver, flushed once per frame.
const listeners = new Map<Element, Set<() => void>>();
const dirty = new Set<Element>();
let observer: ResizeObserver | null = null;
let frame = 0;
const flush = () => {
  frame = 0;
  const els = [...dirty];
  dirty.clear();
  for (const el of els) listeners.get(el)?.forEach((fn) => fn());
};
const schedule = () => (frame ||= requestAnimationFrame(flush));

function watch(el: Element, fn: () => void) {
  observer ??= new ResizeObserver((entries) => {
    for (const e of entries) dirty.add(e.target);
    schedule();
  });
  let set = listeners.get(el);
  if (!set) {
    listeners.set(el, (set = new Set()));
    observer.observe(el);
  }
  set.add(fn);
  return () => {
    set.delete(fn);
    if (set.size) return;
    listeners.delete(el);
    observer?.unobserve(el);
  };
}

/**
 * Ref factory: turns an element's CSS border-radius into a smooth (Figma-style)
 * squircle clip. `ring` clips to a band of that width; `fromParent` takes the
 * parent's radius plus `ring` (for outlines sitting just outside the parent).
 */
export function squircleRef(ring?: number, fromParent = false) {
  return (node: HTMLElement | SVGElement | null) => {
    const el = node as El | null;
    const parent = fromParent ? (el?.parentElement ?? null) : null;
    if (!el || (fromParent && !parent)) return;
    const update = () => {
      if (parent) {
        clear(el);
        el.style.borderRadius = Object.values(radiiOf(getComputedStyle(parent)))
          .map((v) => `${v + (ring ?? 0)}px`)
          .join(" ");
      }
      applyNow(el, ring);
    };
    el.setAttribute("data-squircle", "");
    update();
    const stop = watch(el, update);
    return () => {
      stop();
      el.removeAttribute("data-squircle");
      clear(el);
    };
  };
}

export const squircle = squircleRef();
export const squircleRing1 = squircleRef(1);
export const focusRingRef = squircleRef(2, true);
