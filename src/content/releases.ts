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
    version: "1.4.9",
    build: 153,
    published_at: "2026-10-22T13:20:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 5_987_194 }],
    minimum_system_version: "15",
  },
  stable: {
    version: "1.4.9",
    build: 153,
    published_at: "2026-10-22T13:20:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 5_987_194 }],
    minimum_system_version: "15 Sequoia",
    notes: "Isola is now open source. Send Feedback opens a GitHub issue with your versions filled in.",
    changes: {
      features: [
        "Send Feedback… opens a new issue on GitHub, with your Isola and macOS versions filled in",
      ],
      fixes: [
        "The time to leave notification has its event’s right-click menu and Option-click",
      ],
    },
    zip: "/downloads/Isola-1.4.9.zip",
    sha256: "4c8b13b5a0bd96ad8326251d3301af8525e4be04e76838c88d4c3967794e159e",
    signature: "v2K46sQF1FLhCi0owbvPy+yxBrzeiuOtQJ/mj8XHo++7V5XrGcgDqFwnw9w0wXtv/pZGTO9wtH6/TT6lIGzOAA==",
  },
};
