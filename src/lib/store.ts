import { useSyncExternalStore } from "react";

type Setter<T> = (partial: Partial<T> | ((s: T) => Partial<T>)) => void;

/** Minimal zustand-style store: `useStore(selector)` plus `getState/setState`. */
export function createStore<T extends object>(init: (set: Setter<T>, get: () => T) => T) {
  const subs = new Set<() => void>();
  let state: T;
  const get = () => state;
  const set: Setter<T> = (partial) => {
    const next = typeof partial === "function" ? partial(state) : partial;
    state = { ...state, ...next };
    subs.forEach((fn) => fn());
  };
  state = init(set, get);
  const subscribe = (fn: () => void) => (subs.add(fn), () => subs.delete(fn));
  function useStore(): T;
  function useStore<U>(select: (s: T) => U): U;
  function useStore<U>(select?: (s: T) => U) {
    const pick = () => (select ? select(state) : state);
    return useSyncExternalStore(subscribe, pick, pick);
  }
  return Object.assign(useStore, { getState: get, setState: set, subscribe });
}
