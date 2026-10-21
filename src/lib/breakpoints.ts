import { useEffect, useState } from "react";

const BREAKPOINTS = { sm: 640, md: 768, lg: 1024, xl: 1280, "2xl": 1536 } as const;
type Breakpoint = keyof typeof BREAKPOINTS;

function useMedia(query: string) {
  const [matches, setMatches] = useState(() => matchMedia(query).matches);
  useEffect(() => {
    const mq = matchMedia(query);
    const update = () => setMatches(mq.matches);
    update();
    mq.addEventListener("change", update);
    return () => mq.removeEventListener("change", update);
  }, [query]);
  return matches;
}

export const useMinWidth = (bp: Breakpoint) => useMedia(`(min-width: ${BREAKPOINTS[bp]}px)`);
export const useMaxWidth = (bp: Breakpoint) => useMedia(`(max-width: ${BREAKPOINTS[bp]}px)`);
