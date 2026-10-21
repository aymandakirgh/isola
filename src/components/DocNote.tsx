import type { ReactNode } from "react";
import { flourishRef } from "../lib/hover";
import { DocLinesIcon } from "./icons";

/** "Updated …" note with the document glyph that flourishes on hover. */
export function DocNote({ children }: { children: ReactNode }) {
  return (
    <p ref={flourishRef} className="group dark:text-orange-75/50 flex items-center text-xl text-stone-500">
      <DocLinesIcon className="mr-2 size-[22px] fill-current" />
      <span>{children}</span>
    </p>
  );
}
