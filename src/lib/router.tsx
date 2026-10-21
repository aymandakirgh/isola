import {
  createContext,
  useContext,
  useLayoutEffect,
  useRef,
  type ComponentType,
} from "react";

export type PageProps = {
  params: Record<string, string>;
  search: URLSearchParams;
};

export type RouteDef = {
  path: string;
  load: () => Promise<{ default: ComponentType<PageProps> }>;
  title: string;
  description?: string;
  dark?: boolean;
};

const segments = (p: string) => p.split("/").filter(Boolean);
const decode = (s: string) => {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
};

export function matchRoute(routes: RouteDef[], pathname: string) {
  const parts = segments(pathname);
  for (const route of routes) {
    const pattern = segments(route.path);
    if (pattern.length !== parts.length) continue;
    const params: Record<string, string> = {};
    const ok = pattern.every((p, i) =>
      p.startsWith(":") ? ((params[p.slice(1)] = decode(parts[i])), true) : p === parts[i],
    );
    if (ok) return { route, params };
  }
  return null;
}

const loaded = new Map<RouteDef, ComponentType<PageProps>>();
export const loadedPage = (route: RouteDef) => loaded.get(route);
export async function loadPage(route: RouteDef) {
  if (!loaded.has(route)) loaded.set(route, (await route.load()).default);
  return loaded.get(route)!;
}

export type Location = { pathname: string; search: string };
export const RouterContext = createContext<{
  location: Location;
  navigate: (href: string) => void;
}>({
  location: { pathname: "/", search: "" },
  navigate: () => {},
});
export const useRouter = () => useContext(RouterContext);

// Page entrance/exit choreography shared by every route.
export type PagePhase = "idle" | "leaving" | "enter-from" | "enter-active";
const PHASE_CLASS: Record<PagePhase, string> = {
  idle: "",
  leaving: "transition duration-300 -translate-y-3 opacity-0",
  "enter-from": "opacity-0",
  "enter-active": "transition duration-300",
};
export const PageTransitionContext = createContext<{
  phase: PagePhase;
  begin: () => void;
}>({
  phase: "idle",
  begin: () => {},
});

/** Class for a page's root element; kicks off the enter phase on mount. */
export function usePageTransition() {
  const { phase, begin } = useContext(PageTransitionContext);
  const entering = useRef(phase === "enter-from");
  useLayoutEffect(() => {
    if (entering.current) begin();
  }, [begin]);
  return PHASE_CLASS[phase];
}
