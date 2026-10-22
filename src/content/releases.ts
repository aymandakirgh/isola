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
    version: "1.4.10",
    build: 154,
    published_at: "2026-10-22T13:45:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 5_987_037 }],
    minimum_system_version: "15",
  },
  stable: {
    version: "1.4.10",
    build: 154,
    published_at: "2026-10-22T13:45:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 5_987_037 }],
    minimum_system_version: "15 Sequoia",
    notes: "Dia joins the browsers Isola can script.",
    changes: {
      features: [
        "Dia: copy the playing video’s link, and Show in Browser brings its tab forward",
      ],
    },
    zip: "/downloads/Isola-1.4.10.zip",
    sha256: "59c2813176e12b5a2c423bb2b60937a434d57d39a53451adbee25f35b0299176",
    signature: "Iaau7PqR7Mt6RPNZsHd4Kv3i+akY/aKl3E3HhpGzfokpCWfnga48wHSJvrLZsT9CuUU8WPg8H9ss4uU9Ty7gCw==",
  },
};
