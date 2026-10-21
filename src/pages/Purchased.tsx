import { animate } from "motion";
import { useEffect, useRef, useState } from "react";
import { ContactNote } from "../components/ContactNote";
import { DownloadCard } from "../components/DownloadCard";
import { RECEIPT_FRAME_PATH, SealIcon } from "../components/icons";
import { DOWNLOAD_URL } from "../config";
import { mintDemoLicense } from "../lib/api";
import { useMinWidth } from "../lib/breakpoints";
import { cn } from "../lib/cn";
import { usePageTransition, type PageProps } from "../lib/router";
import { Transition } from "../lib/transition";

// Receipt lines scroll up like paper feeding out; the lower two also draw in.
const RECEIPT_LINES: { d: string; lift: number; dash?: [number, number] }[] = [
  { d: "M7.5 12H20", lift: -4.5 },
  { d: "M7.5 15.5H20", lift: -3.5 },
  { d: "M7.5 19H20", lift: -3.5, dash: [6, 0] },
  { d: "M7.5 22.5H20", lift: -3.5, dash: [14, 6] },
];

export default function Purchased({ params, search }: PageProps) {
  const page = usePageTransition();
  const lg = useMinWidth("lg");
  const md = useMinWidth("md");
  const lines = useRef<SVGPathElement[]>([]);
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");

  useEffect(() => {
    const controls = RECEIPT_LINES.flatMap((l, i) => {
      const el = lines.current[i];
      if (!el) return [];
      const to = l.dash
        ? { y: [0, l.lift], strokeDashoffset: l.dash }
        : { y: [0, l.lift] };
      return [animate(el, to, { duration: 1.5, repeat: Infinity })];
    });
    return () => controls.forEach((c) => c.stop());
  }, []);

  useEffect(() => {
    const pick = (...keys: string[]) =>
      keys.map((k) => search.get(k)?.trim()).find(Boolean) ?? "";
    const given = pick("code", "license_key", "licenseKey");
    // Only shown: anyone can put any address in a link, so it never goes to the licence server.
    const address = pick("email");
    setEmail(address);
    setCode(given);
    // The no-charge demo checkout mints a real licence (the shared demo key without the server).
    if (params.id !== "demo" || given) return;
    let live = true;
    mintDemoLicense().then((key) => {
      if (!live) return;
      setEmail(address || "you@example.com");
      setCode(key);
    });
    return () => {
      live = false;
    };
  }, [params.id, search]);

  return (
    <div className={cn("w-full max-w-(--breakpoint-md) text-center", page)}>
      <Transition
        enterFrom="rotate-2 translate-y-8 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <h1 className="mb-6 text-6xl font-bold tracking-tight opacity-0 delay-500 sm:text-8xl">
          {lg ? (
            <>
              Thanks for <br />
              your <mark>purchase</mark>!
            </>
          ) : (
            <>
              Thanks for <mark>purchasing!</mark>
            </>
          )}
        </h1>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="mx-auto flex max-w-md flex-col items-center justify-center opacity-0 delay-700">
          <p className="mt-6 text-xl leading-[1.575] text-balance sm:mt-10">
            Your{" "}
            <span className="font-medium whitespace-nowrap">
              <SealIcon className="mx-px mb-1 inline-block size-[22px] fill-current" />{" "}
              license
            </span>{" "}
            and{" "}
            <span className="font-medium whitespace-nowrap">
              <svg
                className="mb-0.5 ml-px inline-block size-6 fill-current"
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 28 28"
                aria-hidden="true"
              >
                <path d={RECEIPT_FRAME_PATH} />
                {RECEIPT_LINES.map((l, i) => (
                  <path
                    key={l.d}
                    ref={(el) => {
                      if (el) lines.current[i] = el;
                    }}
                    className="stroke-current stroke-[1.5px]"
                    d={l.d}
                    strokeLinecap="round"
                    strokeDasharray={l.dash && "14"}
                    strokeDashoffset={l.dash?.[0]}
                  />
                ))}
              </svg>{" "}
              receipt
            </span>{" "}
            are on their way to {md ? <br /> : <span />}
            {email ? (
              <span className="font-medium"> {email} </span>
            ) : (
              <span className="relative top-px mr-1.5 inline-block h-[13.5px] w-24 animate-pulse rounded-[0.1875rem] bg-orange-950/12.5" />
            )}
            in two separate emails.
          </p>
          <p className="mt-4 text-lg font-semibold text-orange-950/60">
            License key{" "}
            {code ? (
              <span className="font-mono whitespace-nowrap text-stone-800 select-all">
                {code}
              </span>
            ) : (
              <span className="relative top-px inline-block h-[13.5px] w-48 animate-pulse rounded-[0.1875rem] bg-orange-950/12.5" />
            )}
          </p>
          {/* The plain URL: the app never reads a key from it, and a key in it would end up in the
              browser's history and the downloaded file's "where from". */}
          <DownloadCard href={DOWNLOAD_URL} />
          <ContactNote>
            Having trouble downloading or installing? Please
          </ContactNote>
        </div>
      </Transition>
    </div>
  );
}
