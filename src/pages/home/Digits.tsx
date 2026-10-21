import { animate } from "motion";
import { useRef } from "react";
import { Transition } from "../../lib/transition";

/**
 * A number whose changed digits roll in (springy, from below when counting up)
 * while the old ones blur away; the box width eases to fit.
 */
export function Digits({
  count = 0,
  animateWidth = true,
}: {
  count?: number | string;
  animateWidth?: boolean;
}) {
  const box = useRef<HTMLDivElement>(null);
  const prev = useRef(count);
  const first = useRef(true);
  const rising = useRef(false);
  if (prev.current !== count) {
    rising.current = Number(count) > Number(prev.current);
    prev.current = count;
    first.current = false;
  }
  const chars = [...String(count)];

  const enter = (el: HTMLElement, done: () => void) => {
    const container = box.current;
    if (first.current || !container) return done();
    el.style.position = "";
    el.style.top = "";
    el.style.left = "";
    const { width, height } = container.getBoundingClientRect();
    // Width once leaving digits are gone: only children that match the new value.
    const target = [
      ...container.querySelectorAll<HTMLElement>(":scope > *"),
    ].reduce(
      (w, c) =>
        chars[Number(c.dataset.index)] === c.textContent
          ? w + c.offsetWidth
          : w,
      0,
    );
    if (animateWidth && width !== target)
      animate(
        container,
        {
          width: [`${width}px`, `${target}px`],
          height: [`${height}px`, `${height}px`],
        },
        { duration: 0.25 },
      );
    const shift = el.offsetHeight / 3;
    animate(
      el,
      {
        scale: [0.8, 1],
        y: [rising.current ? `${shift}px` : `-${shift}px`, "0"],
        opacity: [0, 1],
        filter: [`blur(${el.offsetHeight / 6}px)`, "blur(0)"],
      },
      { type: "spring", stiffness: 150, damping: 14 },
    ).finished.then(() => {
      el.removeAttribute("style");
      done();
    });
  };

  const leave = (el: HTMLElement, done: () => void) => {
    if (first.current) return done();
    const { width } = el.getBoundingClientRect();
    const half = el.offsetHeight / 2;
    el.style.position = "absolute";
    animate(
      el,
      {
        top: [0, null],
        left: [`${width * Number(el.dataset.index)}px`, null],
        scale: [1, 0.6],
        y: [0, rising.current ? `-${half}px` : `${half}px`],
        opacity: [1, 0],
        filter: ["blur(0)", `blur(${el.offsetHeight / 6}px)`],
      },
      { duration: 0.4 },
    ).finished.then(done);
  };

  return (
    <div ref={box} className="relative inline-flex tabular-nums">
      {chars.map((c, i) => (
        <Transition key={i} css={false} appear onEnter={enter} onLeave={leave}>
          <span key={c} data-index={i}>
            {c}
          </span>
        </Transition>
      ))}
    </div>
  );
}
