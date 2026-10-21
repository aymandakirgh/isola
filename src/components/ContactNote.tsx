import type { ReactNode } from "react";
import { CONTACT_EMAIL } from "../config";
import { InlineLink } from "./InlineLink";

/** "…, please contact us." footnote under download/recovery cards. */
export function ContactNote({ children }: { children: ReactNode }) {
  return (
    <p className="max-w-sm text-xl leading-normal">
      {children}{" "}
      <InlineLink href={`mailto:${CONTACT_EMAIL}`} label="Contact us">
        contact us
      </InlineLink>
      .
    </p>
  );
}
