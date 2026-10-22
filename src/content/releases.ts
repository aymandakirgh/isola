// Metadata the site shows for the downloadable build (trial vs. licensed channel), and the Mac app's
// update feed: vite.config.ts publishes `stable` (and `beta`, for Early bird) as /releases.json.
// Both channels serve public/downloads/Isola.dmg (mac/scripts/build.sh); update size_bytes when it changes.
export type Release = {
  version: string;
  build: number;
  published_at: string;
  assets: { name: string; size_bytes: number }[];
  minimum_system_version: string;
  /** The update window's text above the changes. */
  notes?: string;
  /** The update window's New Features, Bug Fixes and Important. */
  changes?: { features?: string[]; fixes?: string[]; important?: string[] };
  /** Where the app sends people when it can't update in place: /download unless set. That page serves the
   * stable DMG, so a beta brings its own (its zip, or a page of its own). */
  url?: string;
  /** Update Now… in place, from mac/build/release.json (`scripts/build.sh release`): the zip's path on
   * this site (it ships with the release), its SHA-256 and Ed25519 signature. Without all three the app
   * opens `url` instead. */
  zip?: string;
  sha256?: string;
  signature?: string;
};

export const RELEASES: {
  trial: Release;
  stable: Release;
  beta?: Release & { url: string };
} = {
  trial: {
    version: "1.4.8",
    build: 152,
    published_at: "2026-10-22T09:24:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 5_986_240 }],
    minimum_system_version: "15",
  },
  stable: {
    version: "1.4.8",
    build: 152,
    published_at: "2026-10-22T09:24:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 5_986_240 }],
    minimum_system_version: "15 Sequoia",
    notes: "Settings for every part of the island, a right-click menu, and updates that install themselves.",
    changes: {
      features: [
        "Now Playing: colour styles, a title badge, your own left and right controls, and a peek when the track changes",
        "Right-click or Control-click the island for the menu of whatever it’s showing",
        "A look per HUD, with progress styles, percentage, speed and the output device",
        "Calendar: a peek before events, time left, a month view and an hourly chime",
        "Battery, device and Focus notifications with their own warning levels and allowed modes",
        "Lock screen: a Frosted card and Sunrise & Sunset weather",
        "Updates now install in place, checked against Isola’s signature",
      ],
      fixes: [
        "Swiping up no longer dismisses an activity when dismissing is turned off",
        "HUDs always show their level, as a percentage unless you turn it off",
        "The calendar shows two events when they fit and never runs into the blur",
        "A track you swiped away stays away when you switch back to its player",
        "Sunrise and sunset use the time zone of the place in the forecast",
      ],
    },
    zip: "/downloads/Isola-1.4.8.zip",
    sha256: "eb808597b0b0a2ef9e6b57b4ff95783fe1a1d8b569ea82665465cc2beac71d91",
    signature: "fOqUJzR0vIzVazWFQ+Cjnta1EVcDC0wViWMZtNlp4Ha10Tav26/GIbw/8QH+m46dYMoFcOHdkNuvQzFtzFZ7Aw==",
  },
};
