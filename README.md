# Isola

A 1:1 recreation of the [tryalcove.com](https://tryalcove.com) marketing site — same layout, motion and interactions — under an original, fictional brand ("Isola"), with original artwork, icons, sounds and copy.

```sh
npm install
npm run dev          # http://localhost:5173
npm run build        # dist/ (+ per-route HTML for link previews)
BASE_URL=http://localhost:4173 npm run test:e2e   # after `npm run preview`
```

## What's in it

- **Interactive Mac demo** (`src/pages/home`): lock screen with rolling-digit clock, click-to-unlock (sound), menu bar + dock with tooltips, and a spring-driven Dynamic Island (`Notch.tsx`) that cycles lock → earbuds connected → now playing (Apple Music previews, fade in/out, track flip), quick-peek marquee on album-art hover and play/pause on the equaliser.
- **Pages**: FAQs and Changelog (dark theme), Download, Privacy, license Recover (loading / shake / success), Purchased (`/purchased/demo`).
- **Choreography**: class-driven `Transition` (`src/lib/transition.tsx`), page leave/enter with theme swap, header buttons that pop in/out and FLIP into place, Figma-style squircle clipping (`src/lib/squircle.ts`).

## Placeholders

Brand, price, links and contact live in `src/config.ts`. The licensing backend is mocked in `src/lib/api.ts`; release metadata is in `src/content/releases.ts` (update `size_bytes` when the DMG changes).

## Isola for Mac (`mac/`)

The app the site sells, rebuilt natively in SwiftUI: a Dynamic Island in the notch (a floating pill on notchless displays) with live activities, quick peek, swipes, HUDs, Lock Screen widgets, onboarding, settings and a trial licence. Universal (Apple silicon + Intel), macOS 15+. Feature-by-feature coverage of the reference changelog: [mac/FEATURES.md](mac/FEATURES.md).

```sh
cd mac
scripts/build.sh                 # build/Isola.app + build/Isola.dmg (ad-hoc signed)
open build/Isola.app
build/isolactl state             # drive or inspect the running app (Sources/Isola/Support/Debug.swift)
scripts/tour.sh build/tour       # screenshot every island state on the live screen
build/Isola.app/Contents/MacOS/Isola --gallery /tmp/isola-gallery   # offscreen renders
```

`public/downloads/Isola.dmg` is this build. It is signed ad hoc, not notarized: the first launch needs System Settings → Privacy & Security → Open Anyway (the DMG includes a note).

Now Playing on macOS 15.4+: MediaRemote only answers Apple-signed processes, so `Helpers/MediaRemoteHelper.m` is loaded into `/usr/bin/perl` and streams JSON to the app; Music/Spotify AppleScript is the fallback.
