// Isola glyph set. Original geometry drawn on the same grids as the reference
// (so the shared animation classes and transform-origins land the same way).
// Apple, X and Discord marks are Simple Icons paths (CC0), rescaled.
import { useId, type Ref } from "react";
import { cn } from "../lib/cn";

type P = { className?: string };

// Mask/gradient ids must be valid in url(#…).
const useUid = (prefix: string) =>
  `${prefix}-${useId().replace(/[^a-zA-Z0-9]/g, "")}`;

const n = (v: number) => +v.toFixed(2);
// Four-point sparkle centred on (x, y) with arm length r.
function sparkle(x: number, y: number, r: number, k = 0.16) {
  const c = r * k;
  return `M${n(x)} ${n(y - r)}Q${n(x + c)} ${n(y - c)} ${n(x + r)} ${n(y)}Q${n(x + c)} ${n(y + c)} ${n(x)} ${n(y + r)}Q${n(x - c)} ${n(y + c)} ${n(x - r)} ${n(y)}Q${n(x - c)} ${n(y - c)} ${n(x)} ${n(y - r)}Z`;
}

const stroke = {
  fill: "none",
  stroke: "currentColor",
  strokeLinecap: "round",
  strokeLinejoin: "round",
} as const;

/* ── Brand marks (Simple Icons, CC0) ─────────────────────────────────── */

export const APPLE_BODY_PATH =
  "M12.185 6.603C11.415 6.603 10.223 5.727 8.968 5.758C7.31 5.78 5.791 6.719 4.937 8.207C3.217 11.193 4.494 15.603 6.171 18.03C6.994 19.211 7.965 20.541 9.252 20.499C10.487 20.446 10.95 19.697 12.45 19.697C13.937 19.697 14.359 20.499 15.667 20.468C16.997 20.446 17.841 19.265 18.654 18.072C19.593 16.701 19.983 15.371 20.004 15.298C19.973 15.287 17.419 14.306 17.388 11.351C17.367 8.881 19.403 7.7 19.498 7.647C18.337 5.949 16.554 5.759 15.931 5.717C14.306 5.59 12.945 6.602 12.185 6.602Z";
export const APPLE_LEAF_PATH =
  "M14.93 4.112C15.615 3.29 16.068 2.14 15.942 1C14.961 1.042 13.779 1.654 13.072 2.477C12.438 3.205 11.891 4.377 12.038 5.495C13.125 5.579 14.244 4.936 14.929 4.113Z";

export function AppleLogo({ className }: P) {
  return (
    <svg
      className={cn("fill-current", className)}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path d={APPLE_BODY_PATH + APPLE_LEAF_PATH} />
    </svg>
  );
}

export function XLogo({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M13.675 10.622L20.233 3L18.679 3L12.986 9.618L8.438 3L3.194 3L10.069 13.007L3.194 21L4.748 21L10.759 14.011L15.562 21L20.806 21ZM11.548 13.096L10.851 12.099L5.307 4.17L7.694 4.17L12.167 10.569L12.864 11.566L18.679 19.883L16.293 19.883Z" />
    </svg>
  );
}

export function DiscordLogo({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M19.153 5.438A17.021 17.021 0 0 0 14.951 4.135A0.064 0.064 0 0 0 14.884 4.167C14.702 4.49 14.501 4.911 14.361 5.241C12.774 5.004 11.196 5.004 9.642 5.241C9.501 4.903 9.293 4.49 9.111 4.167A0.066 0.066 0 0 0 9.043 4.135A16.973 16.973 0 0 0 4.842 5.438A0.06 0.06 0 0 0 4.815 5.462C2.139 9.459 1.406 13.359 1.765 17.21A0.071 0.071 0 0 0 1.792 17.258C3.558 18.554 5.268 19.342 6.946 19.863A0.067 0.067 0 0 0 7.018 19.84C7.415 19.297 7.769 18.726 8.073 18.124A0.065 0.065 0 0 0 8.037 18.034C7.476 17.821 6.941 17.561 6.427 17.266A0.066 0.066 0 0 1 6.42 17.156C6.529 17.075 6.637 16.991 6.74 16.906A0.064 0.064 0 0 1 6.807 16.897C10.185 18.439 13.842 18.439 17.18 16.897A0.064 0.064 0 0 1 17.247 16.905C17.351 16.99 17.459 17.075 17.568 17.156A0.066 0.066 0 0 1 17.562 17.266A10.577 10.577 0 0 1 15.951 18.033A0.066 0.066 0 0 0 15.916 18.124C16.226 18.725 16.58 19.296 16.97 19.839A0.065 0.065 0 0 0 17.042 19.863C18.729 19.341 20.439 18.554 22.204 17.258A0.066 0.066 0 0 0 22.231 17.21C22.662 12.758 21.51 8.891 19.179 5.463A0.052 0.052 0 0 0 19.153 5.438ZM8.577 14.865C7.56 14.865 6.722 13.931 6.722 12.784C6.722 11.638 7.544 10.704 8.577 10.704C9.619 10.704 10.448 11.646 10.432 12.785C10.432 13.931 9.61 14.865 8.577 14.865ZM15.436 14.865C14.419 14.865 13.581 13.931 13.581 12.784C13.581 11.638 14.402 10.704 15.436 10.704C16.477 10.704 17.307 11.646 17.29 12.785C17.29 13.931 16.477 14.865 15.436 14.865Z" />
    </svg>
  );
}

// Footer mark for the sibling app, Brezza: two curling gusts of wind.
export function SiblingAppGlyph({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 36 36" aria-hidden="true">
      <path d="M0 0h36v36H0z" />
      <path
        className="text-orange-75 dark:text-stone-900"
        {...stroke}
        strokeWidth="2.6"
        d="M9.5 14.2h12a3.4 3.4 0 1 0-3.4-3.4M9.5 19.4h16a3.6 3.6 0 1 1-3.6 3.6M9.5 24.6h6.6"
      />
    </svg>
  );
}

/* ── Home: hint, lock screen ─────────────────────────────────────────── */

export function CursorIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        d="M6.4 3.6 9.6 23.9l5.3-5.3 9-.9Z"
        stroke="currentColor"
        strokeWidth="2.4"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function BedIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 30 28" aria-hidden="true">
      <path d="M1 16.4A3.4 3.4 0 0 1 4.4 13h21.2a3.4 3.4 0 0 1 3.4 3.4V24a1 1 0 0 1-1 1h-1.3a1 1 0 0 1-1-1v-1.7H4.3V24a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1Z" />
      <rect x="5.4" y="8.1" width="8.4" height="3.6" rx="1.8" />
      <rect x="16.2" y="8.1" width="8.4" height="3.6" rx="1.8" />
      <path
        {...stroke}
        strokeWidth="2"
        d="M3.7 11.4V7.7A3.7 3.7 0 0 1 7.4 4h15.2a3.7 3.7 0 0 1 3.7 3.7v3.7"
      />
    </svg>
  );
}

export function WorkIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        fillRule="evenodd"
        d="M8.6 2h10.8A3.6 3.6 0 0 1 23 5.6v16.8a3.6 3.6 0 0 1-3.6 3.6H8.6A3.6 3.6 0 0 1 5 22.4V5.6A3.6 3.6 0 0 1 8.6 2ZM11.2 4.3a.9.9 0 0 0 0 1.8h5.6a.9.9 0 0 0 0-1.8ZM14 10a3.2 3.2 0 1 0 0 6.4A3.2 3.2 0 0 0 14 10Zm-5.5 12.4c.4-2.8 2.7-4.6 5.5-4.6s5.1 1.8 5.5 4.6c.1.6-.3 1-.9 1H9.4c-.6 0-1-.4-.9-1Z"
      />
    </svg>
  );
}

const MOON_PATH = "M9.88 6.23A10 10 0 1 0 21.92 17.26A8.5 8.5 0 0 1 9.88 6.23Z" + sparkle(21.6, 7.4, 3.4) + sparkle(15.4, 3.6, 2.2);

export function MoonIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path d={MOON_PATH} />
    </svg>
  );
}

export function SunIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <circle cx="14" cy="14" r="5.2" />
      <path
        {...stroke}
        strokeWidth="2.2"
        d="M22.3 14h3M19.87 19.87l2.12 2.12M14 22.3v3M8.13 19.87l-2.12 2.12M5.7 14h-3M8.13 8.13 6.01 6.01M14 5.7v-3M19.87 8.13l2.12-2.12"
      />
    </svg>
  );
}

/* ── Notch ───────────────────────────────────────────────────────────── */

export function NotchLockIcon({
  unlocked,
  className,
}: P & { unlocked: boolean }) {
  return (
    <svg className={className} viewBox="0 0 16 16" aria-hidden="true">
      <path
        className={cn(
          "origin-[56%_50%] transition duration-300",
          unlocked && "-scale-x-100",
        )}
        {...stroke}
        strokeWidth="1.3"
        d="M5 7V4.85a2.85 2.85 0 0 1 5.7 0V7"
      />
      <path
        className={cn(
          "origin-center transition duration-300",
          unlocked && "-translate-x-px",
        )}
        d="M4.6 6.3h6.1a1.6 1.6 0 0 1 1.6 1.6v4.8a1.6 1.6 0 0 1-1.6 1.6H4.6A1.6 1.6 0 0 1 3 12.7V7.9a1.6 1.6 0 0 1 1.6-1.6Z"
      />
    </svg>
  );
}

export function MusicNoteIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path d="M13.2 5.6v12.1a4.1 4.1 0 1 0 1.9 3.5V10l6-1.4V3.9c0-.7-.6-1.2-1.3-1l-5.4 1.3c-.7.2-1.2.8-1.2 1.4Z" />
    </svg>
  );
}

export const PAUSE_PATH =
  "M8.9 4.6h2.6c.9 0 1.6.7 1.6 1.6v15.6c0 .9-.7 1.6-1.6 1.6H8.9c-.9 0-1.6-.7-1.6-1.6V6.2c0-.9.7-1.6 1.6-1.6ZM16.5 4.6h2.6c.9 0 1.6.7 1.6 1.6v15.6c0 .9-.7 1.6-1.6 1.6h-2.6c-.9 0-1.6-.7-1.6-1.6V6.2c0-.9.7-1.6 1.6-1.6Z";
export const PLAY_PATH =
  "M8.9 4.6C7.9 4 6.6 4.7 6.6 5.9v16.2c0 1.2 1.3 1.9 2.3 1.3l13.1-8.1c1-.6 1-2 0-2.6Z";

/* ── Lock-screen now-playing widget ──────────────────────────────────── */

export function ShuffleIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        {...stroke}
        strokeWidth="2"
        d="M3 8.6h3.3c2.1 0 3.4.9 4.6 2.5l4.6 6.1c1.2 1.6 2.5 2.5 4.6 2.5H24M3 19.7h3.3c2.1 0 3.4-.9 4.6-2.5l4.6-6.1c1.2-1.6 2.5-2.5 4.6-2.5H24M21 5.4l3.2 3.2-3.2 3.2M21 16.5l3.2 3.2-3.2 3.2"
      />
    </svg>
  );
}

export function BackwardIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 33 28" aria-hidden="true">
      <path d="M15.8 6.7v14.6c0 1.05-1.15 1.7-2.05 1.15L2.2 15.15c-.87-.52-.87-1.78 0-2.3L13.75 5.55c.9-.55 2.05.1 2.05 1.15ZM30.4 6.7v14.6c0 1.05-1.15 1.7-2.05 1.15L16.8 15.15c-.87-.52-.87-1.78 0-2.3L28.35 5.55c.9-.55 2.05.1 2.05 1.15Z" />
    </svg>
  );
}

export function ForwardIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 33 28" aria-hidden="true">
      <path d="M2.6 6.7v14.6c0 1.05 1.15 1.7 2.05 1.15L16.2 15.15c.87-.52.87-1.78 0-2.3L4.65 5.55c-.9-.55-2.05.1-2.05 1.15ZM17.2 6.7v14.6c0 1.05 1.15 1.7 2.05 1.15L30.8 15.15c.87-.52.87-1.78 0-2.3L19.25 5.55c-.9-.55-2.05.1-2.05 1.15Z" />
    </svg>
  );
}

export function PlayIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path d={PLAY_PATH} />
    </svg>
  );
}

export function LaptopOutputIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 34 28" aria-hidden="true">
      <path fillOpacity="0.3" d="M6.4 5.9h21.2v14.2H6.4Z" />
      <path d="M6.7 4h20.6a2.2 2.2 0 0 1 2.2 2.2v13.9h-1.9V6.6c0-.4-.3-.7-.7-.7h-7.3v.4c0 .6-.4 1-1 1h-3.2c-.6 0-1-.4-1-1v-.4H7.1c-.4 0-.7.3-.7.7v13.5H4.5V6.2A2.2 2.2 0 0 1 6.7 4ZM1 21.75c0-.9.7-1.65 1.65-1.65h28.7c.9 0 1.65.75 1.65 1.65s-.75 1.65-1.65 1.65H2.65C1.7 23.4 1 22.65 1 21.75Z" />
    </svg>
  );
}

/* ── Menu bar ────────────────────────────────────────────────────────── */

// Isola's own menu-bar glyph: a squircle ring around a glowing screen with the island on top.
export function MenuBarAppIcon({ className }: P) {
  const id = useUid("menubar");
  return (
    <svg className={className} viewBox="0 0 16 16" aria-hidden="true">
      <defs>
        <linearGradient id={id} x1="50%" x2="50%" y1="0%" y2="90%">
          <stop offset="0%" stopColor="#fff7ed" stopOpacity=".2" />
          <stop offset="100%" stopColor="#fff7ed" />
        </linearGradient>
      </defs>
      <g fillRule="evenodd">
        <path
          className="fill-current text-orange-50/75"
          d="M4.6 0h6.8A4.6 4.6 0 0 1 16 4.6v6.8a4.6 4.6 0 0 1-4.6 4.6H4.6A4.6 4.6 0 0 1 0 11.4V4.6A4.6 4.6 0 0 1 4.6 0ZM4.65 1.25h6.7a3.4 3.4 0 0 1 3.4 3.4v6.7a3.4 3.4 0 0 1-3.4 3.4h-6.7a3.4 3.4 0 0 1-3.4-3.4v-6.7a3.4 3.4 0 0 1 3.4-3.4Z"
        />
        <path
          fill={`url(#${id})`}
          d="M4.7 2.5h6.6a2.2 2.2 0 0 1 2.2 2.2v6.6a2.2 2.2 0 0 1-2.2 2.2H4.7a2.2 2.2 0 0 1-2.2-2.2V4.7a2.2 2.2 0 0 1 2.2-2.2Z"
        />
        <path
          className="fill-current text-orange-50"
          d="M6.8 3.85h2.4a.72.72 0 0 1 0 1.44H6.8a.72.72 0 0 1 0-1.44Z"
        />
      </g>
    </svg>
  );
}

export function WifiIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        {...stroke}
        strokeWidth="2.4"
        d="M2.59 10.76A15.6 15.6 0 0 1 25.41 10.76M6.25 14.17A10.6 10.6 0 0 1 21.75 14.17M9.9 17.58A5.6 5.6 0 0 1 18.1 17.58"
      />
      <circle cx="14" cy="21.4" r="2" />
    </svg>
  );
}

export function ControlCenterIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <g fill="none" stroke="currentColor" strokeWidth="1.8">
        <rect x="3" y="3.6" width="22" height="9.4" rx="4.7" />
        <rect x="3" y="15" width="22" height="9.4" rx="4.7" />
      </g>
      <circle cx="8.3" cy="8.3" r="3.1" />
      <circle cx="19.7" cy="19.7" r="3.1" />
    </svg>
  );
}

/* ── Feature grid (outer svg classes come from the caller) ───────────── */

export function BellIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        className="origin-top transition duration-300 group-hover:rotate-12"
        {...stroke}
        strokeWidth="1.8"
        d="M14 3.6c-4.2 0-6.8 3.1-6.8 7.6v4.3c0 1.5-.6 2.8-1.6 3.8l-.6.6c-.7.7-.2 1.7.8 1.7h16.4c1 0 1.5-1 .8-1.7l-.6-.6c-1-1-1.6-2.3-1.6-3.8v-4.3c0-4.5-2.6-7.6-6.8-7.6Z"
      />
      <path
        className="stroke-orange-75 stroke-[1.5px]"
        d="M20.2 2.2a4 4 0 1 1 0 8 4 4 0 0 1 0-8Z"
      />
      <path
        className="origin-center transition delay-25 duration-350 group-hover:-translate-x-1 group-hover:-translate-y-px group-hover:rotate-12"
        {...stroke}
        strokeWidth="1.8"
        d="M11.5 23.9a2.5 2.5 0 0 0 5 0"
      />
    </svg>
  );
}

export function LiveActivityIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        {...stroke}
        strokeWidth="1.9"
        d="M23.3 11.74A10.6 10.6 0 1 1 16.26 4.7"
      />
      <circle cx="20.66" cy="7.35" r="3.3" />
      <path
        className="origin-[47%_53%] transition duration-350 group-hover:rotate-180"
        {...stroke}
        strokeWidth="1.9"
        d="M13.16 14.84V8.9"
      />
      <path
        className="origin-[47%_53%] transition duration-300 group-hover:rotate-45"
        {...stroke}
        strokeWidth="1.9"
        d="M13.16 14.84H8.2"
      />
    </svg>
  );
}

export function SwipeIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        className="origin-[75%_75%] transition duration-350 group-hover:-rotate-40"
        {...stroke}
        strokeWidth="1.8"
        d="M10.6 17.6V4.6a1.6 1.6 0 0 1 3.2 0v7.8a1.75 1.75 0 1 1 3.3.2 1.7 1.7 0 1 1 3.2.8 1.6 1.6 0 1 1 3 1.3v4.3c0 4-2.7 6.7-6.4 6.7h-2.1c-2.4 0-4-1.1-5.3-3l-2.6-3.8a1.55 1.55 0 0 1 2.5-1.8l1.2 1.6Z"
      />
      <g className="transition duration-200 group-hover:opacity-0 group-hover:delay-50">
        <path
          className="fill-transparent stroke-current stroke-[1.5px] transition-all duration-350 group-hover:duration-250 group-hover:[stroke-dashoffset:12]"
          strokeLinecap="round"
          strokeLinejoin="round"
          strokeDasharray="12"
          strokeDashoffset="0"
          d="M2.2 16.4C2 12.7 3.8 9 7.1 7"
        />
      </g>
    </svg>
  );
}

export function GiftIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        {...stroke}
        strokeWidth="1.8"
        d="M5.6 14.1h16.8v8.5a2.9 2.9 0 0 1-2.9 2.9h-11a2.9 2.9 0 0 1-2.9-2.9ZM14 14.1v11.4"
      />
      <g
        className="origin-[85%_45%] transition duration-300 group-hover:rotate-18"
        {...stroke}
        strokeWidth="1.8"
      >
        <rect x="3.6" y="8.4" width="20.8" height="5.7" rx="1.6" />
        <path d="M14 8.4v5.7M14 8.4C13.2 5.4 11.6 3.6 9.6 3.6c-1.3 0-2.2.9-2.2 2.1 0 1.6 1.7 2.7 4.3 2.7ZM14 8.4c.8-3 2.4-4.8 4.4-4.8 1.3 0 2.2.9 2.2 2.1 0 1.6-1.7 2.7-4.3 2.7Z" />
      </g>
    </svg>
  );
}

export function HudIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        {...stroke}
        strokeWidth="1.8"
        d="M6.4 19.6h-1a2.8 2.8 0 0 1-2.8-2.8V5.4a2.8 2.8 0 0 1 2.8-2.8h11.4a2.8 2.8 0 0 1 2.8 2.8v1M9.6 6.4h12.6a3.2 3.2 0 0 1 3.2 3.2v12.6a3.2 3.2 0 0 1-3.2 3.2H9.6a3.2 3.2 0 0 1-3.2-3.2V9.6a3.2 3.2 0 0 1 3.2-3.2ZM10.2 12.6h11.4M10.2 19.2h11.4"
      />
      <circle
        className="origin-center transition duration-300 group-hover:-translate-x-[3.75px]"
        cx="17.6"
        cy="12.6"
        r="2.5"
      />
      <circle
        className="origin-center transition duration-300 group-hover:translate-x-[3.75px]"
        cx="14.2"
        cy="19.2"
        r="2.5"
      />
    </svg>
  );
}

export function LockScreenIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <rect
        x="1.6"
        y="4.4"
        width="24.8"
        height="19.2"
        rx="3.4"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
      />
      <path
        className="origin-[55%_50%] transition duration-300 group-hover:-scale-x-100"
        {...stroke}
        strokeWidth="1.5"
        d="M11.6 12.8V11a2.4 2.4 0 0 1 4.8 0v1.8"
      />
      <path
        className="origin-center transition duration-300 group-hover:-translate-x-px"
        d="M11.6 12.6h4.8a1.6 1.6 0 0 1 1.6 1.6v3.6a1.6 1.6 0 0 1-1.6 1.6h-4.8a1.6 1.6 0 0 1-1.6-1.6v-3.6a1.6 1.6 0 0 1 1.6-1.6Z"
      />
    </svg>
  );
}

const BOLT =
  "M16.4 2.6c.6-.8 1.8-.2 1.6.8l-1.6 8.2h5.4c.9 0 1.4 1 .8 1.7L11.6 25.4c-.6.8-1.8.2-1.6-.8l1.6-8.2H6.2c-.9 0-1.4-1-.8-1.7Z";

export function BoltIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path
        className="origin-[50%_40%] scale-[0.25] opacity-0 blur-sm transition duration-300 group-hover:-translate-x-1 group-hover:-translate-y-2 group-hover:scale-50 group-hover:opacity-100 group-hover:blur-none"
        d={BOLT}
      />
      <path
        className="origin-center transition duration-300 group-hover:translate-x-1 group-hover:delay-100"
        d={BOLT}
      />
    </svg>
  );
}

// Hand-drawn loop under "Blazing fast native app"; drawn in by animate-draw.
export function BlazingScribble({
  className,
  ref,
}: P & { ref?: Ref<SVGSVGElement> }) {
  return (
    <svg
      ref={ref}
      className={className}
      viewBox="0 0 176 55"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeDasharray="500"
      strokeDashoffset="500"
      aria-hidden="true"
    >
      <path d="M24 10.8C52 4.4 99 1.7 131 4.1c27 2 41 9.2 40 21.6-1 13.6-41 22.6-84.2 25.4C44.6 53.8 3.2 49.6 5 33.4 6.8 17.6 62.4 6.2 127.6 5.8" />
    </svg>
  );
}

/* ── Header & buttons ────────────────────────────────────────────────── */

const BUBBLE =
  "M5.7 2.3h12.6a4.2 4.2 0 0 1 4.2 4.2v7.4a4.2 4.2 0 0 1-4.2 4.2h-6.2l-3.9 3.4c-.7.6-1.7.1-1.7-.8v-2.6h-.8a4.2 4.2 0 0 1-4.2-4.2V6.5a4.2 4.2 0 0 1 4.2-4.2Z";

export function FaqIcon({ className }: P) {
  const id = useUid("faqs");
  return (
    <svg
      className={
        className ??
        "size-[25px] origin-bottom fill-current transition duration-300 group-hover:-rotate-12 sm:mr-2"
      }
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <mask id={id}>
        <path fill="white" d={BUBBLE} />
        <path
          className="origin-top-left transition duration-300 group-hover:-rotate-3 group-hover:delay-50"
          stroke="black"
          strokeWidth="1.8"
          strokeLinecap="round"
          d="M6.8 8.5H17.2M6.8 12.1H13"
        />
      </mask>
      <path mask={`url(#${id})`} d={BUBBLE} />
    </svg>
  );
}

const SHEET =
  "M6.6.6h10.8A3.4 3.4 0 0 1 20.8 4v16a3.4 3.4 0 0 1-3.4 3.4H6.6A3.4 3.4 0 0 1 3.2 20V4A3.4 3.4 0 0 1 6.6.6Z";

export function ChangelogIcon({ className }: P) {
  const id = useUid("changelog");
  return (
    <svg
      className={
        className ??
        "mr-2 size-[22px] overflow-visible fill-current transition-colors duration-300"
      }
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <mask id={id}>
        <path fill="white" d={SHEET} />
        <circle cx="8.6" cy="7.2" r="1.9" fill="black" />
        <path
          stroke="black"
          strokeWidth="1.8"
          strokeLinecap="round"
          d="M12.2 7.2h3.6"
        />
        <path
          className="transition duration-300 group-hover:-translate-y-[3.34px] group-hover:opacity-0"
          stroke="black"
          strokeWidth="1.8"
          strokeLinecap="round"
          d="M8 14.86H16"
        />
        <path
          className="transition-all duration-300 group-hover:-translate-y-[3.34px] group-hover:[stroke-dashoffset:0]"
          stroke="black"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeDasharray="8"
          strokeDashoffset="4.3"
          d="M8 18.2H16"
        />
        <path
          className="opacity-0 transition-all duration-500 group-hover:opacity-100 group-hover:delay-75 group-hover:[stroke-dashoffset:0]"
          stroke="black"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeDasharray="6"
          strokeDashoffset="6"
          d="M8 18.2H11.7"
        />
      </mask>
      <path mask={`url(#${id})`} d={SHEET} />
    </svg>
  );
}

export function ArrowIcon({ className }: P) {
  return (
    <svg
      className={cn("fill-transparent stroke-current stroke-2", className)}
      viewBox="0 0 24 24"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M4.6 12h14.2M13.1 5.6 19.5 12l-6.4 6.4" />
    </svg>
  );
}

// 12-lobe scalloped seal and a filled check, both on a 28 grid.
export const SEAL_PATH =
  "M14 3.1A2.9 2.9 0 0 1 19.45 4.56A2.9 2.9 0 0 1 23.44 8.55A2.9 2.9 0 0 1 24.9 14A2.9 2.9 0 0 1 23.44 19.45A2.9 2.9 0 0 1 19.45 23.44A2.9 2.9 0 0 1 14 24.9A2.9 2.9 0 0 1 8.55 23.44A2.9 2.9 0 0 1 4.56 19.45A2.9 2.9 0 0 1 3.1 14A2.9 2.9 0 0 1 4.56 8.55A2.9 2.9 0 0 1 8.55 4.56A2.9 2.9 0 0 1 14 3.1Z";
export const CHECK_PATH =
  "M10.48 13.78L12.54 15.98L17.67 9.64A1.2 1.2 0 0 1 19.53 11.16L13.53 18.56A1.2 1.2 0 0 1 11.72 18.62L8.72 15.42A1.2 1.2 0 0 1 10.48 13.78Z";

export function SealIcon({
  className,
  spinClassName = "animate-rotate",
}: P & { spinClassName?: string }) {
  return (
    <svg
      className={cn("fill-current", className)}
      viewBox="0 0 28 28"
      aria-hidden="true"
    >
      <path
        className={cn("running origin-center", spinClassName)}
        d={SEAL_PATH}
      />
      <path className="text-orange-75" d={CHECK_PATH} />
    </svg>
  );
}

// "macOS 15 or later": a small display with the island cut into its screen.
export function MacOsIcon({ className }: P) {
  return (
    <svg
      className={cn("fill-current", className)}
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        d="M5 3h14a3 3 0 0 1 3 3v8.6a3 3 0 0 1-3 3H5a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3Zm.4 2.1a1.2 1.2 0 0 0-1.2 1.2v8a1.2 1.2 0 0 0 1.2 1.2h13.2a1.2 1.2 0 0 0 1.2-1.2v-8a1.2 1.2 0 0 0-1.2-1.2h-3.8v.3c0 .7-.5 1.2-1.2 1.2h-3.2c-.7 0-1.2-.5-1.2-1.2v-.3ZM10.6 17.6h2.8v1.8h2.4c.6 0 1 .4 1 1s-.4 1-1 1H8.2c-.6 0-1-.4-1-1s.4-1 1-1h2.4Z"
      />
    </svg>
  );
}

/* ── FAQ, changelog, recover, purchased ──────────────────────────────── */

const SHIELD =
  "M12.9 2.9c.7-.4 1.5-.4 2.2 0 2.4 1.3 4.9 2.1 7.6 2.5.7.1 1.1.7 1.1 1.4v6.7c0 5.9-3.5 9.8-8.9 12.1-.6.3-1.2.3-1.8 0C7.7 23.3 4.2 19.4 4.2 13.5V6.8c0-.7.4-1.3 1.1-1.4 2.7-.4 5.2-1.2 7.6-2.5Z";
// Inner glyphs wind the other way so they punch out under the default nonzero rule.
export const SHIELD_CHECK_PATH =
  SHIELD +
  "M11.132 13.256A0.984 0.984 0 0 0 9.688 14.6L12.148 17.224A0.984 0.984 0 0 0 13.633 17.175L18.553 11.107A0.984 0.984 0 0 0 17.027 9.861L12.821 15.06Z";
export const SHIELD_ALERT_PATH =
  SHIELD +
  "M15.1 8.9A1.1 1.1 0 0 0 12.9 8.9V14.6A1.1 1.1 0 0 0 15.1 14.6ZM14 17.6A1.35 1.35 0 0 0 14 20.3A1.35 1.35 0 0 0 14 17.6Z";
export const SHIELD_LOCK_PATH =
  SHIELD +
  "M11 13H12.25V11.4A1.75 1.75 0 0 1 15.75 11.4V13H17V11.4A3 3 0 0 0 11 11.4ZM17.8 14.3A1.3 1.3 0 0 0 16.5 13H11.5A1.3 1.3 0 0 0 10.2 14.3V18.1A1.3 1.3 0 0 0 11.5 19.4H16.5A1.3 1.3 0 0 0 17.8 18.1Z";

// "Updated …" note: a page whose lines scroll up on hover / flourish.
export function DocLinesIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 28 28" aria-hidden="true">
      <path d="M7.6 1.4h8.2v6.8c0 1.5.8 2.3 2.3 2.3h5.5v12.4c0 2.4-1.3 3.7-3.7 3.7H7.6c-2.4 0-3.6-1.3-3.6-3.7V5.1c0-2.4 1.2-3.7 3.6-3.7ZM17.4 1.9v6.2c0 .5.3.8.8.8h5.2c-.2-.5-.5-.9-1-1.4L19 2.9c-.5-.5-1-.9-1.6-1Z" />
      <path
        className="text-orange-75 flourishing:-translate-y-[4.45px] flourishing:opacity-0 flourishing:transition flourishing:duration-300 stroke-current dark:text-stone-900"
        d="M9.2 16.15H18.4"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <path
        className="text-orange-75 flourishing:-translate-y-[4.45px] flourishing:transition flourishing:duration-300 stroke-current dark:text-stone-900"
        d="M9.2 20.6H18.4"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <path
        className="text-orange-75 flourishing:opacity-100 flourishing:transition-all flourishing:delay-75 flourishing:duration-500 flourishing:[stroke-dashoffset:0] stroke-current opacity-0 dark:text-stone-900"
        d="M9.2 20.6H18.4"
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray="10"
        strokeDashoffset="10"
      />
    </svg>
  );
}

const SPARKLES_PATH = sparkle(14.2, 15.4, 8.2) + sparkle(6, 7.6, 4.2) + sparkle(12.6, 3, 2.4);

export function SparklesIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      <path d={SPARKLES_PATH} />
    </svg>
  );
}

export function BugIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      <path
        fillRule="evenodd"
        d="M12 7.6a6.3 7.6 0 1 0 0 15.2 6.3 7.6 0 1 0 0-15.2ZM11.35 9.8h1.3v11.2h-1.3Z"
      />
      <circle cx="12" cy="4.7" r="2.3" />
      <path
        {...stroke}
        strokeWidth="1.7"
        d="M6.6 11.2 3.6 9.3M5.7 15.2H2.6M6.75 19.4l-2.8 2M17.4 11.2l3-1.9M18.3 15.2h3.1M17.25 19.4l2.8 2M10.5 3.1 9.3 1.4M13.5 3.1l1.2-1.7"
      />
    </svg>
  );
}

export const PAPER_PLANE_PATH =
  "M23.42 3.72L4.19 11.76Q2.9 12.3 4.16 12.91L10.96 16.24Q11.5 16.5 11.76 17.04L15.09 23.84Q15.7 25.1 16.24 23.81L24.28 4.58Q24.9 3.1 23.42 3.72ZM22.5 5.5L22.7 5.7L13.5 15.5L12.7 14.7Z";

// Receipt window: filled header band over an open body (the page animates 4 lines inside).
export const RECEIPT_FRAME_PATH =
  "M5.8 3.2h16.4a3.6 3.6 0 0 1 3.6 3.6v14.4a3.6 3.6 0 0 1-3.6 3.6H5.8a3.6 3.6 0 0 1-3.6-3.6V6.8a3.6 3.6 0 0 1 3.6-3.6ZM23.9 10.4a1.8 1.8 0 0 0-1.8-1.8H5.9a1.8 1.8 0 0 0-1.8 1.8v10.6a1.8 1.8 0 0 0 1.8 1.8h16.2a1.8 1.8 0 0 0 1.8-1.8Z";

export function ClockIcon({ className }: P) {
  return (
    <svg className={className} viewBox="0 0 29 28" aria-hidden="true">
      <path d="M14 2a12 12 0 0 1 0 24a12 12 0 0 1 0-24ZM14.9 7.1A0.9 0.9 0 0 0 13.1 7.1V13.1H8.3A0.9 0.9 0 0 0 8.3 14.9H14A0.9 0.9 0 0 0 14.9 14Z" />
    </svg>
  );
}
