import { createStore } from "../../lib/store";
import { fadeVolume, preloadSound, takeSound } from "../../lib/sound";

export type Track = {
  name: string;
  artist: string;
  album_art: string;
  preview_url: string;
  url: string;
  colors: [string, string];
  artPreloaded?: boolean;
};

// Apple Music previews, each linking back to the full track.
const TRACKS: Track[] = [
  {
    name: "Emagination (B - Side)",
    artist: "Miami Horror",
    album_art:
      "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/ee/5e/9b/ee5e9b85-e222-e5a0-15e5-880f5b165932/067003168366.png/168x168bb.jpg",
    preview_url:
      "https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/1d/9e/4c/1d9e4cc0-c3ce-2660-d116-86fb386d5920/mzaf_18139705836037492329.plus.aac.p.m4a",
    url: "https://music.apple.com/us/album/emagination-b-side/1615142779?i=1615143055",
    colors: ["#d39da0", "#6b596a"],
  },
  {
    name: "Shiny Tune",
    artist: "Patrick Holland",
    album_art:
      "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/d7/c5/60/d7c560ee-b05d-75e1-b4ae-039f8deb0f32/69499.jpg/168x168bb.jpg",
    preview_url:
      "https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview116/v4/98/b6/a3/98b6a34d-0d07-6d81-99e5-97383bded724/mzaf_17962729563231555672.plus.aac.p.m4a",
    url: "https://music.apple.com/us/album/shiny-tune/1693032577?i=1693032727",
    colors: ["#7273d6", "#1a203b"],
  },
  {
    name: "Ocean City",
    artist: "Pacific Coliseum",
    album_art:
      "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/3b/ff/18/3bff180a-3204-9657-9bd8-fdcb79a4b9eb/5054526057630_cover.jpg/168x168bb.jpg",
    preview_url:
      "https://audio-ssl.itunes.apple.com/itunes-assets/AudioPreview211/v4/0f/8f/10/0f8f106e-ca35-34eb-f38e-5336242eedca/mzaf_9043965348750221227.plus.aac.p.m4a",
    url: "https://music.apple.com/us/album/ocean-city/1819148323?i=1819148325",
    colors: ["#e27f93", "#4b215c"],
  },
];

/* ---------- Notch command bus: the demo talks to the notch through here ---------- */

export type NotchCommand =
  | {
      kind: "notification";
      state: boolean;
      type: "didConnectAirPods";
      duration?: number;
    }
  | { kind: "live-activity"; state: boolean; type: "isPlaying" | "isLocked" }
  | { kind: "quick-peek"; state: boolean; duration?: number };

let commandId = 0;
export const useNotchBus = createStore<{
  command: (NotchCommand & { id: number }) | null;
}>(() => ({ command: null }));
export const sendToNotch = (c: NotchCommand) =>
  useNotchBus.setState({ command: { ...c, id: ++commandId } });

/* ---------- Clock ---------- */

let tick = 0;
export const useClock = createStore<{ now: Date; start(): void; stop(): void }>(
  (set) => ({
    now: new Date(),
    start() {
      clearInterval(tick);
      tick = window.setInterval(() => set({ now: new Date() }), 1000);
    },
    stop() {
      clearInterval(tick);
    },
  }),
);

/* ---------- Music: previews fade in to 30% volume and out before they end ---------- */

const FADE_MS = 1000;
const PLAY_VOLUME = 0.3;
let audio: HTMLAudioElement | null = null;
let fadeOutTimer = 0;
let cancelFade: (() => void) | null = null;

type Music = {
  index: number;
  tracks: Track[] | null;
  isFlipped: boolean;
  isSoundPlaying: boolean;
  getTracks(): void;
  preloadTrackArt(i?: number): void;
  preloadTrack(i?: number): void;
  preloadNextTrack(): void;
  play(): void;
  startPlayback(): void;
  next(): void;
  toggle(): void;
  scheduleFadeOut(ms: number): void;
  stopCurrentSound(): void;
};

export const currentTrack = (s: Pick<Music, "tracks" | "index">) =>
  s.tracks?.[s.index] ?? null;

export const useMusic = createStore<Music>((set, get) => ({
  index: 0,
  tracks: null,
  isFlipped: false,
  isSoundPlaying: false,
  getTracks() {
    set({ tracks: TRACKS });
  },
  preloadTrackArt(i = get().index) {
    const t = get().tracks?.[i];
    if (!t || t.artPreloaded) return;
    new Image().src = t.album_art;
    t.artPreloaded = true;
  },
  preloadTrack(i = get().index) {
    const t = get().tracks?.[i];
    if (!t) return;
    get().preloadTrackArt(i);
    preloadSound(t.preview_url);
  },
  preloadNextTrack() {
    const { tracks, index } = get();
    if (tracks?.length) get().preloadTrack((index + 1) % tracks.length);
  },
  play() {
    get().preloadTrackArt();
    get().stopCurrentSound();
    const t = currentTrack(get());
    if (!t || !(audio = takeSound(t.preview_url))) return;
    const a = audio;
    get().preloadNextTrack();
    a.preload = "auto";
    a.volume = 0;
    const announce = () =>
      setTimeout(
        () =>
          sendToNotch({
            kind: "live-activity",
            state: true,
            type: "isPlaying",
          }),
        50,
      );
    if (a.readyState >= 3) announce();
    else a.addEventListener("canplay", announce, { once: true });
    a.addEventListener("play", () => {
      set({ isSoundPlaying: true });
      clearTimeout(fadeOutTimer);
      cancelFade?.();
      cancelFade = fadeVolume(a, a.volume, PLAY_VOLUME, FADE_MS);
      get().scheduleFadeOut(FADE_MS);
    });
    a.addEventListener("pause", () => set({ isSoundPlaying: false }));
    a.addEventListener("ended", () => {
      set({ isSoundPlaying: false });
      get().next();
      sendToNotch({ kind: "quick-peek", state: true, duration: 2000 });
      set((s) => ({ isFlipped: !s.isFlipped }));
    });
    get().startPlayback();
  },
  startPlayback() {
    const p = audio?.play();
    if (!p) return set({ isSoundPlaying: !!audio });
    p.then(
      () => set({ isSoundPlaying: true }),
      () => set({ isSoundPlaying: false }),
    );
  },
  next() {
    const { tracks, index } = get();
    set({ index: tracks?.length ? (index + 1) % tracks.length : 0 });
    get().play();
  },
  toggle() {
    clearTimeout(fadeOutTimer);
    if (get().isSoundPlaying) {
      set({ isSoundPlaying: false });
      cancelFade?.();
      cancelFade = null;
      audio?.pause();
    } else {
      get().startPlayback();
      sendToNotch({ kind: "quick-peek", state: true, duration: 2000 });
    }
  },
  scheduleFadeOut(ms) {
    const a = audio;
    if (!a) return;
    if (!Number.isFinite(a.duration)) {
      a.addEventListener("loadedmetadata", () => get().scheduleFadeOut(ms), {
        once: true,
      });
      return;
    }
    fadeOutTimer = window.setTimeout(
      () => {
        cancelFade?.();
        cancelFade = fadeVolume(a, PLAY_VOLUME, 0, ms);
      },
      Math.max(0, (a.duration - a.currentTime) * 1000 - ms),
    );
  },
  stopCurrentSound() {
    clearTimeout(fadeOutTimer);
    cancelFade?.();
    cancelFade = null;
    set({ isSoundPlaying: false });
    if (audio) {
      audio.pause();
      audio.src = "";
      audio.load();
    }
  },
}));
