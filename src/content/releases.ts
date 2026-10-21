// Metadata the site shows for the downloadable build (trial vs. licensed channel).
// Both channels serve public/downloads/Isola.dmg (mac/scripts/build.sh); update size_bytes when it changes.
export type Release = {
  version: string;
  build: number;
  published_at: string;
  assets: { name: string; size_bytes: number }[];
  minimum_system_version: string;
};

export const RELEASES: Record<"trial" | "stable", Release> = {
  trial: {
    version: "1.4.7",
    build: 151,
    published_at: "2026-10-09T16:12:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 4_968_307 }],
    minimum_system_version: "15",
  },
  stable: {
    version: "1.4.7",
    build: 151,
    published_at: "2026-10-09T16:12:00.000Z",
    assets: [{ name: "Isola.dmg", size_bytes: 4_968_307 }],
    minimum_system_version: "15 Sequoia",
  },
};
