import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";
import { RELEASES, type Release } from "./src/content/releases";

const BRAND = "Isola";
const SITE = "https://isola-ruby.vercel.app";

// Static copies of index.html with per-route <title>/OG tags, for crawlers and link previews.
const PAGES = [
  { file: "faqs", title: "FAQs", description: "Frequently asked questions" },
  {
    file: "changelog",
    title: "Changelog",
    description: `See what’s new in ${BRAND}`,
  },
  {
    file: "download",
    title: "Download for Mac",
    description: `Download ${BRAND} for Mac`,
  },
  {
    file: "privacy",
    title: "Privacy policy",
    description: `What ${BRAND} keeps for your license, and why`,
  },
  {
    file: "recover",
    title: "Recover your license",
    description: "Recover your license",
    noindex: true,
  },
];

function routeMeta(): Plugin {
  return {
    name: "route-meta",
    apply: "build",
    closeBundle() {
      const dist = resolve(__dirname, "dist");
      const html = readFileSync(resolve(dist, "index.html"), "utf8");
      for (const p of PAGES) {
        const title = `${BRAND} — ${p.title}`;
        const out = html
          .replace(/<title>.*?<\/title>/, `<title>${title}</title>`)
          .replace(/(name="description" content=")[^"]*/, `$1${p.description}`)
          .replace(/(property="og:title" content=")[^"]*/, `$1${title}`)
          .replace(/(name="twitter:title" content=")[^"]*/, `$1${title}`)
          .replace(
            /(property="og:description" content=")[^"]*/,
            `$1${p.description}`,
          )
          .replace(
            /(name="twitter:description" content=")[^"]*/,
            `$1${p.description}`,
          )
          .replace(/\/images\/meta\.png/g, `/images/meta-${p.file}.png`)
          .replace(
            "</title>",
            p.noindex
              ? '</title>\n    <meta name="robots" content="noindex, nofollow" />'
              : "</title>",
          );
        writeFileSync(resolve(dist, `${p.file}.html`), out);
      }
      // Update feed the Mac app polls once a day, in the shape Updates.Feed decodes (mac/Sources/Isola/
      // Modules/Settings/License.swift): the stable release at the top level, Early bird's under "beta".
      // Fields a release doesn't have stay out (JSON.stringify drops undefined).
      const entry = ({ assets: _, zip, ...release }: Release) => ({
        ...release,
        url: `${SITE}/download`,
        zip: zip ? new URL(zip, SITE).href : undefined,
      });
      const feed = {
        ...entry(RELEASES.stable),
        beta: RELEASES.beta && entry(RELEASES.beta),
      };
      writeFileSync(
        resolve(dist, "releases.json"),
        JSON.stringify(feed, null, 2),
      );
    },
  };
}

export default defineConfig({
  plugins: [react(), tailwindcss(), routeMeta()],
});
