import { animate, type AnimationOptions } from "motion";
import { useCallback, useEffect, useRef, useState, type Ref } from "react";
import {
  MusicNoteIcon,
  NotchLockIcon,
  PAUSE_PATH,
  PLAY_PATH,
} from "../../components/icons";
import { cn } from "../../lib/cn";
import { squircle, squirclePath, type Radii } from "../../lib/squircle";
import { Transition } from "../../lib/transition";
import { currentTrack, useMusic, useNotchBus, type Track } from "./stores";

type Frame = Radii & { width: number; height: number };
type Spring = AnimationOptions;

const spring = (
  stiffness: number,
  damping: number,
  extra: Spring = {},
): Spring => ({
  type: "spring",
  stiffness,
  damping,
  mass: 1,
  ...extra,
});
const corners = (r: number): Radii => ({
  topLeft: r,
  topRight: r,
  bottomRight: r,
  bottomLeft: r,
});

const COMPACT = 112;
const EXPANDED = 186;
const MARQUEE_SPEED = 30; // px per second
const UNLOCK_SETTLE = 475; // ms the open shackle stays visible
const SIDE = {
  enterFrom: "opacity-0 blur-[10px] scale-x-0",
  enterActive: "transition duration-300",
  leaveActive: "transition duration-250",
  leaveTo: "opacity-0 blur-sm scale-x-[0.25]",
};
const BARS = [
  "animate-[playing_0.95s_ease_infinite]",
  "animate-[playing_1.46s_ease_infinite]",
  "animate-[playing_0.82s_ease_infinite]",
  "animate-[playing_1.24s_ease_infinite]",
];

/** Size + corner radii live in a plain object that springs drive; each frame repaints the clip. */
function useNotchFrame() {
  const notchRef = useRef<HTMLDivElement>(null);
  const innerRef = useRef<HTMLDivElement>(null);
  const frame = useRef<Frame>({ width: COMPACT, height: 40, ...corners(12) });
  const render = useCallback(() => {
    const notch = notchRef.current;
    const inner = innerRef.current;
    if (!notch || !inner) return;
    const { width, height, ...r } = frame.current;
    notch.style.width = `${width}px`;
    notch.style.height = `${height}px`;
    notch.style.borderRadius = `${r.topLeft}px ${r.topRight}px ${r.bottomRight}px ${r.bottomLeft}px`;
    inner.style.clipPath = `path('${squirclePath(width, height, r)}')`;
  }, []);
  const animateFrame = useCallback(
    (to: Partial<Frame>, options: Spring) =>
      animate(frame.current, to, { ...options, onUpdate: render }),
    [render],
  );
  return { notchRef, innerRef, render, animateFrame };
}

function TrackLabel({
  track,
  className,
}: {
  track: Track;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "inline-flex shrink-0 items-center px-1.5 whitespace-nowrap",
        className,
      )}
    >
      <MusicNoteIcon className="mr-0.5 size-[15px] fill-current text-stone-600" />
      <span>{track.name}</span>
      <span className="mx-0.5 text-stone-600">∙</span>
      <span>{track.artist}</span>
    </div>
  );
}

function Marquee({
  ref,
  marqueeRef,
}: {
  ref: Ref<HTMLDivElement>;
  marqueeRef: Ref<HTMLDivElement>;
}) {
  const music = useMusic();
  const track = currentTrack(music);
  return (
    <div
      ref={ref}
      className="pointer-events-none absolute right-0 bottom-0 left-0 flex origin-top justify-center mask-[linear-gradient(to_left,rgba(0,0,0,0)_7%,rgba(0,0,0,1)_11%,rgba(0,0,0,1)_89%,rgba(0,0,0,0)_93%)] pb-[11px] text-xs font-semibold text-stone-300/85 opacity-0"
    >
      {music.tracks && track ? (
        <div ref={marqueeRef} className="relative flex">
          <TrackLabel
            track={track}
            className="animate-[marquee-first_var(--marquee-duration)_linear_infinite]"
          />
          <TrackLabel
            track={track}
            className="absolute top-0 animate-[marquee-second_var(--marquee-duration)_linear_infinite]"
          />
        </div>
      ) : null}
    </div>
  );
}

function NotchLeft({
  notification,
  activity,
  unlocked,
  peeking,
  onPeekEnter,
  onPeekLeave,
}: {
  notification: string | null;
  activity: string | null;
  unlocked: boolean;
  peeking: boolean;
  onPeekEnter: () => void;
  onPeekLeave: () => void;
}) {
  const music = useMusic();
  const track = currentTrack(music);
  return (
    <div className="absolute top-0 left-0 flex h-10 items-center">
      <Transition {...SIDE}>
        {notification === "didConnectAirPods" ? (
          <div
            key="earbuds-left"
            className="flex h-full items-center pb-0.5 pl-1.5"
          >
            <video className="size-8" autoPlay loop muted playsInline>
              <source src="/videos/earbuds.mp4" type="video/mp4" />
            </video>
          </div>
        ) : activity === "isLocked" ? (
          <div key="locked" className="pl-2.5">
            <NotchLockIcon
              unlocked={unlocked}
              className="size-[18px] fill-current"
            />
          </div>
        ) : activity === "isPlaying" && track ? (
          <div
            key="playing-left"
            className={cn(
              "origin-[20%_0%] pl-[9px] transition duration-300",
              peeking && "scale-[1.20]",
            )}
          >
            {/* Two nested mirror flips cancel out: the art squeezes and returns, like a card turn. */}
            <div
              className={cn(
                "transition duration-500",
                music.isFlipped && "-scale-x-100",
              )}
            >
              <div
                className={cn(
                  "transition duration-500",
                  music.isFlipped && "-scale-x-100",
                )}
              >
                <div
                  className={cn(
                    "transition duration-500",
                    !music.isSoundPlaying && "scale-[0.85] opacity-60",
                  )}
                >
                  <div
                    ref={squircle}
                    className="size-[22px] rounded-md bg-cover! transition-all duration-150"
                    style={{ background: `url(${track.album_art})` }}
                    onMouseEnter={onPeekEnter}
                    onMouseLeave={onPeekLeave}
                    onMouseUp={() =>
                      track.url && window.open(track.url, "_blank")
                    }
                  />
                </div>
              </div>
            </div>
          </div>
        ) : null}
      </Transition>
    </div>
  );
}

function PlaybackGlyph({ path, hidden }: { path: string; hidden: boolean }) {
  return (
    <div
      className={cn(
        "absolute inset-0 flex items-center justify-center pr-[9px] transition duration-400",
        hidden && "scale-0 opacity-0 blur-sm",
      )}
    >
      <svg
        className="text-orange-25/85 size-4 fill-current"
        viewBox="0 0 28 28"
        aria-hidden="true"
      >
        <path d={path} />
      </svg>
    </div>
  );
}

function NotchRight({
  notification,
  activity,
}: {
  notification: string | null;
  activity: string | null;
}) {
  const music = useMusic();
  const track = currentTrack(music);
  const gradient = track
    ? {
        backgroundImage: `linear-gradient(to bottom, ${track.colors[0]}, ${track.colors[1]})`,
      }
    : undefined;
  return (
    <div className="absolute top-0 right-0 flex h-10 items-center">
      <Transition {...SIDE}>
        {notification === "didConnectAirPods" ? (
          <div key="earbuds-right" className="pr-2.5">
            <svg
              className="size-5 -rotate-90"
              viewBox="0 0 16 16"
              aria-hidden="true"
            >
              <circle
                className="fill-transparent stroke-current stroke-2 text-green-300/30"
                r="6"
                cx="8"
                cy="8"
                strokeDasharray="38px"
                strokeDashoffset="0"
              />
              <circle
                className="fill-transparent stroke-current stroke-2 text-green-300"
                r="6"
                cx="8"
                cy="8"
                strokeDasharray="38px"
                strokeDashoffset="14px"
                strokeLinecap="round"
              />
            </svg>
          </div>
        ) : activity === "isPlaying" && track ? (
          <div key="playing-right" className="group pr-[9px]">
            <div
              className="absolute inset-0 z-10 opacity-0 group-hover:opacity-100"
              onClick={() => music.toggle()}
            >
              <PlaybackGlyph path={PAUSE_PATH} hidden={!music.isSoundPlaying} />
              <PlaybackGlyph path={PLAY_PATH} hidden={music.isSoundPlaying} />
            </div>
            <div className="flex w-5 items-center justify-center space-x-[1.5px] brightness-110 group-hover:scale-125 group-hover:blur-[3.5px] group-hover:brightness-125 group-hover:saturate-150">
              {BARS.map((bar) => (
                <div
                  key={bar}
                  className={cn(
                    "size-0.5 max-h-5 rounded-[1px] transition-all duration-500",
                    bar,
                    !music.isSoundPlaying && "pause max-h-0.5!",
                  )}
                  style={gradient}
                />
              ))}
            </div>
          </div>
        ) : null}
      </Transition>
    </div>
  );
}

/**
 * The Dynamic Island: a black squircle whose size/corners spring between states —
 * locked (186 wide), notification (186), now playing (186), quick peek (72 tall).
 */
export function Notch({ isLocked = false }: { isLocked?: boolean }) {
  const command = useNotchBus((s) => s.command);
  const lastCommand = useRef(command?.id ?? 0);
  const { notchRef, innerRef, render, animateFrame } = useNotchFrame();
  const wrapper = useRef<HTMLDivElement>(null);
  const marqueeBox = useRef<HTMLDivElement>(null);
  const marquee = useRef<HTMLDivElement>(null);
  const [hovered, setHovered] = useState(false);
  const [peeking, setPeeking] = useState(false);
  const [unlocked, setUnlocked] = useState(false);
  const [activity, setActivity] = useState<string | null>(null);
  const [notification, setNotification] = useState<string | null>(null);
  const live = useRef({
    peeking: false,
    activity: null as string | null,
    notification: null as string | null,
    activityTimer: 0,
    notificationTimer: 0,
  });

  const settleScale = useCallback(() => {
    if (wrapper.current)
      animate(wrapper.current, { scale: 1 }, spring(160, 18));
  }, []);

  const notify = useCallback(
    (on: boolean, type: string, duration = 0) => {
      const s = live.current;
      if (on && type === s.notification) return;
      s.notification = on ? type : null;
      setNotification(s.notification);
      animateFrame({ width: EXPANDED }, spring(150, 20));
      clearTimeout(s.notificationTimer);
      if (duration <= 0) return;
      s.notificationTimer = window.setTimeout(() => {
        s.notification = null;
        setNotification(null);
        animateFrame({ width: COMPACT }, spring(150, 16));
        settleScale();
      }, duration);
    },
    [animateFrame, settleScale],
  );

  const setLiveActivity = useCallback(
    (on: boolean, type: string) => {
      const s = live.current;
      if (on && type === s.activity) return;
      clearTimeout(s.activityTimer);
      if (on) {
        s.activity = type;
        setActivity(type);
        animateFrame({ width: EXPANDED }, spring(150, 20));
        return;
      }
      let delay = 0;
      if (type === "isLocked") {
        setUnlocked(true);
        delay = UNLOCK_SETTLE;
      }
      s.activityTimer = window.setTimeout(() => {
        s.activity = null;
        setActivity(null);
        animateFrame({ width: COMPACT }, spring(175, 17.5));
      }, delay);
    },
    [animateFrame],
  );

  const quickPeek = useCallback(
    (on: boolean, duration = 0) => {
      const s = live.current;
      if (on && s.peeking) return;
      s.peeking = on;
      setPeeking(on);
      const box = marqueeBox.current;
      if (!on) {
        animateFrame({ height: 40, ...corners(12) }, spring(250, 25));
        if (box)
          animate(
            box,
            { opacity: 0, filter: "blur(10px)", scaleX: 0.75 },
            spring(250, 25),
          );
        return;
      }
      animateFrame(
        {
          height: 72,
          topLeft: 13,
          topRight: 13,
          bottomRight: 19,
          bottomLeft: 19,
        },
        spring(250, 21),
      );
      if (box)
        animate(
          box,
          { opacity: 1, filter: "blur(0)", scaleX: 1 },
          spring(250, 21, { delay: 0.05 }),
        );
      requestAnimationFrame(() => {
        const label = marquee.current?.firstElementChild;
        if (label)
          marquee.current!.style.setProperty(
            "--marquee-duration",
            `${label.scrollWidth / MARQUEE_SPEED}s`,
          );
      });
      if (duration > 0) setTimeout(() => quickPeek(false), duration);
    },
    [animateFrame],
  );

  useEffect(() => {
    requestAnimationFrame(() => {
      render();
      setLiveActivity(true, "isLocked");
    });
    const s = live.current;
    return () => {
      clearTimeout(s.notificationTimer);
      clearTimeout(s.activityTimer);
    };
  }, [render, setLiveActivity]);

  useEffect(() => {
    if (!command || command.id === lastCommand.current) return;
    lastCommand.current = command.id;
    if (command.kind === "notification")
      notify(command.state, command.type, command.duration);
    else if (command.kind === "live-activity")
      setLiveActivity(command.state, command.type);
    else quickPeek(command.state, command.duration);
  }, [command, notify, setLiveActivity, quickPeek]);

  const mounted = useRef(false);
  useEffect(() => {
    if (!mounted.current) {
      mounted.current = true;
      return;
    }
    setLiveActivity(isLocked, "isLocked");
  }, [isLocked, setLiveActivity]);

  return (
    <div
      ref={wrapper}
      className="select-none"
      onMouseEnter={() => {
        if (live.current.peeking) return;
        setHovered(true);
        if (notchRef.current)
          animate(notchRef.current, { scale: 1.075 }, spring(250, 14));
        animateFrame(corners(13), spring(250, 14));
      }}
      onMouseLeave={() => {
        if (live.current.peeking) return;
        setHovered(false);
        if (notchRef.current)
          animate(notchRef.current, { scale: 1 }, spring(200, 20));
        animateFrame(corners(12), spring(200, 20));
        settleScale();
      }}
      onMouseDown={() =>
        wrapper.current &&
        animate(wrapper.current, { scale: 0.94 }, spring(160, 18))
      }
      onMouseUp={settleScale}
    >
      <div
        ref={notchRef}
        className={cn(
          "text-orange-25 relative flex h-10 origin-top rounded-xl transition-shadow duration-300",
          hovered && "shadow-[0_2px_16px_0_rgba(12,10,9,0.25)]",
        )}
      >
        <div ref={innerRef} className="relative size-full bg-stone-950">
          <NotchLeft
            notification={notification}
            activity={activity}
            unlocked={unlocked}
            peeking={peeking}
            onPeekEnter={() => quickPeek(true)}
            onPeekLeave={() => quickPeek(false)}
          />
          <NotchRight notification={notification} activity={activity} />
          <Marquee ref={marqueeBox} marqueeRef={marquee} />
        </div>
      </div>
    </div>
  );
}
