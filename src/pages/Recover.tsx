import { useRef, useState, type ComponentProps, type Ref } from "react";
import { Button, FocusRing } from "../components/Button";
import { ContactNote } from "../components/ContactNote";
import { PAPER_PLANE_PATH, SEAL_PATH, SealIcon } from "../components/icons";
import { requestLicenseEmail } from "../lib/api";
import { useMinWidth } from "../lib/breakpoints";
import { cn } from "../lib/cn";
import { usePageTransition } from "../lib/router";
import { squircle } from "../lib/squircle";
import { Transition } from "../lib/transition";

type InputProps = Omit<ComponentProps<"input">, "ref" | "value"> & {
  value?: string;
  error?: boolean;
  onValueChange?: (value: string) => void;
  ref?: Ref<HTMLInputElement>;
};

/** Squircle text field with purple focus ring and rose error ring. */
function Input({
  value = "",
  readOnly = false,
  error = false,
  onValueChange,
  onFocus,
  onBlur,
  ref,
  ...rest
}: InputProps) {
  const [focused, setFocused] = useState(false);
  const active = focused && !error && !readOnly;
  return (
    <div className="group relative isolate flex w-full items-center rounded-[14px] p-0.5 text-base text-stone-900/95 transition duration-300">
      <FocusRing
        show={active || error}
        className={cn(
          "duration-300",
          error ? "bg-rose-300/90" : "bg-purple-300/90",
        )}
      />
      <span
        ref={squircle}
        className={cn(
          "absolute inset-0 -z-10 rounded-[inherit] transition duration-300",
          error && "bg-rose-300/30",
          !error &&
            (active
              ? "bg-purple-300/30"
              : "bg-orange-900/10 group-hover:bg-orange-900/20"),
        )}
      />
      <span
        ref={squircle}
        className="bg-orange-25 absolute inset-0.5 -z-10 rounded-[12px]"
      />
      <input
        {...rest}
        ref={ref}
        className={cn(
          "w-full grow rounded-[inherit] bg-transparent px-4 py-2.5 font-medium outline-hidden transition duration-300 placeholder:text-orange-950/35",
          error && "placeholder:text-rose-950/35",
        )}
        value={value}
        readOnly={readOnly}
        onChange={(e) => onValueChange?.(e.target.value)}
        onFocus={(e) => {
          setFocused(true);
          onFocus?.(e);
        }}
        onBlur={(e) => {
          setFocused(false);
          onBlur?.(e);
        }}
      />
    </div>
  );
}

const plane = (className: string) => (
  <svg
    className={cn("absolute inset-3 size-[22px] fill-current", className)}
    xmlns="http://www.w3.org/2000/svg"
    viewBox="0 0 28 28"
    aria-hidden="true"
  >
    <path d={PAPER_PLANE_PATH} />
  </svg>
);

/** Mini licence card that appears once the email has gone out. */
function LicenseFound() {
  return (
    <>
      <div className="relative isolate h-14 w-20 rounded-[0.5625rem] p-0.75 shadow-md shadow-orange-900/20 outline-1 outline-orange-900/10 outline-solid">
        <span
          ref={squircle}
          className="absolute inset-0 -z-10 rounded-[inherit] bg-linear-to-b from-orange-50 to-orange-100"
        />
        <div className="relative isolate flex h-full flex-col justify-between rounded-md px-[7px] py-[6.5px]">
          <span
            ref={squircle}
            className="absolute inset-0 -z-10 rounded-[inherit] bg-orange-950/40"
          />
          <span
            ref={squircle}
            className="absolute inset-[1.5px] -z-10 rounded-[4.5px] bg-orange-100"
          />
          <div className="space-y-[2.5px]">
            <div className="h-[2.5px] w-full rounded-full bg-teal-400" />
            <div className="h-[2.5px] w-3/4 rounded-full bg-teal-400" />
          </div>
          <div className="mt-[6px] flex space-x-1.5">
            <div className="mb-px w-full space-y-[1.5px]">
              {[
                "w-full",
                "w-full",
                "w-full",
                "w-full",
                "w-full",
                "w-full",
                "w-2/3",
              ].map((w, i) => (
                <div
                  key={i}
                  className={cn("h-[1.5px] rounded-full bg-orange-950/20", w)}
                />
              ))}
            </div>
            <Transition
              enterFrom="-rotate-135 opacity-0 blur-xs scale-[0.4]"
              enterActive="transition duration-400 delay-250"
              appear
            >
              <svg
                className="-mt-px -ml-px size-5 shrink-0 fill-current text-orange-950/30"
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 28 28"
                aria-hidden="true"
              >
                <path d={SEAL_PATH} />
              </svg>
            </Transition>
          </div>
        </div>
      </div>
      <div>
        <p className="text-xl font-bold">License found!</p>
        <p className="text-lg font-semibold text-orange-950/60">
          Check your inbox.
        </p>
      </div>
    </>
  );
}

export default function Recover() {
  const page = usePageTransition();
  const md = useMinWidth("md");
  const input = useRef<HTMLInputElement>(null);
  const [email, setEmail] = useState("");
  const [error, setError] = useState(false);
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);

  const submit = async () => {
    const fail = () => {
      setError(true);
      input.current?.focus();
    };
    setError(false);
    setLoading(true);
    try {
      if ((await requestLicenseEmail(email)).ok) return setSent(true);
      setEmail("");
      fail();
    } catch {
      fail();
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className={cn("w-full max-w-(--breakpoint-md) text-center", page)}>
      <Transition
        enterFrom="rotate-2 translate-y-8 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <h1 className="mb-3 text-6xl font-bold tracking-tight opacity-0 delay-500 sm:text-8xl">
          Recover {md ? "your" : "a"}
          <br />
          <mark className="relative -ml-1.5 after:bg-purple-300/85">
            <SealIcon
              className="absolute top-1.5 left-1.5 inline-block size-12 fill-current sm:size-21"
              spinClassName="animate-rotate-slow"
            />
            <span className="pl-15 sm:pl-24">license</span>
          </mark>
        </h1>
      </Transition>
      <Transition
        enterFrom="translate-y-5 opacity-0"
        enterActive="transition duration-500"
        appear
      >
        <div className="mx-auto flex max-w-120 flex-col items-center justify-center opacity-0 delay-500">
          <div
            className={cn(
              "relative isolate my-12 flex h-52.5 w-full max-w-[24rem] justify-center rounded-4xl px-9.5 pt-8.5 pb-9.5 outline-hidden sm:my-16 sm:px-10.5 sm:pt-9 sm:pb-10.5",
              error && "animate-shake",
            )}
          >
            <span
              ref={squircle}
              className="absolute inset-0 -z-10 rounded-[inherit] bg-orange-800/10"
            />
            <span
              ref={squircle}
              className="absolute inset-0.5 -z-10 rounded-[1.875rem] bg-orange-50"
            />
            <Transition
              enterFrom="opacity-0 -translate-y-2"
              enterActive="transition duration-300"
              leaveActive="transition duration-300"
              leaveTo="opacity-0 translate-y-2"
              mode="out-in"
            >
              {sent ? (
                <div
                  key="success"
                  className="flex flex-col items-center justify-between"
                >
                  <LicenseFound />
                </div>
              ) : (
                <div
                  key="form"
                  className="flex w-full flex-col items-center justify-between"
                >
                  <div>
                    <p className="text-2xl font-bold">Lost your license?</p>
                    <p className="text-lg font-semibold text-orange-950/60">
                      Enter your email address{md ? " below" : ""}
                    </p>
                  </div>
                  <div className="flex w-full items-center justify-center space-x-3">
                    <Input
                      ref={input}
                      type="email"
                      autoComplete="email"
                      aria-label="Email address"
                      value={email}
                      placeholder={
                        md ? "e.g. you@example.com" : "you@example.com"
                      }
                      error={error}
                      onValueChange={(v) => {
                        setEmail(v);
                        setError(false);
                      }}
                      onKeyUp={(e) => e.key === "Enter" && submit()}
                      onBlur={() => setError(false)}
                    />
                    <Button
                      className="text-orange-50"
                      loading={loading}
                      aria-label="Send"
                      onClick={submit}
                    >
                      {plane(
                        "origin-top-right -translate-x-full translate-y-full scale-75 rotate-16 opacity-0 blur-sm transition duration-200 ease-out group-hover:translate-x-0 group-hover:translate-y-0 group-hover:scale-100 group-hover:rotate-0 group-hover:opacity-100 group-hover:blur-none group-hover:delay-100 group-hover:duration-300",
                      )}
                      {plane(
                        "origin-top-right text-orange-50 transition delay-75 duration-150 group-hover:translate-x-2/3 group-hover:-translate-y-2/3 group-hover:scale-75 group-hover:-rotate-10 group-hover:opacity-0 group-hover:blur-sm group-hover:delay-0 group-hover:duration-200",
                      )}
                    </Button>
                  </div>
                </div>
              )}
            </Transition>
          </div>
          <ContactNote>
            Having trouble recovering your license? Please
          </ContactNote>
        </div>
      </Transition>
    </div>
  );
}
