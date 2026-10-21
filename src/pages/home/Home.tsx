import { AppleButton } from "../../components/Button";
import { MacOsIcon } from "../../components/icons";
import { PURCHASE_URL } from "../../config";
import { useAppVersion } from "../../lib/appVersion";
import { useMinWidth } from "../../lib/breakpoints";
import { cn } from "../../lib/cn";
import { usePageTransition } from "../../lib/router";
import { Transition } from "../../lib/transition";
import { Demo } from "./Demo";
import { Features } from "./Features";
import { Hero } from "./Hero";

export default function Home() {
  const page = usePageTransition();
  const lg = useMinWidth("lg");
  const { appMinimumSystemVersion } = useAppVersion();
  return (
    <section
      className={cn(
        "flex w-full max-w-(--breakpoint-xl) flex-col items-center",
        page,
      )}
    >
      <Hero />
      <Demo />
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <section className="isolate mt-16 w-full opacity-0 delay-1100 sm:mt-12">
          <Features />
          <div className="mt-24 flex flex-col items-center justify-center">
            <AppleButton
              href={lg ? "/download" : PURCHASE_URL}
              label={lg ? "Download for Mac" : "Purchase for Mac"}
              data-an={lg ? "download" : "purchase"}
              aria-label={lg ? "Download for Mac" : "Purchase"}
            />
            {appMinimumSystemVersion ? (
              <p className="mt-9 flex items-center gap-2 text-sm font-bold text-orange-950/36">
                <MacOsIcon className="size-4" />
                macOS {appMinimumSystemVersion.split(" ")[0]} or later
              </p>
            ) : null}
          </div>
        </section>
      </Transition>
    </section>
  );
}
