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

Brand, price, links and contact live in `src/config.ts`. The licensing backend is mocked in `src/lib/api.ts`; release metadata is in `src/content/releases.ts`; the DMG in `public/downloads` only contains a README.
