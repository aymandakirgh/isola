import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

const BRAND = "Isola";

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
    description: "No data or personal information is collected",
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
    },
  };
}

export default defineConfig({
  plugins: [react(), tailwindcss(), routeMeta()],
});
