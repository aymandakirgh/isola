// Release notes, newest first (same shape as a changelog API response).
import { BRAND } from "../config";

export type Minor = {
  version: string;
  date: string;
  note: string | null;
  features: string[];
  fixes: string[];
};
export type Entry = {
  version: string;
  description: string;
  video?: string;
  minors: Minor[];
};

export const CHANGELOG: { updated: string; entries: Entry[] } = {
  updated: "October 2026",
  entries: [
    {
      version: "1.4",
      description:
        "Stacked live activities, a compact mode for external displays, battery and charging HUDs, and a rebuilt settings window.",
      minors: [
        {
          version: "1.4.8",
          date: "22 Oct 2026",
          note: "From this version on, updates install themselves.",
          features: [
            "Added colour styles, a title badge and custom controls to Now Playing",
            "Added a right-click menu to the island",
            "Added a look per HUD, with progress styles and the output device",
            "Added calendar peeks, time left, a month view and an hourly chime",
            "Added warning levels and allowed Focus modes to notifications",
            "Added a Frosted lock screen card and Sunrise & Sunset weather",
          ],
          fixes: [
            "Fixed swipe up dismissing activities with dismissing turned off",
            "Fixed HUDs showing an empty wing without a percentage",
            "Fixed the calendar agenda running into the blur",
            "Fixed swiped-away tracks coming back from their player",
            "Fixed sunrise and sunset in other time zones",
          ],
        },
        {
          version: "1.4.7",
          date: "9 Oct 2026",
          note: null,
          features: [
            "Added a battery percentage option to the compact view",
            "Added a subtle haptic tick when the island snaps open",
          ],
          fixes: [
            "Fixed the island flickering when the Mac wakes from sleep",
            "Fixed artwork not refreshing for some podcast apps",
            "Smoothed the spring when stacked activities collapse",
            "Reduced CPU use while music is paused",
            "Fixed timer activities drifting during long sessions",
          ],
        },
        {
          version: "1.4.6",
          date: "2 Oct 2026",
          note: "Trial builds now ship from the same channel as releases.",
          features: [
            "Added per-app rules to hide the island in full-screen apps",
          ],
          fixes: [
            "Fixed the calendar activity showing yesterday’s events",
            "Improved charging HUD accuracy on MacBook Air",
            "Fixed a crash when unplugging an external display",
            "Polished German and Japanese translations",
          ],
        },
        {
          version: "1.4.5",
          date: "24 Sep 2026",
          note: null,
          features: [],
          fixes: [
            "Fixed stacked activities overlapping the menu bar on 13-inch displays",
            "Improved swipe detection with Magic Mouse",
            "Fixed the volume HUD appearing twice with media keys",
            "Smoother animations on 60 Hz displays",
          ],
        },
        {
          version: "1.4.4",
          date: "15 Sep 2026",
          note: "Running the macOS 27 beta? Please update to beta 4 or later first.",
          features: ["Added early support for macOS 27"],
          fixes: [
            "Fixed the island not appearing right after login",
            "Fixed notification previews cutting emoji in half",
            "Lowered memory use of the artwork cache",
          ],
        },
        {
          version: "1.4.3",
          date: "2 Sep 2026",
          note: null,
          features: [
            "Added a quick Do Not Disturb toggle",
            "Added a keyboard shortcut to expand the island",
          ],
          fixes: [
            "Fixed the brightness HUD on Studio Display",
            "Fixed a rare freeze when switching Spaces",
            "Improved battery HUD colors in light mode",
          ],
        },
        {
          version: "1.4.2",
          date: "18 Aug 2026",
          note: null,
          features: [],
          fixes: [
            "Fixed compact mode clipping long titles",
            "Fixed timers resetting after an update",
            "Faster startup",
          ],
        },
        {
          version: "1.4.1",
          date: "4 Aug 2026",
          note: null,
          features: [
            "Added an option to keep the island expanded while music plays",
          ],
          fixes: [
            "Fixed the settings window opening behind other apps",
            "Fixed stacked activities ignoring the chosen order",
            "Clearer VoiceOver labels throughout settings",
          ],
        },
        {
          version: "1.4.0",
          date: "21 Jul 2026",
          note: "A big one — thank you to everyone who tested the betas!",
          features: [
            "Added stacked live activities",
            "Added compact mode for external displays",
            "Added battery and charging HUDs",
            "Rebuilt the settings window from scratch",
          ],
          fixes: [
            "Faster animations across the board",
            "Fixed the island misaligning on notchless displays",
          ],
        },
      ],
    },
    {
      version: "1.3",
      description:
        "Lock Screen widgets for music, weather, focus and battery — plus per-display layouts and smarter notification grouping.",
      minors: [
        {
          version: "1.3.8",
          date: "30 Jun 2026",
          note: null,
          features: [],
          fixes: [
            "Fixed the weather widget using Fahrenheit in some Celsius regions",
            "Faster focus widget refresh",
          ],
        },
        {
          version: "1.3.7",
          date: "12 Jun 2026",
          note: null,
          features: [
            "Added an option to show seconds on the Lock Screen clock",
          ],
          fixes: [
            "Fixed widgets drifting on ultrawide displays",
            "Improved artwork blur performance",
          ],
        },
        {
          version: "1.3.6",
          date: "27 May 2026",
          note: "Widgets now remember their layout on every display.",
          features: ["Added per-display widget layouts"],
          fixes: [
            "Fixed the battery widget showing on desktop Macs",
            "Fixed a crash when no weather location is set",
          ],
        },
        {
          version: "1.3.5",
          date: "8 May 2026",
          note: null,
          features: [],
          fixes: [
            "Better notification grouping for Messages",
            "Fixed music widget controls not responding after sleep",
            "Fewer wakeups while the Lock Screen is visible",
          ],
        },
        {
          version: "1.3.4",
          date: "21 Apr 2026",
          note: null,
          features: ["Added a calendar widget"],
          fixes: [
            "Fixed widget fonts on non-English systems",
            "Improved contrast over bright wallpapers",
          ],
        },
        {
          version: "1.3.3",
          date: "2 Apr 2026",
          note: null,
          features: [],
          fixes: [
            "Fixed duplicate notifications when using Focus filters",
            "Smoother scrolling in the widget gallery",
          ],
        },
        {
          version: "1.3.2",
          date: "16 Mar 2026",
          note: null,
          features: ["Added smarter notification grouping"],
          fixes: [
            "Fixed weather icons at night",
            "Fixed a layout glitch on the 14-inch MacBook Pro",
          ],
        },
        {
          version: "1.3.1",
          date: "24 Feb 2026",
          note: null,
          features: [],
          fixes: [
            "Fixed widgets missing on first launch",
            "Softer Lock Screen fade timing",
          ],
        },
        {
          version: "1.3.0",
          date: "9 Feb 2026",
          note: "Lock Screen widgets are here.",
          features: [
            "Added Lock Screen widgets for music, weather, focus and battery",
            "Added a widget gallery",
          ],
          fixes: ["Improved notification timing"],
        },
      ],
    },
    {
      version: "1.2",
      description:
        "Timer and calendar live activities, gesture shortcuts, custom HUD styles, and big performance gains on Intel Macs.",
      minors: [
        {
          version: "1.2.7",
          date: "19 Jan 2026",
          note: null,
          features: [],
          fixes: [
            "Fixed timers losing their label after a restart",
            "Gentler default gesture sensitivity",
          ],
        },
        {
          version: "1.2.6",
          date: "2 Dec 2025",
          note: null,
          features: ["Added a Pomodoro preset for timers"],
          fixes: ["Fixed the calendar activity including declined events"],
        },
        {
          version: "1.2.5",
          date: "10 Nov 2025",
          note: "Intel Macs got a lot of love in this one.",
          features: [],
          fixes: [
            "Halved GPU usage on Intel Macs",
            "Fixed a stutter when expanding with large artwork",
            "Lower idle energy impact",
          ],
        },
        {
          version: "1.2.4",
          date: "22 Oct 2025",
          note: null,
          features: ["Added a two-finger swipe to skip tracks"],
          fixes: ["Fixed swipe gestures firing inside full-screen games"],
        },
        {
          version: "1.2.3",
          date: "30 Sep 2025",
          note: null,
          features: [],
          fixes: [
            "Fixed HUD styles resetting after updates",
            "Improved the brightness HUD on external monitors",
            "Fixed a crash when opening settings twice",
          ],
        },
        {
          version: "1.2.2",
          date: "4 Sep 2025",
          note: null,
          features: ["Added outline and glass HUD styles"],
          fixes: ["Fixed time zones in the calendar activity"],
        },
        {
          version: "1.2.1",
          date: "6 Aug 2025",
          note: null,
          features: [],
          fixes: [
            "Fixed timers staying silent when the Mac is muted",
            "Clearer onboarding text",
          ],
        },
        {
          version: "1.2.0",
          date: "14 Jul 2025",
          note: null,
          features: [
            "Added timer and calendar live activities",
            "Added gesture shortcuts",
            "Added custom HUD styles",
          ],
          fixes: ["Overall performance improvements"],
        },
      ],
    },
    {
      version: "1.1",
      description:
        "Media controls for any player, a volume and brightness HUD, and the first round of customization.",
      minors: [
        {
          version: "1.1.2",
          date: "18 Mar 2025",
          note: null,
          features: [],
          fixes: [
            "Fixed the volume HUD showing on the wrong display",
            "Better artwork color sampling",
          ],
        },
        {
          version: "1.1.1",
          date: "11 Feb 2025",
          note: null,
          features: ["Added support for more media players"],
          fixes: [
            "Fixed playback controls for browser players",
            "Fixed launch at login",
          ],
        },
        {
          version: "1.1.0",
          date: "20 Jan 2025",
          note: "Thanks for all the feedback on 1.0!",
          features: [
            "Added media controls for any player",
            "Added a volume and brightness HUD",
            "Added the first customization options",
          ],
          fixes: [],
        },
      ],
    },
    {
      version: "1.0",
      description:
        `The very first public release of ${BRAND} — a Dynamic Island for your Mac.`,
      minors: [
        {
          version: "1.0.2",
          date: "10 Dec 2024",
          note: null,
          features: [],
          fixes: [
            "Fixed the island drawing over full-screen video",
            "Better multi-display support",
          ],
        },
        {
          version: "1.0.1",
          date: "29 Nov 2024",
          note: null,
          features: [],
          fixes: [
            "Fixed a crash on launch for some users",
            "More reliable notch detection",
          ],
        },
        {
          version: "1.0.0",
          date: "25 Nov 2024",
          note: "Hello, world.",
          features: ["Initial release"],
          fixes: [],
        },
      ],
    },
  ],
};
