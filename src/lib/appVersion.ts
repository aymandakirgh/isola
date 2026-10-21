import { RELEASES, type Release } from "../content/releases";
import { useRouter } from "./router";

const MACOS_NAMES = new Map([
  ["14", "Sonoma"],
  ["15", "Sequoia"],
  ["26", "Tahoe"],
]);

/** "15" → "15 Sequoia", "15.4" → "15.4 Sequoia". */
export function formatMinimumSystem(v: string) {
  const [, major, minor = "0"] = v.match(/^(\d+)(?:\.(\d+))?/) ?? [];
  if (!major) return v;
  const version = Number(minor) > 0 ? `${major}.${Number(minor)}` : major;
  const name = MACOS_NAMES.get(version) ?? MACOS_NAMES.get(major);
  return name ? `${version} ${name}` : version;
}

function format(r: Release, asset = "isola.dmg") {
  const file =
    r.assets.find((a) => a.name.toLowerCase() === asset) ?? r.assets.find((a) => a.name.endsWith(".dmg"));
  return {
    appVersion: r.version.replace(/^v/i, ""),
    appSize: file ? String(Math.floor(file.size_bytes / 1e6)) : "",
    appMinimumSystemVersion: formatMinimumSystem(r.minimum_system_version),
  };
}

/** Buyers (/purchased/*) get the licensed channel, everyone else the trial build. */
export function useAppVersion() {
  const { location } = useRouter();
  return format(RELEASES[location.pathname.startsWith("/purchased") ? "stable" : "trial"]);
}
