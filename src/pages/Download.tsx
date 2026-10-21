import { AppMark } from "../components/AppMark";
import { ContactNote } from "../components/ContactNote";
import { DownloadCard } from "../components/DownloadCard";
import { AppleLogo } from "../components/icons";
import { BRAND, DOWNLOAD_URL } from "../config";
import { useMinWidth } from "../lib/breakpoints";
import { cn } from "../lib/cn";
import { usePageTransition } from "../lib/router";
import { Transition } from "../lib/transition";

export default function Download() {
  const page = usePageTransition();
  const lg = useMinWidth("lg");
  return (
    <div className={cn("w-full max-w-(--breakpoint-md) text-center", page)}>
      <Transition
        enterFrom="rotate-2 translate-y-8 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <h1 className="mb-6 text-6xl font-bold tracking-tight opacity-0 delay-500 sm:text-8xl">
          Download {lg ? `${BRAND} ` : ""}
          {/* Keep "for Mac" together so a short brand name still breaks before "for". */}
          <span className="whitespace-nowrap">
            for{" "}
            <mark className="relative">
              <AppleLogo className="absolute -bottom-1 -left-1 size-16 fill-current sm:-bottom-1.5 sm:-left-2 sm:size-25" />
              <span className="pl-[55px] sm:pl-21">Mac</span>
            </mark>
          </span>
        </h1>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="mx-auto flex max-w-120 flex-col items-center justify-center opacity-0 delay-700">
          <p className="mt-6 text-xl leading-normal sm:mt-10">
            After downloading, open the DMG and drag{" "}
            <span className="relative ml-px inline-flex items-center">
              <span className="absolute left-0.5">
                <AppMark />
              </span>
              <span className="ml-8 font-medium">{BRAND}</span>
            </span>{" "}
            into your Applications folder <i>before</i> opening it.
          </p>
          <DownloadCard href={DOWNLOAD_URL} />
          <ContactNote>
            Having trouble downloading or installing? Please
          </ContactNote>
        </div>
      </Transition>
    </div>
  );
}
