import type { ReactNode } from "react";
import { ISSUES_URL } from "../config";
import { InlineLink } from "./InlineLink";

/** "…, please contact us." footnote under download/recovery cards. */
export function ContactNote({ children }: { children: ReactNode }) {
  return (
    <p className="max-w-sm text-xl leading-normal">
      {children}{" "}
      <InlineLink href={`${ISSUES_URL}/new`} label="Contact us">
        contact us
      </InlineLink>
      .
    </p>
  );
}
