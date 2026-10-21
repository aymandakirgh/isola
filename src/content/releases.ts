// Metadata the site shows for the downloadable build (trial vs. licensed channel).
export type Release = {
  version: string;
  build: number;
  published_at: string;
  assets: { name: string; size_bytes: number }[];
  minimum_system_version: string;
};

export const RELEASES: Record<"trial" | "stable", Release> = {
  trial: {
    version: "1.4.6",
    build: 148,
    published_at: "2026-10-02T09:40:00.000Z",
    assets: [
      { name: "Isola.zip", size_bytes: 14_204_117 },
      { name: "Isola.dmg", size_bytes: 14_961_532 },
    ],
    minimum_system_version: "15",
  },
  stable: {
    version: "1.4.7",
    build: 151,
    published_at: "2026-10-09T16:12:00.000Z",
    assets: [
      { name: "Isola.zip", size_bytes: 14_388_920 },
      { name: "Isola.dmg", size_bytes: 15_140_276 },
    ],
    minimum_system_version: "15 Sequoia",
  },
};
