import { useEffect, useRef, useState } from "react";
import { CursorIcon } from "../../components/icons";
import { useMinWidth } from "../../lib/breakpoints";
import { cn } from "../../lib/cn";
import { playSound, preloadSound } from "../../lib/sound";
import { Transition } from "../../lib/transition";
import {
  Dock,
  LockScreen,
  NowPlayingWidget,
  TopBar,
  Wallpaper,
} from "./Screen";
import { currentTrack, sendToNotch, useClock, useMusic } from "./stores";

const UNLOCK_SOUND = "/sounds/unlock.wav";
const CONNECT_SOUND = "/sounds/connect.wav";
const CONNECT_AFTER = 2000; // unlock → earbuds connect
const PLAY_AFTER = 3750; // connect → music starts
const CONNECT_SHOWN = 3500;

const NUDGE_EVERY = 4000;
const NUDGE_FOR = 1000;

/** "Psst… it's interactive!" — the cursor twitches every few seconds until hovered. */
function InteractiveHint() {
  const [hovered, setHovered] = useState(false);
  const [nudging, setNudging] = useState(false);
  const [settling, setSettling] = useState(false);
  const interval = useRef(0);
  const timeout = useRef(0);
  const start = () => {
    interval.current = window.setInterval(() => {
      setNudging(true);
      timeout.current = window.setTimeout(() => {
        setNudging(false);
        setSettling(true);
      }, NUDGE_FOR);
    }, NUDGE_EVERY);
  };
  const stop = () => {
    setNudging(false);
    clearInterval(interval.current);
    clearTimeout(timeout.current);
  };
  useEffect(() => {
    start();
    return stop;
  }, []);
  return (
    <div
      className="mt-4 hidden cursor-default items-center p-4 text-sm font-bold text-orange-950/40 select-none sm:flex"
      onMouseEnter={() => {
        setHovered(true);
        stop();
      }}
      onMouseLeave={() => {
        setSettling(false);
        setHovered(false);
        start();
      }}
    >
      <CursorIcon
        className={cn(
          "mr-2 size-3.5 fill-current transition duration-500",
          hovered && "-translate-x-1.5 -translate-y-1.5 duration-700",
          nudging && "-translate-x-1 -translate-y-1 duration-1000",
          settling && "duration-700",
        )}
      />
      Psst… it's interactive!
    </div>
  );
}

/** The interactive Mac: click the lock screen to unlock, then earbuds connect and music plays. */
export function Demo() {
  const xxl = useMinWidth("2xl");
  const md = useMinWidth("md");
  const music = useMusic();
  const track = currentTrack(music);
  const now = useClock((s) => s.now);
  const [locked, setLocked] = useState(true);
  const armed = useRef(true);
  const connectTimer = useRef(0);
  const playTimer = useRef(0);

  useEffect(() => {
    const clock = useClock.getState();
    clock.start();
    useMusic.getState().getTracks();
    return () => {
      clearTimeout(connectTimer.current);
      clearTimeout(playTimer.current);
      clock.stop();
      useMusic.getState().stopCurrentSound();
    };
  }, []);

  return (
    <Transition
      enterFrom="translate-y-5 opacity-0"
      enterActive="transition duration-500"
      appear
    >
      <section className="isolate flex w-full flex-col items-center px-0 opacity-0 delay-500 select-none lg:px-8">
        <div
          className="relative h-48 w-full overflow-visible sm:aspect-2/1 sm:h-full sm:overflow-hidden"
          onMouseEnter={() => {
            preloadSound(UNLOCK_SOUND);
            preloadSound(CONNECT_SOUND);
            useMusic.getState().preloadTrack();
            useMusic.getState().preloadNextTrack();
          }}
          onClick={() => {
            if (!armed.current) return;
            armed.current = false;
            setLocked(false);
            useMusic.getState().preloadTrackArt();
            playSound(UNLOCK_SOUND);
            connectTimer.current = window.setTimeout(() => {
              sendToNotch({
                kind: "notification",
                state: true,
                type: "didConnectAirPods",
                duration: CONNECT_SHOWN,
              });
              playSound(CONNECT_SOUND, { volume: 0.5 });
              playTimer.current = window.setTimeout(
                () => useMusic.getState().play(),
                PLAY_AFTER,
              );
            }, CONNECT_AFTER);
          }}
        >
          <TopBar isLocked={locked} now={now} />
          <div className="absolute inset-0">
            <div className="absolute bottom-24 z-20 hidden w-full items-center justify-center 2xl:flex">
              {music.tracks && xxl ? (
                <NowPlayingWidget
                  className={cn(
                    "transition duration-400",
                    !locked && "opacity-0",
                  )}
                  track={track}
                />
              ) : null}
            </div>
            <Transition
              leaveTo="opacity-0"
              leaveActive="transition duration-400"
            >
              {locked ? <LockScreen now={now} /> : null}
            </Transition>
          </div>
          {md ? (
            <Transition
              enterFrom="translate-y-[318px]"
              enterActive="transition duration-400 ease-out"
            >
              {locked ? null : <Dock />}
            </Transition>
          ) : null}
          <Wallpaper />
        </div>
        <InteractiveHint />
      </section>
    </Transition>
  );
}
