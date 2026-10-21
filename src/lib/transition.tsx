import {
  Children,
  cloneElement,
  isValidElement,
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type ReactElement,
  type ReactNode,
  type Ref,
} from "react";
import { cn } from "./cn";
import { mergeRefs, nextFrame, transitionMs } from "./frame";

type Phase = "idle" | "from" | "active" | "done";
type Child = ReactElement<{
  className?: string;
  style?: CSSProperties;
  ref?: Ref<HTMLElement>;
}>;
type Frozen = { key: string; el: Child };

const tokens = (s = "") => s.split(/\s+/).filter(Boolean);
const without = (base = "", drop = "") => {
  const d = new Set(tokens(drop));
  return tokens(base)
    .filter((t) => !d.has(t))
    .join(" ");
};

// enterFrom tokens are stripped from the child's own className once entering
// starts, so markup can ship pre-hidden (e.g. "opacity-0") and reveal itself.
function classFor(
  base: string | undefined,
  phase: Phase,
  from: string,
  active: string,
) {
  if (phase === "from") return cn(base, from);
  if (phase === "active") return cn(without(base, from), active);
  if (phase === "done") return without(base, from);
  return base ?? "";
}

export type TransitionProps = {
  children?: ReactNode;
  show?: boolean;
  appear?: boolean;
  css?: boolean;
  mode?: "default" | "out-in";
  enterFrom?: string;
  enterActive?: string;
  leaveActive?: string;
  leaveTo?: string;
  onEnter?: (el: HTMLElement, done: () => void) => void;
  onLeave?: (el: HTMLElement, done: () => void) => void;
};

/**
 * Class-driven enter/leave for a single keyed child. Changing the child's key
 * plays the old element's leave while the new one enters ("out-in" waits).
 */
export function Transition({
  children,
  show = true,
  appear = false,
  css = true,
  mode = "default",
  enterFrom = "",
  enterActive = "",
  leaveActive = "",
  leaveTo = "",
  onEnter,
  onLeave,
}: TransitionProps) {
  const child = show
    ? ((Children.toArray(children).find(isValidElement) as Child | undefined) ??
      null)
    : null;
  const key = child ? String(child.key ?? "#") : null;

  const [cur, setCur] = useState(() => ({
    key,
    phase: (key !== null && appear ? "from" : "idle") as Phase,
    n: 0,
  }));
  const [leaving, setLeaving] = useState<Frozen[]>([]);
  const node = useRef<HTMLElement | null>(null);
  const last = useRef<Frozen | null>(null);
  const rendered = useRef<Frozen | null>(null);
  const cancels = useRef(new Map<string, () => void>());
  const gen = useRef(0);
  const opts = useRef({ css, leaveActive, leaveTo, onEnter, onLeave });
  opts.current = { css, leaveActive, leaveTo, onEnter, onLeave };

  const setNode = useCallback((el: HTMLElement | null) => {
    if (!el) return;
    node.current = el;
    return () => {
      if (node.current === el) node.current = null;
    };
  }, []);
  const childRef = child?.props.ref;
  const ref = useMemo(() => mergeRefs(setNode, childRef), [setNode, childRef]);

  const leave = (f: Frozen, el: HTMLElement | null, after: () => void) => {
    const { css, leaveActive, leaveTo, onLeave } = opts.current;
    let done = false;
    let timer = 0;
    const finish = () => {
      if (done) return;
      done = true;
      cancels.current.delete(f.key);
      setLeaving((l) => l.filter((x) => x !== f));
      after();
    };
    cancels.current.set(f.key, () => {
      done = true;
      clearTimeout(timer);
      el?.classList.remove(...tokens(leaveActive), ...tokens(leaveTo));
    });
    setLeaving((l) => [...l.filter((x) => x.key !== f.key), f]);
    if (!el) return finish();
    if (!css) return onLeave ? onLeave(el, finish) : finish();
    el.classList.add(...tokens(leaveActive));
    void el.offsetHeight;
    nextFrame(() => {
      if (done) return;
      el.classList.add(...tokens(leaveTo));
      timer = window.setTimeout(finish, transitionMs(el));
    });
  };

  // Key changed: retire the old element, bring in the new one.
  useLayoutEffect(() => {
    if (key === cur.key) return;
    const g = ++gen.current;
    const prev = cur.key !== null ? last.current : null;
    if (key !== null && cancels.current.has(key)) {
      cancels.current.get(key)!();
      cancels.current.delete(key);
      setLeaving((l) => l.filter((x) => x.key !== key));
    }
    const enter = () =>
      setCur((c) => ({
        key,
        phase: key !== null ? "from" : "idle",
        n: c.n + 1,
      }));
    // Queue the swap before leaving: a node-less leave finishes synchronously.
    if (mode === "out-in" && prev)
      setCur((c) => ({ ...c, key: null, phase: "idle" }));
    else enter();
    if (prev)
      leave(
        prev,
        node.current,
        () => mode === "out-in" && g === gen.current && enter(),
      );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  // Enter choreography: from → (paint) → active → (transition end) → done.
  useLayoutEffect(() => {
    const el = node.current;
    if (cur.phase === "from") {
      if (!el) return setCur((c) => ({ ...c, phase: "done" }));
      if (!opts.current.css) {
        setCur((c) => ({ ...c, phase: "done" }));
        opts.current.onEnter?.(el, () => {});
        return;
      }
      void el.offsetHeight;
      let cancelled = false;
      const n = cur.n;
      nextFrame(
        () =>
          !cancelled &&
          setCur((c) =>
            c.n === n && c.phase === "from" ? { ...c, phase: "active" } : c,
          ),
      );
      return () => {
        cancelled = true;
      };
    }
    if (cur.phase === "active" && el) {
      const n = cur.n;
      const t = window.setTimeout(
        () =>
          setCur((c) =>
            c.n === n && c.phase === "active" ? { ...c, phase: "done" } : c,
          ),
        transitionMs(el),
      );
      return () => clearTimeout(t);
    }
  }, [cur.phase, cur.n]);

  // Remember what was committed, so a later key change can freeze it.
  useLayoutEffect(() => {
    last.current = rendered.current;
  });

  const out: ReactNode[] = [];
  const currentKey = cur.key === key ? key : cur.key;
  for (const f of leaving) if (f.key !== currentKey) out.push(f.el);

  rendered.current = null;
  if (child && cur.key === key) {
    const className = css
      ? classFor(child.props.className, cur.phase, enterFrom, enterActive)
      : child.props.className;
    const style =
      css && cur.phase === "from"
        ? { ...child.props.style, transitionProperty: "none" }
        : child.props.style;
    const el = cloneElement(child, { key, className, style, ref }) as Child;
    rendered.current = { key: key!, el };
    out.push(el);
  } else if (cur.key !== null && last.current?.key === cur.key) {
    // Key just changed; keep the old node mounted until the effect retires it.
    rendered.current = last.current;
    out.push(last.current.el);
  }
  return <>{out}</>;
}
