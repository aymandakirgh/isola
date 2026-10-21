import { BRAND } from "../config";
import { useAppVersion } from "../lib/appVersion";
import { cn } from "../lib/cn";
import { squircle } from "../lib/squircle";
import { AppleLabel, FocusRing } from "./Button";

function Skeleton({ className }: { className: string }) {
  return (
    <span
      className={cn(
        "relative top-px inline-block h-[13.5px] animate-pulse rounded-[0.1875rem] bg-orange-950/12.5",
        className,
      )}
      aria-hidden="true"
    />
  );
}

/** Disk-image card: icon, requirements, size/version and a download button. */
export function DownloadCard({ href }: { href: string }) {
  const { appSize, appVersion, appMinimumSystemVersion } = useAppVersion();
  return (
    <a
      className="group relative isolate my-12 flex w-full max-w-96 flex-col items-center justify-center rounded-3xl px-0.5 pt-5.5 pb-8.5 outline-hidden sm:my-16"
      href={href}
      download
      aria-label="Download for Mac"
    >
      <span
        ref={squircle}
        className="absolute inset-0 -z-10 rounded-[inherit] bg-orange-950/5"
      />
      <span
        ref={squircle}
        className="bg-orange-75 absolute inset-0.5 -z-10 rounded-[1.375rem] dark:bg-stone-900"
      />
      <span
        ref={squircle}
        className="absolute inset-0.5 -z-10 rounded-[1.375rem] bg-orange-950/2.5"
      />
      <div className="mb-3 size-37">
        <picture>
          <source srcSet="/images/disk-icon.webp" type="image/webp" />
          <img
            className="size-full select-none"
            src="/images/disk-icon.png"
            alt={`${BRAND} Disk Icon`}
            draggable="false"
          />
        </picture>
      </div>
      <p className="text-2xl font-bold">{BRAND}</p>
      <p className="text-lg font-semibold text-orange-950/60">
        {appMinimumSystemVersion ? (
          <>Minimum macOS {appMinimumSystemVersion}</>
        ) : (
          <Skeleton className="w-36" />
        )}
      </p>
      <p className="inline-flex min-h-6 items-center font-semibold text-orange-950/40">
        {appSize && appVersion ? (
          <>
            DMG, {appSize}MB
            <span className="mx-1.5 mt-px inline-block size-[3px] rounded-full bg-orange-950/40" />
            v{appVersion}
          </>
        ) : (
          <Skeleton className="w-24" />
        )}
      </p>
      <div className="text-orange-75 relative isolate mt-6 flex items-center rounded-[0.875rem] py-2.5 pr-5 pl-13 text-lg font-bold">
        <span
          ref={squircle}
          className="absolute inset-0 -z-10 rounded-[inherit] bg-stone-800 transition duration-200 group-hover:bg-stone-900"
        />
        <FocusRing />
        <AppleLabel
          label="Download"
          logoPosition="left-4.5"
          arrowPosition="right-4.5"
        />
      </div>
    </a>
  );
}
