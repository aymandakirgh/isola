import {
  useEffect,
  useState,
  type MouseEventHandler,
  type PointerEventHandler,
  type ReactNode,
} from "react";
import { BRAND, SIBLING_APP, SOCIAL } from "../config";
import { useAppVersion } from "../lib/appVersion";
import { cn } from "../lib/cn";
import { squircle, squircleRef } from "../lib/squircle";
import { Transition } from "../lib/transition";
import { FocusRing, NavButton } from "./Button";
import { HeaderNav } from "./HeaderNav";
import { DiscordLogo, SiblingAppGlyph, XLogo } from "./icons";

const bezelRing = squircleRef(2.5);
const badgeRing = squircleRef(1.5);
const BACK_ARROW =
  "M18.032 11.218a1 1 0 0 0-1.414 0l-6.075 6.075a1 1 0 0 0 0 1.414l6.075 6.075a1 1 0 0 0 1.414-1.414L13.664 19H24.75a1 1 0 1 0 0-2H13.664l4.368-4.368a1 1 0 0 0 0-1.414Z";
const PINNED = "in-[.logo-pin]";

/** Isola mark: a bezel with an "island" pill; on hover the screen slides away for a back arrow. */
function Logo() {
  return (
    <div className="relative mr-3 rounded-xl">
      <FocusRing />
      <div className="relative isolate size-10 overflow-hidden rounded-xl">
        <span
          ref={bezelRing}
          className="absolute inset-0 -z-10 rounded-[inherit] bg-stone-800 transition-colors delay-50 duration-300 ease-out dark:bg-orange-100"
        />
        <div
          ref={squircle}
          className={cn(
            "absolute inset-[4.5px] origin-center rounded-[7.5px] bg-linear-to-t from-stone-950/20 to-stone-950 to-95% transition delay-50 duration-300 ease-out",
            "group-hover:-translate-x-full group-hover:scale-x-50 group-hover:scale-y-75 group-hover:opacity-25 group-hover:delay-0",
            `${PINNED}:-translate-x-full ${PINNED}:scale-x-50 ${PINNED}:scale-y-75 ${PINNED}:opacity-25 ${PINNED}:delay-0`,
            "dark:from-orange-75 dark:to-orange-75/5 dark:inset-[5px] dark:rounded-[0.4375rem] dark:to-100%",
          )}
        >
          <span className="absolute top-[3px] left-1/2 h-[4px] w-[11px] -translate-x-1/2 rounded-full bg-orange-75 dark:bg-stone-900" />
        </div>
        <svg
          className="absolute -inset-[0.15625rem] size-[2.8125rem] fill-current"
          viewBox="0 0 36 36"
          aria-hidden="true"
        >
          <path
            className={cn(
              "origin-right translate-x-0.5 scale-50 opacity-0 blur-xs transition duration-300",
              "group-hover:translate-x-0 group-hover:scale-100 group-hover:opacity-100 group-hover:blur-none group-hover:delay-50",
              `${PINNED}:translate-x-0 ${PINNED}:scale-100 ${PINNED}:opacity-100 ${PINNED}:blur-none ${PINNED}:delay-50`,
            )}
            d={BACK_ARROW}
          />
        </svg>
      </div>
    </div>
  );
}

export function Layout({
  path,
  dark,
  leaving,
  onClick,
  onPointerOver,
  children,
}: {
  path: string;
  dark: boolean;
  leaving: boolean;
  onClick: MouseEventHandler;
  onPointerOver: PointerEventHandler;
  children: ReactNode;
}) {
  const [scrolled, setScrolled] = useState(false);
  const [pinned, setPinned] = useState(false);
  const { appVersion } = useAppVersion();
  const shortVersion = appVersion.split(".").slice(0, 2).join(".");

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 32);
    window.addEventListener("scroll", onScroll);
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <section
      className={cn(
        "dark:text-orange-75 flex min-h-svh flex-col text-stone-800",
        dark && "dark",
      )}
      onClick={onClick}
      onPointerOver={onPointerOver}
    >
      <header
        className={cn(
          "fixed top-0 z-40 flex w-full flex-col outline outline-1 outline-orange-400/0 transition-shadow duration-300 ease-in-out",
          scrolled &&
            "not-sm:bg-orange-75 sm:bg-orange-75/80 shadow-2xl shadow-orange-800/15 outline-orange-400/5 sm:backdrop-blur-xl dark:shadow-none dark:outline-none not-sm:dark:bg-stone-900 sm:dark:bg-stone-900/80",
        )}
      >
        <div className="flex w-full justify-center px-8 py-5 sm:py-7">
          <div className="max-w-screen-3xl flex min-h-14 w-full justify-between">
            <div className="animate-header-rise flex items-center will-change-transform">
              <a
                href="/"
                className={cn(
                  "group relative -m-1.5 flex items-center rounded-2xl p-1.5 outline-hidden",
                  pinned && "logo-pin",
                )}
                aria-label="Go home"
                aria-current={path === "/" ? "page" : undefined}
                onClick={(e) => {
                  // Keep the back-arrow state while we travel home.
                  const el = e.currentTarget;
                  setPinned(el.matches(":hover"));
                  setTimeout(
                    () => el.matches(":hover") || setPinned(false),
                    900,
                  );
                }}
                onMouseLeave={() => setPinned(false)}
              >
                <Logo />
                <div className="text-2xl font-bold">{BRAND}</div>
              </a>
              <Transition
                enterFrom="rotate-4 scale-75 translate-y-2 opacity-0"
                enterActive="transition duration-500 will-change-transform"
                appear
              >
                {shortVersion ? (
                  <a
                    href="/changelog"
                    className="dark:text-orange-75/50 group relative isolate mt-2.5 ml-[6.5px] flex items-center justify-center self-start rounded-lg px-[5.5px] py-[2.5px] text-center text-xs font-bold whitespace-nowrap text-orange-950/60 outline-hidden transition duration-300"
                    aria-label="View changelog"
                  >
                    <FocusRing />
                    <span
                      ref={badgeRing}
                      className="dark:bg-orange-75/10 dark:group-hover:bg-orange-75/25 absolute inset-0 -z-10 rounded-[inherit] bg-orange-950/15 transition duration-300 group-hover:bg-orange-950/30"
                    />
                    <span
                      ref={squircle}
                      className="dark:bg-orange-75/4 absolute inset-[1.5px] -z-10 rounded-[6.5px] bg-orange-950/3"
                    />
                    v{shortVersion}
                  </a>
                ) : null}
              </Transition>
            </div>
            <HeaderNav path={path} />
          </div>
        </div>
      </header>
      <main className="flex flex-1 justify-center px-8 pt-32 pb-16 sm:pt-48 sm:pb-28 xl:px-36">
        {children}
      </main>
      <Transition
        show={!leaving}
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500 delay-1300 dark:delay-800"
        leaveActive="transition duration-300"
        leaveTo="translate-y-3 opacity-0"
        appear
      >
        <footer className="relative flex flex-col items-center justify-center px-8 pb-20 opacity-0 sm:pb-0">
          <div className="flex items-center justify-center space-x-3">
            <NavButton
              className="size-10"
              href={SOCIAL.x}
              rel="noopener noreferrer"
              target="_blank"
              aria-label="X (Twitter)"
              squircle
            >
              <XLogo className="size-[22px] fill-current transition duration-300 ease-out group-hover:scale-105 dark:opacity-50 dark:group-hover:opacity-100" />
            </NavButton>
            <NavButton
              className="size-10"
              href={SOCIAL.discord}
              rel="noopener noreferrer"
              target="_blank"
              aria-label="Discord"
              squircle
            >
              <DiscordLogo className="size-6 fill-current transition duration-300 ease-out group-hover:scale-105 dark:opacity-50 dark:group-hover:opacity-100" />
            </NavButton>
            <NavButton
              className="size-10"
              href={SIBLING_APP.url || "#"}
              rel="noopener noreferrer"
              target={SIBLING_APP.url ? "_blank" : undefined}
              aria-label={`${SIBLING_APP.name} Mac App`}
              squircle
            >
              <span
                ref={squircle}
                className="relative m-px size-[21px] origin-center overflow-hidden rounded-[0.34375rem] transition duration-300 ease-out group-hover:scale-105 group-hover:opacity-100 dark:opacity-50 dark:group-hover:opacity-100"
                aria-hidden="true"
              >
                <SiblingAppGlyph className="relative size-full fill-current" />
              </span>
            </NavButton>
          </div>
          <div className="dark:from-orange-75/[0.035] dark:to-orange-75/0 pointer-events-none -mt-6 hidden overflow-hidden bg-linear-to-b from-orange-950/10 from-25% to-orange-950/0 bg-clip-text text-[14rem] leading-none font-black text-transparent select-none sm:block sm:h-36 md:h-48 md:text-[18rem] lg:h-56 lg:text-[20rem]">
            {BRAND}
          </div>
        </footer>
      </Transition>
    </section>
  );
}
