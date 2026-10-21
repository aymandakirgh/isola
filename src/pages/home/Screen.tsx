import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type Ref,
} from "react";
import {
  AppleLogo,
  APPLE_BODY_PATH,
  BackwardIcon,
  BedIcon,
  ControlCenterIcon,
  ForwardIcon,
  LaptopOutputIcon,
  MenuBarAppIcon,
  MoonIcon,
  PlayIcon,
  ShuffleIcon,
  SunIcon,
  WifiIcon,
  WorkIcon,
} from "../../components/icons";
import { BRAND, SIBLING_APP } from "../../config";
import { useMaxWidth, useMinWidth } from "../../lib/breakpoints";
import { cn } from "../../lib/cn";
import {
  dayOfMonth,
  formatMonth,
  formatWeekday,
  hours,
  isNight,
  minutes,
} from "../../lib/datetime";
import { mergeRefs } from "../../lib/frame";
import { squircle, squircleRing1 } from "../../lib/squircle";
import { Transition } from "../../lib/transition";
import { Digits } from "./Digits";
import { Notch } from "./Notch";
import type { Track } from "./stores";

type Slot = {
  className?: string;
  style?: CSSProperties;
  ref?: Ref<HTMLDivElement>;
};

// Privacy lock shackle that replaces the Apple leaf on hover (24x24 space).
const SHACKLE_PATH =
  "M8.15 5.4h1.55v-.95c0-1.9 1.1-2.85 2.32-2.85s2.33.95 2.33 2.85v.95h1.55V4.3C15.9 1.62 14.17.2 12.02.2 9.88.2 8.15 1.62 8.15 4.3z";
const SWAP = {
  enterFrom: "opacity-0 scale-50 blur-xs -rotate-60",
  enterActive: "transition duration-500",
  leaveActive: "transition duration-500",
  leaveTo: "opacity-0 scale-50 blur-xs -rotate-60",
};

export function LockScreen({
  now,
  className,
  style,
  ref,
}: Slot & { now: Date }) {
  const md = useMinWidth("md");
  const night = isNight(now);
  return (
    <div
      ref={ref}
      style={style}
      className={cn(
        "absolute inset-0 z-10 mt-22 mb-6 flex flex-col items-center justify-end md:justify-between lg:mt-23",
        className,
      )}
    >
      <div className="flex flex-col items-center">
        {md ? (
          <div className="flex flex-col items-center text-center">
            <time className="text-3xl font-semibold text-purple-300/85 saturate-150">
              <span>{formatWeekday(now)}, </span>
              <Digits count={dayOfMonth(now)} />
              <span> {formatMonth(now)}</span>
            </time>
            <time className="font-numeric text-8xl font-bold text-purple-300/90 saturate-150">
              <Digits count={hours(now)} />
              <span>:</span>
              <Digits count={minutes(now)} />
            </time>
          </div>
        ) : null}
        <div className="mt-3.5 hidden items-center space-x-5 font-semibold text-purple-300/90 saturate-150 lg:flex">
          <div className="relative flex w-18 items-center">
            <Transition {...SWAP}>
              {night ? (
                <div key="sleep" className="absolute flex w-18 items-center">
                  <div className="mr-2 ml-0.5 size-[18px]">
                    <BedIcon className="size-[18px] fill-current" />
                  </div>
                  <div>Sleep</div>
                </div>
              ) : (
                <div key="work" className="absolute flex w-18 items-center">
                  <div className="mr-1.5 ml-0.5 size-[18px]">
                    <WorkIcon className="absolute size-[18px] fill-current" />
                  </div>
                  <div>Work</div>
                </div>
              )}
            </Transition>
          </div>
          <div className="flex items-center">
            <div className="relative mr-[5px] ml-0.5 size-[18px]">
              <Transition {...SWAP}>
                {night ? (
                  <span key="moon" className="absolute size-[18px]">
                    <MoonIcon className="size-[18px] fill-current" />
                  </span>
                ) : (
                  <span key="sun" className="absolute size-[18px]">
                    <SunIcon className="size-[18px] fill-current" />
                  </span>
                )}
              </Transition>
            </div>
            <Digits count={night ? 16 : 24} />
            <div className="px-px">°</div>
          </div>
        </div>
      </div>
      <div className="shimmer animate-shine cursor-pointer bg-clip-text! p-6 text-2xl font-bold text-transparent saturate-150 sm:text-lg sm:font-semibold lg:p-4">
        Press to unlock
      </div>
    </div>
  );
}

function WidgetButton({
  dim = false,
  children,
}: {
  dim?: boolean;
  children: ReactNode;
}) {
  return (
    <div
      className={cn(
        "flex h-[46px] w-12 items-center justify-center rounded-2xl",
        dim ? "text-purple-300/75 saturate-150" : "text-orange-25",
      )}
    >
      {children}
    </div>
  );
}

/** Lock-screen media widget (2xl screens). */
export function NowPlayingWidget({
  track = null,
  className = "",
}: {
  track?: Track | null;
  className?: string;
}) {
  return (
    <div
      ref={squircle}
      className={cn(
        "relative isolate flex h-43.5 w-82 flex-col justify-center rounded-[1.75rem] p-4.25 backdrop-blur-2xl backdrop-saturate-115",
        className,
      )}
    >
      <span
        ref={squircle}
        className="absolute inset-px -z-10 rounded-[1.6875rem] bg-stone-900/15"
      />
      <span
        ref={squircleRing1}
        className="bg-orange-25/10 absolute inset-px -z-10 rounded-[1.6875rem]"
      />
      <span
        ref={squircleRing1}
        className="absolute inset-0 -z-10 rounded-[1.75rem] bg-stone-950/25"
      />
      <div className="flex items-center justify-between">
        {track ? (
          <div
            ref={squircle}
            className="size-14 shrink-0 scale-95 rounded-xl bg-cover! opacity-95"
            style={{ background: `url(${track.album_art})` }}
          />
        ) : (
          <div
            ref={squircle}
            className="size-14 shrink-0 rounded-xl bg-purple-300/10 saturate-150"
          />
        )}
        <div className="ml-4 grow">
          {track ? (
            <>
              <div className="text-orange-25 text-[13.5px] leading-4 font-semibold">
                {track.name}
              </div>
              <div className="text-[13px] leading-4 font-medium text-purple-300/75 saturate-150">
                {track.artist}
              </div>
            </>
          ) : (
            <div className="mb-4 text-[13.5px] leading-4 font-semibold text-purple-300/50 saturate-150">
              Not Playing
            </div>
          )}
        </div>
        <div className="mr-1 flex w-5 items-center justify-center space-x-0.5 brightness-110 saturate-150">
          {[1, 2, 3, 4, 5].map((i) => (
            <div key={i} className="size-0.5 rounded-[1px] bg-purple-300/25" />
          ))}
        </div>
      </div>
      <div className="mt-4 flex items-center justify-between space-x-2 text-[10px] leading-none font-bold whitespace-nowrap text-purple-300/75 saturate-150">
        <div>-:--</div>
        <div className="h-1.5 w-full rounded-full bg-purple-300/25 saturate-15" />
        <div>-:--</div>
      </div>
      <div className="flex grow items-end justify-center space-x-2">
        <WidgetButton dim>
          <ShuffleIcon className="size-[22px] fill-current" />
        </WidgetButton>
        <WidgetButton>
          <BackwardIcon className="size-[26px] fill-current" />
        </WidgetButton>
        <WidgetButton>
          <PlayIcon className="size-[34px] fill-current" />
        </WidgetButton>
        <WidgetButton>
          <ForwardIcon className="size-[26px] fill-current" />
        </WidgetButton>
        <WidgetButton dim>
          <LaptopOutputIcon className="size-[26px] fill-current" />
        </WidgetButton>
      </div>
    </div>
  );
}

/** Menu bar: privacy pill (left), the notch (centre), status items + clock (right). */
export function TopBar({ isLocked, now }: { isLocked: boolean; now: Date }) {
  const phone = useMaxWidth("sm");
  const reveal = {
    enterFrom: "-translate-y-5 opacity-0",
    enterActive: "transition duration-400 ease-out delay-100",
  };
  return (
    <div className="absolute top-0 right-0 left-0 z-20 flex justify-center sm:grid sm:grid-cols-3">
      {phone ? null : (
        <div className="flex p-5">
          <Transition {...reveal}>
            {isLocked ? null : (
              <div
                ref={squircle}
                className="flex h-10 items-center rounded-[0.625rem] rounded-tl-[1.25rem] bg-orange-50/10 backdrop-blur-xl backdrop-saturate-115"
              >
                <a
                  href="/privacy"
                  className="group relative flex h-full w-[62px] items-center justify-center text-orange-50 outline-hidden"
                  tabIndex={-1}
                  aria-label="Privacy policy"
                >
                  <div className="absolute size-[23px] opacity-100 transition delay-150 duration-200 group-hover:scale-75 group-hover:opacity-0 group-hover:blur-xs group-hover:delay-[0ms]">
                    <AppleLogo className="size-full fill-current" />
                  </div>
                  <div className="absolute size-[23px] scale-75 opacity-0 blur-xs transition delay-[0ms] duration-200 group-hover:scale-100 group-hover:opacity-100 group-hover:blur-none group-hover:delay-150">
                    <svg
                      className="size-full fill-current"
                      viewBox="0 0 24 24"
                      aria-hidden="true"
                    >
                      <path d={APPLE_BODY_PATH} />
                      <path d={SHACKLE_PATH} />
                    </svg>
                  </div>
                </a>
              </div>
            )}
          </Transition>
        </div>
      )}
      <div className="flex justify-center p-5">
        <Notch isLocked={isLocked} />
      </div>
      {phone ? null : (
        <div className="flex justify-end p-5">
          <Transition {...reveal}>
            {isLocked ? null : (
              <div
                ref={squircle}
                className="flex h-10 items-center justify-center space-x-5 rounded-[0.625rem] rounded-tr-[1.25rem] bg-orange-50/10 px-5 text-orange-50 backdrop-blur-xl backdrop-saturate-115"
              >
                <MenuBarAppIcon className="h-5 w-5" />
                <WifiIcon className="hidden h-5 w-5 fill-current text-orange-50 lg:block" />
                <ControlCenterIcon className="hidden h-5 w-5 fill-current text-orange-50 lg:block" />
                <time className="text-[15px] font-medium whitespace-nowrap">
                  <span className="hidden md:inline">{`${formatWeekday(now)} `}</span>
                  <Digits count={hours(now)} animateWidth={false} />
                  <span>:</span>
                  <Digits count={minutes(now)} animateWidth={false} />
                </time>
              </div>
            )}
          </Transition>
        </div>
      )}
    </div>
  );
}

function Tooltip({
  offset = 8,
  trigger,
  content,
}: {
  offset?: number;
  trigger: ReactNode;
  content: ReactNode;
}) {
  const triggerRef = useRef<HTMLSpanElement>(null);
  const tipRef = useRef<HTMLDivElement>(null);
  const [show, setShow] = useState(false);
  const [pos, setPos] = useState<CSSProperties>({ left: 0, top: 0 });
  const tipRefs = useMemo(() => mergeRefs(tipRef, squircle), []);

  useEffect(() => {
    const el = triggerRef.current;
    if (!el) return;
    const on = () => setShow(true);
    const off = () => setShow(false);
    el.addEventListener("mouseenter", on);
    el.addEventListener("mouseleave", off);
    return () => {
      el.removeEventListener("mouseenter", on);
      el.removeEventListener("mouseleave", off);
    };
  }, []);

  useEffect(() => {
    if (!show) return;
    let cancelled = false;
    document.fonts.ready.then(() =>
      requestAnimationFrame(() => {
        const t = triggerRef.current;
        const tip = tipRef.current;
        if (cancelled || !t || !tip) return;
        setPos({
          left: `${0.5 * (t.offsetWidth - tip.offsetWidth)}px`,
          top: `${-tip.offsetHeight - offset}px`,
        });
      }),
    );
    return () => {
      cancelled = true;
    };
  }, [show, offset]);

  return (
    <div className="relative inline-flex items-center select-none">
      <span
        ref={triggerRef}
        className="flex w-full items-center justify-center"
      >
        {trigger}
      </span>
      <Transition
        show={show}
        enterFrom="scale-90 opacity-0"
        enterActive="transition duration-200"
        leaveActive="transition duration-200"
        leaveTo="scale-90 opacity-0"
      >
        <div
          ref={tipRefs}
          className="absolute z-50 flex min-w-min origin-bottom flex-col rounded-xl bg-stone-950/65 px-3 py-1 text-sm font-medium whitespace-nowrap text-orange-50 drop-shadow-lg drop-shadow-stone-950/20 backdrop-blur-xs"
          style={pos}
        >
          {content}
        </div>
      </Transition>
    </div>
  );
}

function DockIcon({
  src,
  label,
  pressed,
  onPress,
}: {
  src: string;
  label: string;
  pressed: boolean;
  onPress: () => void;
}) {
  return (
    <div className="absolute inset-0 z-10 [filter:drop-shadow(0_1px_2.25px_color-mix(in_srgb,#0c0a09_30%,transparent))]">
      <picture>
        <source srcSet={`/images/${src}.webp`} type="image/webp" />
        <img
          className={cn(
            "size-full cursor-pointer object-contain transition-[filter] duration-100 select-none",
            pressed && "brightness-75",
          )}
          src={`/images/${src}.png`}
          alt={label}
          draggable={false}
          onMouseDown={onPress}
        />
      </picture>
    </div>
  );
}

export function Dock({ className, style, ref }: Slot) {
  const [pressed, setPressed] = useState<string | null>(null);
  useEffect(() => {
    const release = () => setPressed(null);
    window.addEventListener("mouseup", release);
    return () => window.removeEventListener("mouseup", release);
  }, []);
  const sibling = (
    <DockIcon
      src="brezza-app-icon"
      label={`${SIBLING_APP.name} App Icon`}
      pressed={pressed === "sibling"}
      onPress={() => setPressed("sibling")}
    />
  );
  return (
    <div
      ref={ref}
      style={style}
      className={cn(
        "absolute right-0 bottom-7 left-0 z-10 flex items-center justify-center",
        className,
      )}
    >
      <div className="relative isolate flex items-center justify-center gap-3 rounded-[28px] p-3">
        <span
          ref={squircle}
          className="absolute inset-0 -z-10 rounded-[inherit] bg-orange-50/15 backdrop-blur-xl backdrop-saturate-115"
        />
        <span
          ref={squircleRing1}
          className="pointer-events-none absolute inset-0 -z-10 rounded-[inherit] bg-orange-50/20 [mask-image:linear-gradient(to_bottom,black_0%,black_24%,transparent_70%)]"
        />
        <Tooltip
          offset={18}
          trigger={
            <div className="relative size-16">
              <DockIcon
                src="app-icon"
                label={`${BRAND} App Icon`}
                pressed={pressed === "app"}
                onPress={() => setPressed("app")}
              />
            </div>
          }
          content={BRAND}
        />
        <Tooltip
          offset={18}
          trigger={
            SIBLING_APP.url ? (
              <a
                className="relative block size-16 outline-hidden"
                href={SIBLING_APP.url}
                rel="noopener noreferrer"
                target="_blank"
                tabIndex={-1}
                aria-label={`${SIBLING_APP.name} Mac App`}
              >
                {sibling}
              </a>
            ) : (
              <div className="relative block size-16">{sibling}</div>
            )
          }
          content={SIBLING_APP.name}
        />
        <div ref={squircle} className="size-16 rounded-2xl bg-orange-50/15" />
        <div ref={squircle} className="size-16 rounded-2xl bg-orange-50/15" />
      </div>
    </div>
  );
}

/** Wallpaper with a gentle scroll parallax (the image is taller than its frame). */
export function Wallpaper() {
  const box = useRef<HTMLDivElement>(null);
  const img = useRef<HTMLImageElement>(null);
  const [progress, setProgress] = useState(0);
  const [overflow, setOverflow] = useState(0);
  const boxRef = useMemo(() => mergeRefs(box, squircle), []);

  useEffect(() => {
    const onScroll = () => {
      const d = document.documentElement;
      setProgress(d.scrollTop / (d.scrollHeight - window.innerHeight));
    };
    const onResize = () => {
      if (img.current && box.current)
        setOverflow(img.current.offsetHeight - box.current.offsetHeight);
    };
    window.addEventListener("scroll", onScroll);
    window.addEventListener("resize", onResize);
    requestAnimationFrame(onResize);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onResize);
    };
  }, []);

  return (
    <div
      ref={boxRef}
      className="rounded-5xl absolute top-0 right-0 left-0 h-48 w-full overflow-hidden bg-stone-900 sm:h-full"
    >
      <picture>
        <source
          media="(min-width: 640px)"
          srcSet="/images/wallpaper.webp"
          type="image/webp"
        />
        <source
          media="(max-width: 640px)"
          srcSet="/images/wallpaper-alt.webp"
          type="image/webp"
        />
        <img
          ref={img}
          className="aspect-video h-96 w-full object-cover blur-sm sm:h-auto sm:blur-none"
          fetchPriority="high"
          src="/images/wallpaper.jpg"
          alt="Wallpaper"
          style={{ transform: `translateY(${-progress * overflow}px)` }}
        />
      </picture>
    </div>
  );
}
