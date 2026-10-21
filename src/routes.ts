import { BRAND, TAGLINE } from "./config";
import { matchRoute, type RouteDef } from "./lib/router";

export const routes: RouteDef[] = [
  { path: "/", load: () => import("./pages/home/Home"), title: `${BRAND} — Dynamic Island for your Mac`, description: TAGLINE },
  { path: "/faqs", load: () => import("./pages/Faqs"), title: `${BRAND} — FAQs`, description: "Frequently asked questions", dark: true },
  {
    path: "/changelog",
    load: () => import("./pages/Changelog"),
    title: `${BRAND} — Changelog`,
    description: `See what’s new in ${BRAND}`,
    dark: true,
  },
  { path: "/download", load: () => import("./pages/Download"), title: `${BRAND} — Download for Mac`, description: `Download ${BRAND} for Mac` },
  {
    path: "/privacy",
    load: () => import("./pages/Privacy"),
    title: `${BRAND} — Privacy policy`,
    description: "No data or personal information is collected",
    dark: true,
  },
  { path: "/recover", load: () => import("./pages/Recover"), title: `${BRAND} — Recover your license`, description: "Recover your license" },
  { path: "/purchased/:id", load: () => import("./pages/Purchased"), title: `${BRAND} — Thanks for your purchase!` },
];

/** Unknown paths fall back to the home page (the URL is rewritten to "/"). */
export function resolve(pathname: string) {
  const hit = matchRoute(routes, pathname);
  return hit ? { ...hit, pathname } : { route: routes[0], params: {}, pathname: "/" };
}
