import { useState } from "react";
import { Accordion, AccordionItem } from "../components/Accordion";
import { DocNote } from "../components/DocNote";
import {
  SHIELD_ALERT_PATH,
  SHIELD_CHECK_PATH,
  SHIELD_LOCK_PATH,
} from "../components/icons";
import { InlineLink } from "../components/InlineLink";
import { BRAND, CONTACT_EMAIL, TRIAL } from "../config";
import { cn } from "../lib/cn";
import { usePageTransition } from "../lib/router";
import { Transition } from "../lib/transition";

const CONTACT = `mailto:${CONTACT_EMAIL}?body=${encodeURIComponent("Hi,\n\nI checked the FAQs first — here’s my question:\n\n")}`;
const DIM = "dark:text-orange-75/50 text-stone-500";

const symbol = (d: string) => (
  <svg
    className="size-[30px] fill-current"
    xmlns="http://www.w3.org/2000/svg"
    viewBox="0 0 28 28"
    aria-hidden="true"
  >
    <path d={d} />
  </svg>
);

export default function Faqs() {
  const page = usePageTransition();
  const [open, setOpen] = useState<string | null>(null);
  return (
    <div className={cn("mb-0 w-full max-w-(--breakpoint-md) sm:mb-6", page)}>
      <Transition
        enterFrom="rotate-2 translate-y-8 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <h1 className="mb-3 text-6xl font-bold opacity-0 delay-500 sm:text-8xl">
          FAQs
        </h1>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="opacity-0 delay-700">
          <DocNote>Updated October 2026</DocNote>
        </div>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="mt-12 opacity-0 delay-900">
          <Accordion value={open} onChange={setOpen}>
            <AccordionItem
              title="What should I do if I run into a bug?"
              name="bugs"
            >
              <p>
                Tell us what happened by{" "}
                <InlineLink href={CONTACT} label="Contact us">
                  getting in touch
                </InlineLink>{" "}
                — a screenshot or a short screen recording helps a lot.
              </p>
            </AccordionItem>
            <AccordionItem title="How do I hide the menu bar icon?" name="icon">
              <p>
                From macOS Tahoe onward you can switch it off in System Settings
                › Menu Bar. {BRAND} keeps working in the background.
              </p>
            </AccordionItem>
            <AccordionItem
              title="How many Macs can one license cover?"
              name="devices"
            >
              <p>
                Each license activates on up to three Macs at the same time, and
                you can free up a slot from Settings whenever you like.
              </p>
            </AccordionItem>
            <AccordionItem
              title="How do I remove a Mac from my license?"
              name="remove"
            >
              <p>
                Open the License tab in Settings and deactivate any Mac you no
                longer use. A Mac can remove itself or any Mac activated after
                it, so your first Mac can always tidy up the list.
              </p>
              <p className={DIM}>
                Need a complete reset instead? Just reach out.
              </p>
            </AccordionItem>
            <AccordionItem
              title="I lost my license. How do I get it back?"
              name="recover"
            >
              <p>
                Head over to the{" "}
                <InlineLink href="/recover" label="Recover your license">
                  recovery
                </InlineLink>{" "}
                page and we’ll send it to you again.
              </p>
            </AccordionItem>
            <AccordionItem title="Are future updates included?" name="purchase">
              <p>
                Yes. {BRAND} is a single purchase and every future update comes
                with it.
              </p>
              <p className={DIM}>No subscription, ever.</p>
            </AccordionItem>
            <AccordionItem
              title={`Can I try ${BRAND} before buying?`}
              name="trial"
            >
              <p>
                Of course — there’s a free {TRIAL} trial. Grab it from the{" "}
                <InlineLink href="/download" label="Download for Mac">
                  download
                </InlineLink>{" "}
                page and you’re set.
              </p>
            </AccordionItem>
            <AccordionItem title="Do you offer discounts?" name="discount">
              <p>We don’t run discounts or coupon codes.</p>
              <p className={DIM}>
                One fair price for everyone keeps the updates coming.
              </p>
            </AccordionItem>
            <AccordionItem
              title="Can I get a refund?"
              name="refund"
              symbol={symbol(SHIELD_CHECK_PATH)}
            >
              <p>
                Yes. If {BRAND} isn’t for you, ask for a full refund within 14
                days of your purchase.
              </p>
              <p className={DIM}>No questions asked.</p>
            </AccordionItem>
            <AccordionItem
              title={`Will ${BRAND} keep working forever?`}
              name="indefinitely"
              symbol={symbol(SHIELD_ALERT_PATH)}
            >
              <p>
                {BRAND} builds on parts of macOS that Apple doesn’t officially
                document. They have stayed stable for years, but Apple could
                change or remove them at any time, so {BRAND} is sold “as is”,
                without a guarantee that every feature will keep working on
                future versions of macOS.
              </p>
              <p className={DIM}>
                If that happens, we’ll adapt {BRAND} as best we can.
              </p>
            </AccordionItem>
            <AccordionItem
              title={`Does ${BRAND} collect any data?`}
              name="privacy"
              symbol={symbol(SHIELD_LOCK_PATH)}
            >
              <p>
                Only what your license needs: the key, the e-mail address you
                give at checkout if you give one, and for each activated Mac a
                hashed hardware ID, its name and its model. Nothing else is
                kept.
              </p>
              <p className={DIM}>
                The{" "}
                <InlineLink href="/privacy" label="Privacy policy">
                  privacy policy
                </InlineLink>{" "}
                has the details.
              </p>
            </AccordionItem>
          </Accordion>
          <div className="mt-12 pt-6">
            <h3 className="mb-3 text-2xl font-bold">Have more questions?</h3>
            <p className="text-xl">
              If anything else is on your mind, feel free to{" "}
              <InlineLink href={CONTACT} label="Contact us">
                contact us
              </InlineLink>
              .
            </p>
          </div>
        </div>
      </Transition>
    </div>
  );
}
