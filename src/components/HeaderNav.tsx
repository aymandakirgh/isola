import {
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type Ref,
} from "react";
import { cn } from "../lib/cn";
import { nextFrame } from "../lib/frame";
import { snapBackRef } from "../lib/hover";
import { AppleButton, NavButton } from "./Button";
import { ChangelogIcon, FaqIcon } from "./icons";

type Key = "faqs" | "changelog" | "download";
type Phase = "idle" | "enter-from" | "enter-active" | "leave" | "leave-to";
type Item = { key: Key; id: number; phase: Phase; pin?: CSSProperties };
type NavProps = {
  className?: string;
  style?: CSSProperties;
  ref?: Ref<HTMLAnchorElement>;
};

const ORDER: Key[] = ["faqs", "changelog", "download"];
const ENTER = "transition delay-300 duration-500 ease-spring nav-btn-enter";
const PHASE_CLASS: Record<Phase, string> = {
  idle: "",
  "enter-from": `scale-90 opacity-0 ${ENTER}`,
  "enter-active": ENTER,
  leave: "nav-btn-leave",
  "leave-to": "nav-btn-leave scale-75 opacity-0",
};
const SLIDE = [
  "transition-[transform]",
  "delay-300",
  "duration-400",
  "ease-spring",
];
const isLeaving = (i: Item) => i.phase === "leave" || i.phase === "leave-to";

/** A page never links to itself; download pages hide the download button. */
function itemsFor(path: string) {
  const downloadPage =
    path === "/download" ||
    path === "/recover" ||
    path.startsWith("/purchased");
  return ORDER.filter((k) =>
    k === "download" ? !downloadPage : path !== `/${k}`,
  );
}

function FaqsLink({ className, style, ref }: NavProps) {
  return (
    <NavButton
      ref={ref}
      style={style}
      className={className}
      fillClass="not-sm:dark:bg-orange-75/5 not-sm:bg-stone-800/5"
      href="/faqs"
      aria-label="Frequently asked questions"
    >
      <FaqIcon className="size-[25px] origin-bottom fill-current transition duration-300 group-hover:-rotate-12 sm:mr-2" />
      <span className="dark:text-orange-75 hidden text-stone-800 transition-colors duration-300 sm:block">
        FAQs
      </span>
    </NavButton>
  );
}

function ChangelogLink({ className, style, ref }: NavProps) {
  return (
    <NavButton
      ref={ref}
      style={style}
      className={cn("not-lg:hidden", className)}
      href="/changelog"
      aria-label="Changelog"
    >
      <ChangelogIcon className="mr-2 size-[22px] overflow-visible fill-current transition-colors duration-300" />
      <span className="dark:text-orange-75 text-stone-800 transition-colors duration-300">
        Changelog
      </span>
    </NavButton>
  );
}

function DownloadLink({ className, style, ref }: NavProps) {
  return (
    <AppleButton
      ref={ref}
      style={style}
      className={cn("not-sm:hidden sm:ml-3.5", className)}
      type="info"
      href="/download"
      label="Download for Mac"
      labelClassName="dark:text-orange-75 text-stone-800"
      arrowClassName="size-[25px]"
      aria-label="Download for Mac"
    />
  );
}

const LINKS = {
  faqs: FaqsLink,
  changelog: ChangelogLink,
  download: DownloadLink,
};

let uid = 0;

/** Header buttons that pop in/out per route; survivors glide to their new slot (FLIP). */
export function HeaderNav({ path }: { path: string }) {
  const [items, setItems] = useState<Item[]>(() =>
    itemsFor(path).map((key) => ({ key, id: ++uid, phase: "idle" })),
  );
  const itemsRef = useRef(items);
  itemsRef.current = items;
  const nodes = useRef(new Map<Key, HTMLElement>());
  const timers = useRef<number[]>([]);
  const prevPath = useRef(path);
  const flipFrom = useRef<{ key: Key; left: number; top: number }[] | null>(
    null,
  );
  const [refs] = useState(() => {
    const make = (key: Key) => (el: HTMLElement | null) => {
      if (!el) return;
      nodes.current.set(key, el);
      const unsnap = key === "changelog" ? snapBackRef(el) : undefined;
      return () => {
        if (nodes.current.get(key) === el) nodes.current.delete(key);
        unsnap?.();
      };
    };
    return {
      faqs: make("faqs"),
      changelog: make("changelog"),
      download: make("download"),
    };
  });

  // FLIP: slide surviving buttons from where they were to where they now sit.
  useLayoutEffect(() => {
    const from = flipFrom.current;
    if (!from) return;
    flipFrom.current = null;
    const moved: HTMLElement[] = [];
    for (const { key, left, top } of from) {
      const el = nodes.current.get(key);
      if (!el) continue;
      const r = el.getBoundingClientRect();
      const dx = left - r.left;
      const dy = top - r.top;
      if (!dx && !dy) continue;
      el.style.transform = `translate(${dx}px, ${dy}px)`;
      el.style.transitionDuration = "0s";
      moved.push(el);
    }
    if (!moved.length) return;
    void document.body.offsetHeight;
    for (const el of moved) {
      el.classList.add(...SLIDE);
      el.style.transform = "";
      el.style.transitionDuration = "";
      timers.current.push(
        window.setTimeout(() => el.classList.remove(...SLIDE), 750),
      );
    }
  });

  useLayoutEffect(() => {
    if (prevPath.current === path) return;
    prevPath.current = path;
    const next = itemsFor(path);
    const live = itemsRef.current.filter((i) => !isLeaving(i));
    const stay = live.filter((i) => next.includes(i.key));
    const gone = live.filter((i) => !next.includes(i.key));
    if (!gone.length && stay.length === next.length) return;
    const leaving = gone.map((i): Item => {
      const r = nodes.current.get(i.key)?.getBoundingClientRect();
      return {
        ...i,
        phase: "leave",
        pin: r && {
          left: `${r.left}px`,
          top: `${r.top}px`,
          width: `${r.width}px`,
          margin: "0",
        },
      };
    });
    flipFrom.current = stay.flatMap(({ key }) => {
      const r = nodes.current.get(key)?.getBoundingClientRect();
      return r ? [{ key, left: r.left, top: r.top }] : [];
    });
    setItems([
      ...itemsRef.current.filter(isLeaving),
      ...leaving,
      ...next.map(
        (key) =>
          stay.find((i) => i.key === key) ?? {
            key,
            id: ++uid,
            phase: "enter-from" as Phase,
          },
      ),
    ]);
    nextFrame(() => {
      setItems((list) =>
        list.map((i) =>
          i.phase === "enter-from"
            ? { ...i, phase: "enter-active" }
            : i.phase === "leave"
              ? { ...i, phase: "leave-to" }
              : i,
        ),
      );
      timers.current.push(
        window.setTimeout(
          () => setItems((list) => list.filter((i) => i.phase !== "leave-to")),
          300,
        ),
        window.setTimeout(
          () =>
            setItems((list) =>
              list.map((i) =>
                i.phase === "enter-active" ? { ...i, phase: "idle" } : i,
              ),
            ),
          800,
        ),
      );
    });
  }, [path]);

  useLayoutEffect(() => {
    const t = timers.current;
    return () => t.forEach(clearTimeout);
  }, []);

  return (
    <div className="header-nav animate-nav-fade relative flex items-center sm:gap-1.5">
      {items.map((i) => {
        const Link = LINKS[i.key];
        return (
          <Link
            key={i.id}
            ref={refs[i.key]}
            style={isLeaving(i) ? i.pin : undefined}
            className={PHASE_CLASS[i.phase]}
          />
        );
      })}
    </div>
  );
}
