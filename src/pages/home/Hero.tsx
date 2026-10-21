import { animate } from "motion";
import { useEffect, useRef } from "react";
import { AppleButton, Button } from "../../components/Button";
import {
  APPLE_BODY_PATH,
  APPLE_LEAF_PATH,
  CHECK_PATH,
  ClockIcon,
  SEAL_PATH,
} from "../../components/icons";
import { PRICE, PURCHASE_URL, TRIAL } from "../../config";
import { useMaxWidth, useMinWidth } from "../../lib/breakpoints";
import { squircle } from "../../lib/squircle";
import { Transition } from "../../lib/transition";

/** Purchase button: the seal spins while hovered and gives an extra flick on the way out. */
function PurchaseButton() {
  const seal = useRef<SVGGElement>(null);
  const hoverTimer = useRef(0);
  const armed = useRef(false);
  const flicking = useRef(false);
  useEffect(() => () => clearTimeout(hoverTimer.current), []);
  return (
    <Button
      className="pl-6"
      href={PURCHASE_URL}
      type="info"
      data-an="purchase"
      aria-label="Purchase"
      onMouseEnter={() => {
        hoverTimer.current = window.setTimeout(
          () => (armed.current = true),
          100,
        );
      }}
      onMouseLeave={() => {
        clearTimeout(hoverTimer.current);
        if (!armed.current || flicking.current || !seal.current) return;
        armed.current = false;
        flicking.current = true;
        animate(
          seal.current,
          { transform: ["rotate(0)", "rotate(45deg)"] },
          { duration: 0.5, ease: "easeOut" },
        ).finished.then(() => (flicking.current = false));
      }}
    >
      <svg
        className="mr-2.5 h-[22px] w-[22px] fill-current"
        viewBox="0 0 28 28"
        aria-hidden="true"
      >
        <g ref={seal} className="origin-center fill-current">
          <path
            className="group-hover:running pause animate-rotate origin-center text-orange-950/25 transition duration-300 group-hover:text-rose-400/75"
            d={SEAL_PATH}
          />
        </g>
        <path className="text-[#f5e5d5]" d={CHECK_PATH} />
      </svg>
      <span>Purchase</span>
      <span
        ref={squircle}
        className="text-orange-75 ml-3.5 rounded-lg bg-stone-800 px-2 py-1 text-sm tracking-wide"
      >
        ${PRICE}
      </span>
    </Button>
  );
}

function TrialNote() {
  return (
    <div className="group flex flex-col items-center justify-center outline-hidden select-none">
      <p className="text-sm font-bold text-orange-950/40">Trial available</p>
      <div className="mt-0.5 -ml-2 flex items-center justify-center">
        <ClockIcon className="mr-1 size-[22px] fill-current text-orange-950/30" />
        <p className="text-lg leading-tight font-bold text-orange-950/60">
          {TRIAL} duration
        </p>
      </div>
    </div>
  );
}

export function Hero() {
  const lg = useMinWidth("lg");
  const md = useMinWidth("md");
  const phone = useMaxWidth("sm");
  return (
    <section className="mb-14 w-full sm:mb-20 xl:w-4/5 xl:max-w-(--breakpoint-lg)">
      <Transition
        enterFrom="rotate-2 translate-y-8 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <h1 className="relative text-center text-5xl leading-[1.05] font-bold tracking-tight opacity-0 delay-150 sm:text-8xl sm:leading-none">
          Dynamic Island{lg ? "." : ""}
          <br />
          {lg ? "Now " : ""} for {md ? "your " : ""}
          <mark className="relative">
            <svg
              className="absolute -bottom-0.5 -left-0.5 size-13 overflow-visible fill-current sm:-bottom-1.5 sm:-left-2 sm:size-25"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <Transition
                css={false}
                appear
                onEnter={(el) => {
                  animate(
                    el,
                    { y: [10, 0] },
                    { type: "spring", stiffness: 60, damping: 6, delay: 0.35 },
                  );
                }}
              >
                <path d={APPLE_LEAF_PATH} />
              </Transition>
              <path d={APPLE_BODY_PATH} />
            </svg>
            <span className="pl-[46px] sm:pl-21">Mac</span>
          </mark>
        </h1>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="mt-14 flex flex-col items-center justify-center space-y-6 opacity-0 delay-300 sm:mt-12 sm:flex-row sm:space-y-0 sm:space-x-7">
          <AppleButton
            href={phone ? PURCHASE_URL : "/download"}
            label={phone ? "Purchase for Mac" : "Download for Mac"}
            data-an={phone ? "purchase" : "download"}
            aria-label={phone ? "Purchase for Mac" : "Download for Mac"}
          />
          {phone ? <TrialNote /> : <PurchaseButton />}
        </div>
      </Transition>
    </section>
  );
}
