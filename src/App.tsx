import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MouseEvent,
  type PointerEvent,
} from "react";
import { Layout } from "./components/Layout";
import { nextFrame, wait } from "./lib/frame";
import {
  loadedPage,
  loadPage,
  matchRoute,
  PageTransitionContext,
  RouterContext,
  type Location,
  type PagePhase,
} from "./lib/router";
import { resolve, routes } from "./routes";

const html = document.documentElement;
const isDark = (path: string) => !!matchRoute(routes, path)?.route.dark;

function setMeta(path: string) {
  const { route } = resolve(path);
  document.title = route.title;
  document
    .querySelector('meta[name="description"]')
    ?.setAttribute("content", route.description ?? "");
}

// Hover styles are muted until the pointer moves again after a navigation.
function suppressHover() {
  html.classList.add("suppress-hover");
  const release = () => {
    html.classList.remove("suppress-hover");
    window.removeEventListener("pointermove", release);
    window.removeEventListener("pointerdown", release);
  };
  window.addEventListener("pointermove", release);
  window.addEventListener("pointerdown", release);
}

export function App() {
  const [location, setLocation] = useState<Location>(() => ({
    pathname: window.location.pathname,
    search: window.location.search,
  }));
  const [navPath, setNavPath] = useState(location.pathname);
  const [dark, setDark] = useState(() => isDark(location.pathname));
  const [leaving, setLeaving] = useState(false);
  const [phase, setPhase] = useState<PagePhase>("idle");
  const current = useRef(location);
  current.current = location;
  const ticket = useRef(0);

  const applyDark = useCallback((on: boolean) => {
    setDark(on);
    html.classList.toggle("dark", on);
  }, []);

  const navigate = useCallback(
    async (href: string, push = true) => {
      const url = new URL(href, window.location.href);
      const { route, pathname } = resolve(url.pathname);
      url.pathname = pathname;
      if (
        url.pathname === current.current.pathname &&
        url.search === current.current.search
      )
        return;
      const t = ++ticket.current;
      const toDark = !!route.dark;
      setNavPath(url.pathname);
      if (toDark !== html.classList.contains("dark")) {
        html.classList.add("theme-swap");
        setTimeout(() => html.classList.remove("theme-swap"), 1300);
      }
      suppressHover();
      setLeaving(true);
      setPhase("leaving");
      await Promise.all([wait(300), loadPage(route)]);
      if (t !== ticket.current) return;
      window.scrollTo(0, 0);
      applyDark(toDark);
      setPhase("enter-from");
      if (push)
        history.pushState(null, "", url.pathname + url.search + url.hash);
      setLocation({ pathname: url.pathname, search: url.search });
      setMeta(url.pathname);
    },
    [applyDark],
  );

  const begin = useCallback(() => {
    nextFrame(() => {
      setPhase("enter-active");
      setTimeout(() => {
        setPhase("idle");
        setLeaving(false);
      }, 300);
    });
  }, []);

  useEffect(() => {
    history.scrollRestoration = "manual";
    html.classList.toggle("dark", isDark(current.current.pathname));
    const onPop = () => navigate(window.location.href, false);
    window.addEventListener("popstate", onPop);
    // Warm every route once the browser is idle.
    const warm = () => routes.forEach((r) => loadPage(r));
    const idle =
      "requestIdleCallback" in window
        ? requestIdleCallback(warm, { timeout: 2500 })
        : setTimeout(warm, 1200);
    return () => {
      window.removeEventListener("popstate", onPop);
      if ("cancelIdleCallback" in window) cancelIdleCallback(idle as number);
      clearTimeout(idle as number);
    };
  }, [navigate]);

  // Same-origin anchors navigate in-app (with the leave animation).
  const onClick = (e: MouseEvent) => {
    const a = (e.target as Element).closest?.("a");
    if (
      !a ||
      a.origin !== window.location.origin ||
      a.target ||
      a.hasAttribute("download")
    )
      return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    if (a.pathname === location.pathname) {
      if (!a.hash) e.preventDefault();
      return;
    }
    e.preventDefault();
    navigate(a.pathname + a.search + a.hash);
  };
  const onPointerOver = (e: PointerEvent) => {
    const a = (e.target as Element).closest?.("a");
    if (
      a &&
      a.origin === window.location.origin &&
      !a.target &&
      !a.hasAttribute("download")
    )
      loadPage(resolve(a.pathname).route);
  };

  const { route, params } = resolve(location.pathname);
  const Page = loadedPage(route);
  const search = useMemo(
    () => new URLSearchParams(location.search),
    [location.search],
  );
  const router = useMemo(() => ({ location, navigate }), [location, navigate]);
  const transition = useMemo(() => ({ phase, begin }), [phase, begin]);

  return (
    <RouterContext value={router}>
      <Layout
        path={navPath}
        dark={dark}
        leaving={leaving}
        onClick={onClick}
        onPointerOver={onPointerOver}
      >
        <PageTransitionContext value={transition}>
          {Page ? (
            <Page key={location.pathname} params={params} search={search} />
          ) : null}
        </PageTransitionContext>
      </Layout>
    </RouterContext>
  );
}
