import { useId, type ReactNode } from "react";
import {
  BellIcon,
  BlazingScribble,
  BoltIcon,
  GiftIcon,
  HudIcon,
  LiveActivityIcon,
  LockScreenIcon,
  SwipeIcon,
} from "../../components/icons";

/** Draw the scribble each time it scrolls into view. */
function drawWhenVisible(el: SVGSVGElement | null) {
  if (!el) return;
  const io = new IntersectionObserver(([entry]) => {
    el.classList.toggle("animate-draw", entry.isIntersecting);
    el.classList.toggle("delay-500", entry.isIntersecting);
  });
  io.observe(el);
  return () => io.disconnect();
}

function Feature({
  className = "group flex flex-col items-center justify-center text-center",
  heading = "text-3xl font-bold",
  icon,
  children,
}: {
  className?: string;
  heading?: string;
  icon: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className={className}>
      {icon}
      <h2 className={heading}>{children}</h2>
    </div>
  );
}

/** Two blobs that trade places through a goo filter. */
function GooeyIcon() {
  const id = useId().replace(/[^a-zA-Z0-9]/g, "");
  return (
    <svg
      className="mb-5 h-18 w-28 overflow-visible fill-stone-800"
      viewBox="0 0 112 72"
      aria-hidden="true"
    >
      <defs>
        <filter
          id={id}
          x="-20"
          y="-20"
          width="152"
          height="112"
          filterUnits="userSpaceOnUse"
        >
          <feGaussianBlur in="SourceGraphic" stdDeviation="6" result="blur" />
          <feColorMatrix
            in="blur"
            mode="matrix"
            values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 20 -10"
            result="gooey"
          />
          <feComposite in="SourceGraphic" in2="gooey" operator="atop" />
        </filter>
      </defs>
      <g filter={`url(#${id})`}>
        <circle
          className="transition-[cx] duration-700 group-hover:[cx:81px]"
          cx="37"
          cy="36"
          r="22"
        />
        <circle
          className="transition-[cx] duration-700 group-hover:[cx:35px]"
          cx="83"
          cy="36"
          r="14"
        />
      </g>
    </svg>
  );
}

export function Features() {
  return (
    <div className="mx-auto grid w-full gap-x-3 gap-y-10 tracking-tight sm:max-w-(--breakpoint-lg) sm:grid-cols-2 sm:gap-y-14 lg:grid-cols-4">
      <Feature icon={<GooeyIcon />}>
        Fluid
        <br />
        transitions
      </Feature>
      <Feature
        icon={
          <BellIcon className="mb-5 size-18 overflow-visible fill-current" />
        }
      >
        Instant <br />
        Notifications
      </Feature>
      <Feature
        icon={<LiveActivityIcon className="mb-5 size-18 fill-current" />}
      >
        Live
        <br />
        Activities
      </Feature>
      <Feature
        icon={
          <SwipeIcon className="mb-5 size-18 overflow-visible fill-current" />
        }
      >
        Swipe
        <br />
        gestures
      </Feature>
      <Feature
        heading="w-full text-3xl font-bold"
        icon={
          <GiftIcon className="mb-5 size-18 overflow-visible fill-current transition duration-300 group-hover:-translate-y-px group-hover:-rotate-2" />
        }
      >
        Packed with
        <br />
        surprises
      </Feature>
      <Feature icon={<HudIcon className="mb-5 size-18 fill-current" />}>
        Customizable
        <br />
        HUDs
      </Feature>
      <Feature icon={<LockScreenIcon className="mb-5 size-18 fill-current" />}>
        Lock Screen
        <br />
        Widgets
      </Feature>
      <div className="group relative flex flex-col items-center justify-center text-center">
        <BoltIcon className="mb-5 size-18 overflow-visible fill-current" />
        <h2 className="relative z-10 text-3xl font-bold">
          Blazing fast
          <br />
          native app
        </h2>
        <div className="absolute right-0 -bottom-3.5 left-0 flex items-center justify-center">
          <BlazingScribble
            ref={drawWhenVisible}
            className="w-44 fill-transparent stroke-current stroke-[0.1875rem] text-purple-400/95"
          />
        </div>
      </div>
    </div>
  );
}
