import { useState } from "react";
import { Accordion, AccordionItem } from "../components/Accordion";
import { FocusRing } from "../components/Button";
import { DocNote } from "../components/DocNote";
import { BugIcon, SparklesIcon } from "../components/icons";
import { CHANGELOG, type Entry, type Minor } from "../content/changelog";
import { cn } from "../lib/cn";
import { usePageTransition } from "../lib/router";
import { Transition } from "../lib/transition";

const VISIBLE = 5;
const LIST = "dark:text-orange-75/70 mt-3 space-y-2 text-xl text-stone-600";

function MinorItem({ minor }: { minor: Minor }) {
  return (
    <AccordionItem
      title={minor.version}
      name={minor.version}
      small
      lazy
      symbol={
        <span className="text-lg whitespace-nowrap text-stone-500 dark:text-[#8d8881]">
          {minor.date}
        </span>
      }
    >
      {minor.note ? <p className="text-xl">{minor.note}</p> : null}
      {minor.features.length ? (
        <div className="mt-6">
          <h3 className="flex items-center gap-2 text-xl font-bold">
            <SparklesIcon className="size-[18px] fill-current" />
            Features ({minor.features.length})
          </h3>
          <ul className={LIST}>
            {minor.features.map((f) => (
              <li key={f}>{f}</li>
            ))}
          </ul>
        </div>
      ) : null}
      {minor.fixes.length ? (
        <div className="mt-6">
          <h3 className="flex items-center gap-2 text-xl font-bold">
            <BugIcon className="size-[18px] fill-current" />
            Fixes ({minor.fixes.length})
          </h3>
          <ul className={LIST}>
            {minor.fixes.map((f) => (
              <li key={f}>{f}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </AccordionItem>
  );
}

/** One major version: first five minors, a faded sixth that teases "Show more", the rest collapsed. */
function Release({ entry, first }: { entry: Entry; first: boolean }) {
  const [open, setOpen] = useState<string[]>([]);
  const [expanded, setExpanded] = useState(false);
  const id = `v${entry.version.replaceAll(".", "-")}`;
  const head = entry.minors.slice(0, VISIBLE);
  const teaser = entry.minors[VISIBLE] ?? null;
  const rest = entry.minors.slice(VISIBLE + 1);

  return (
    <section id={id} className={cn("scroll-mt-32", !first && "mt-36")}>
      <a
        className="group relative -mx-3 -my-1.5 inline-block rounded-xl px-3 py-1.5 outline-hidden transition hover:opacity-70"
        href={`#${id}`}
      >
        <FocusRing className="bg-rose-300/90" />
        <h2 className="text-4xl font-bold">{entry.version}</h2>
      </a>
      <p className="mt-6 text-xl">{entry.description}</p>
      <div className="mt-8">
        <Accordion value={open} multiple onChange={setOpen}>
          {head.map((m) => (
            <MinorItem key={m.version} minor={m} />
          ))}
          {teaser ? (
            <div
              className={cn(
                "relative transition-opacity duration-300 after:absolute after:inset-x-0 after:bottom-0 after:h-0.5 after:rounded-full after:bg-stone-800/5 dark:after:bg-orange-50/10",
                !expanded && "opacity-30",
              )}
              onClick={() => setExpanded(true)}
            >
              <MinorItem minor={teaser} />
            </div>
          ) : null}
          {rest.length ? (
            <div
              className={cn(
                "grid transition-all duration-300",
                expanded
                  ? "grid-rows-[1fr] opacity-100"
                  : "grid-rows-[0fr] [mask-image:linear-gradient(to_bottom,black_50%,transparent)] opacity-0",
              )}
              inert={!expanded}
            >
              <div className="row-[1/span_2] overflow-hidden">
                {rest.map((m) => (
                  <MinorItem key={m.version} minor={m} />
                ))}
              </div>
            </div>
          ) : null}
        </Accordion>
      </div>
      {teaser ? (
        <button
          type="button"
          className="group relative mx-auto mt-5 block cursor-pointer rounded-xl px-3.5 py-2 text-sm font-medium text-stone-500 outline-hidden transition duration-300 hover:opacity-70 dark:text-[#8d8881]"
          onClick={() => {
            const next = !expanded;
            setExpanded(next);
            if (next) return;
            // Collapsing closes any minor that is about to be hidden.
            const hidden = entry.minors.slice(VISIBLE).map((m) => m.version);
            setOpen((o) => o.filter((v) => !hidden.includes(v)));
          }}
        >
          <FocusRing />
          {expanded ? "Show less" : "Show more"}
        </button>
      ) : null}
    </section>
  );
}

export default function Changelog() {
  const page = usePageTransition();
  const { updated, entries } = CHANGELOG;
  return (
    <div className={cn("mb-0 w-full max-w-(--breakpoint-md) sm:mb-6", page)}>
      <Transition
        enterFrom="rotate-2 translate-y-8 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <h1 className="mb-3 text-6xl font-bold opacity-0 delay-500 sm:text-8xl">
          Changelog
        </h1>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="opacity-0 delay-700">
          <DocNote>
            {updated.startsWith("Updated") ? updated : `Updated ${updated}`}
          </DocNote>
        </div>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="mt-12 opacity-0 delay-900">
          {entries.map((e, i) => (
            <Release key={e.version} entry={e} first={i === 0} />
          ))}
        </div>
      </Transition>
    </div>
  );
}
