import { createRoot } from "react-dom/client";
import "./app.css";
import { App } from "./App";
import { loadPage } from "./lib/router";
import { resolve } from "./routes";

const { route, pathname } = resolve(window.location.pathname);
if (pathname !== window.location.pathname) history.replaceState(null, "", pathname + window.location.search);
document.title = route.title;

loadPage(route).then(() => createRoot(document.getElementById("app")!).render(<App />));
