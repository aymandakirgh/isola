import type { ReactNode } from "react";
import { AppMark } from "../components/AppMark";
import { InlineLink } from "../components/InlineLink";
import { BRAND, CONTACT_EMAIL } from "../config";
import { cn } from "../lib/cn";
import { usePageTransition } from "../lib/router";
import { Transition } from "../lib/transition";

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <>
      <h2 className="mb-3 text-2xl font-bold">{title}</h2>
      <p className="mb-10 text-xl leading-normal">{children}</p>
    </>
  );
}

export default function Privacy() {
  const page = usePageTransition();
  const contact = (
    <InlineLink href={`mailto:${CONTACT_EMAIL}`} label="Contact us">
      {CONTACT_EMAIL}
    </InlineLink>
  );
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
            Only what your license needs is ever collected by{" "}
            <span className="relative ml-px inline-flex items-center">
              <span className="absolute left-0.5">
                <AppMark />
              </span>
              <span className="ml-8 font-medium">{BRAND}</span>.
            </span>
          </p>
          <Section title="What we keep">
            Your license key. For each Mac you activate: a random ID the app
            makes for it, the Mac’s name and model, and when it was activated
            and last seen. The demo checkout on this site asks for no e-mail
            address.
          </Section>
          <Section title="Why">
            To hold each license to three Macs, and to list them in Settings ›
            License so you can free a slot. Nothing else: no analytics, no ads,
            no tracking.
          </Section>
          <Section title="Where">
            With Vercel, which hosts this site and keeps licenses in private
            storage (Vercel Blob). Like any host, it sees your IP address with
            each request, {BRAND}’s daily checks included; the license server
            keeps it in memory for up to an hour to rate-limit requests, and
            never stores it. Once license e-mails are switched on, they go out through
            Resend. The demo on this site plays its songs straight from Apple
            Music, and in the app, weather and Spotify features talk to those
            services directly. Everything else stays on your Mac, or in your own
            iCloud Drive if you sync settings.
          </Section>
          <Section title="How long">
            A Mac’s details stay until that Mac is deactivated. Your key stays
            as long as the license exists, or until you ask us to delete it.
          </Section>
          <Section title="Your rights">
            You can ask for a copy of what we hold about you, a correction or
            its deletion at any time, and complain to your data protection
            authority if you think we got it wrong. Just write to {contact}.
          </Section>
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
