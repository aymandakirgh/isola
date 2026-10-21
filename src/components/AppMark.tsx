import { squircle } from "../lib/squircle";

/** Inline Isola mark (bezel + screen + island pill), sized for running text. */
export function AppMark() {
  return (
    <span className="relative isolate mr-3 block size-6 overflow-hidden rounded-[0.4375rem]">
      <span ref={squircle} className="absolute inset-0 -z-10 rounded-[inherit] bg-stone-800 dark:bg-orange-100" />
      <span ref={squircle} className="bg-orange-75 absolute inset-[2px] -z-10 rounded-[5px] dark:bg-stone-900" />
      <span
        ref={squircle}
        className="dark:from-orange-75 dark:to-orange-75/15 absolute inset-[3.5px] origin-center rounded-[3.5px] bg-linear-to-t from-stone-950/20 to-stone-950 to-95% dark:inset-1 dark:rounded-[0.1875rem] dark:to-100%"
      >
        <span className="bg-orange-75 absolute top-[1.75px] left-1/2 h-[2.5px] w-[6.5px] -translate-x-1/2 rounded-full dark:bg-stone-900" />
      </span>
    </span>
  );
}
