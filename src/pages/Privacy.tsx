import { AppMark } from "../components/AppMark";
import { InlineLink } from "../components/InlineLink";
import { BRAND, CONTACT_EMAIL } from "../config";
import { cn } from "../lib/cn";
import { usePageTransition } from "../lib/router";
import { Transition } from "../lib/transition";

export default function Privacy() {
  const page = usePageTransition();
  return (
    <div className={cn("w-full max-w-(--breakpoint-md)", page)}>
      <Transition
        enterFrom="rotate-2 translate-y-8 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <h1 className="text-6xl font-bold opacity-0 delay-500 sm:text-8xl">
          Privacy policy
        </h1>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="opacity-0 delay-700">
          <p className="my-8 py-4 text-xl leading-normal">
            No data or personal information is ever collected by{" "}
            <span className="relative ml-px inline-flex items-center">
              <span className="absolute left-0.5">
                <AppMark />
              </span>
              <span className="ml-8 font-medium">{BRAND}</span>.
            </span>
          </p>
          <h2 className="mb-3 text-2xl font-bold">Have questions?</h2>
          <p className="text-xl">
            If you have questions or suggestions about this privacy policy, feel
            free to{" "}
            <InlineLink href={`mailto:${CONTACT_EMAIL}`} label="Contact us">
              contact us
            </InlineLink>
            .
          </p>
        </div>
      </Transition>
    </div>
  );
}
