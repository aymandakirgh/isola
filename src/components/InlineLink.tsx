import type { ReactNode } from "react";

const LINK =
  "relative font-medium whitespace-nowrap outline-hidden transition duration-200 after:pointer-events-none after:absolute after:right-0 after:bottom-0 after:left-0 after:h-0.5 after:rounded-xs after:bg-teal-400 after:transition after:duration-200 after:content-[''] hover:text-teal-400 hover:after:translate-y-px focus-visible:text-teal-400 focus-visible:after:h-[3px] focus-visible:after:translate-y-px";

/** Teal-underlined text link (internal hrefs are routed by App's click handler). */
export function InlineLink({ href, label, children }: { href: string; label: string; children: ReactNode }) {
  return (
    <a className={LINK} href={href} aria-label={label}>
      {children}
    </a>
  );
}
