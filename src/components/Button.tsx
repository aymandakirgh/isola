import type { ComponentProps, ReactNode, Ref } from "react";
import { cn } from "../lib/cn";
import { focusRingRef, squircle } from "../lib/squircle";
import { Transition } from "../lib/transition";
import { AppleLogo, ArrowIcon } from "./icons";

/** Squircle outline shown on keyboard focus (or forced via `show`). */
export function FocusRing({ className = "bg-rose-300/90 duration-300", show }: { className?: string; show?: boolean }) {
  return (
    <span
      aria-hidden="true"
      ref={focusRingRef}
      className={cn(
        "pointer-events-none absolute -inset-0.5 transition",
        show === undefined ? "opacity-0 group-focus-visible:opacity-100" : show ? "opacity-100" : "opacity-0",
        className,
      )}
    />
  );
}

type ButtonProps = Omit<ComponentProps<"a">, "type" | "ref"> & {
  href?: string;
  type?: "info" | null;
  loading?: boolean;
  ref?: Ref<HTMLElement>;
};

/** Primary dark button (or "info" tinted). Without href it renders the square icon button. */
export function Button({ href = "", type = null, loading = false, className = "", children, ref, ...rest }: ButtonProps) {
  if (!href)
    return (
      <button
        {...(rest as ComponentProps<"button">)}
        ref={ref as Ref<HTMLButtonElement>}
        disabled={loading}
        className={cn(
          "group text-orange-75 relative isolate ml-2.5 flex size-12 shrink-0 items-center justify-center rounded-2xl text-lg font-bold outline-hidden transition duration-300",
          className,
        )}
      >
        <span ref={squircle} className="absolute inset-0 -z-10 rounded-[inherit] bg-stone-800" />
        <FocusRing className="bg-purple-300/85 duration-300" />
        <Transition
          enterFrom="opacity-0"
          enterActive="transition duration-200"
          leaveActive="transition duration-150"
          leaveTo="opacity-0"
          mode="out-in"
        >
          {loading ? (
            <svg key="spinner" className="size-[22px]" viewBox="0 0 24 24" aria-hidden="true">
              <g className="origin-center animate-spin">
                <circle
                  className="animate-spinner stroke-current"
                  cx="12"
                  cy="12"
                  r="9.5"
                  fill="none"
                  strokeWidth="3"
                  strokeLinecap="round"
                />
              </g>
            </svg>
          ) : (
            <div key="content">{children}</div>
          )}
        </Transition>
      </button>
    );
  return (
    <a
      {...rest}
      ref={ref as Ref<HTMLAnchorElement>}
      href={href}
      className={cn(
        "group relative isolate inline-flex max-h-15 items-center justify-center rounded-2xl px-5 py-4 text-lg font-bold whitespace-nowrap outline-hidden transition duration-300",
        !type &&
          "text-orange-75 shadow-xl shadow-orange-950/20 after:absolute after:inset-0 after:hidden after:rounded-2xl after:shadow-2xl after:shadow-orange-950/25 after:content-[''] sm:shadow-orange-950/25 sm:after:block",
        className,
      )}
    >
      <span
        ref={squircle}
        className={cn(
          "absolute inset-0 -z-10 rounded-[inherit]",
          type === "info" ? "dark:bg-orange-75/5 bg-orange-950/5" : "bg-stone-800",
        )}
      />
      <FocusRing />
      {children}
    </a>
  );
}

/** Apple logo → label → arrow swap used by every "Download" style button. */
export function AppleLabel({
  label,
  logoPosition = "left-5",
  arrowPosition = "right-5",
  labelClassName = "",
  arrowClassName = "size-6",
}: {
  label: ReactNode;
  logoPosition?: string;
  arrowPosition?: string;
  labelClassName?: string;
  arrowClassName?: string;
}) {
  return (
    <>
      <div
        className={cn(
          "absolute translate-x-0 opacity-100 transition duration-300 group-hover:-translate-x-full group-hover:scale-x-50 group-hover:opacity-0 group-hover:blur-sm",
          logoPosition,
        )}
      >
        <AppleLogo className="size-[25px]" />
      </div>
      <div className={cn("translate-x-0 transition duration-300 group-hover:-translate-x-8", labelClassName)}>{label}</div>
      <div
        className={cn(
          "absolute translate-x-full scale-x-50 opacity-0 blur-sm transition duration-300 group-hover:translate-x-0 group-hover:scale-x-100 group-hover:opacity-100 group-hover:blur-none",
          arrowPosition,
        )}
      >
        <ArrowIcon className={arrowClassName} />
      </div>
    </>
  );
}

export function AppleButton({
  label,
  labelClassName,
  arrowClassName,
  className = "",
  ...rest
}: ButtonProps & { label: ReactNode; labelClassName?: string; arrowClassName?: string }) {
  return (
    <Button {...rest} className={cn("pl-13", className)}>
      <AppleLabel label={label} labelClassName={labelClassName} arrowClassName={arrowClassName} />
    </Button>
  );
}

/** Quiet header/footer button: tinted squircle fill on hover. */
export function NavButton({
  href = "",
  squircle: square = false,
  fillClass = "",
  className = "",
  children,
  ref,
  ...rest
}: Omit<ComponentProps<"a">, "ref"> & { squircle?: boolean; fillClass?: string; ref?: Ref<HTMLAnchorElement> }) {
  return (
    <a
      {...rest}
      ref={ref}
      href={href}
      className={cn(
        "group relative isolate inline-flex items-center justify-center outline-hidden transition duration-300",
        square
          ? "dark:text-orange-75 dark:hover:text-orange-75 rounded-xl p-2 text-orange-950/50 hover:text-orange-950/75"
          : "rounded-2xl px-5 py-4 text-lg font-bold",
        className,
      )}
    >
      <span
        ref={squircle}
        className={cn(
          "dark:group-hover:bg-orange-75/5 absolute inset-0 -z-10 rounded-[inherit] transition duration-300 group-hover:bg-orange-950/5",
          square && "dark:bg-orange-75/5 bg-orange-950/5",
          fillClass,
        )}
      />
      <FocusRing />
      {children}
    </a>
  );
}
