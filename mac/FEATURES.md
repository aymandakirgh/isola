# Isola for Mac — feature coverage

Every line of the reference app's public changelog (165 items, versions 1.0–1.7), checked against this codebase. Statuses come from reading the code, not from the UI copy:

- **Done**: works against the real system and is reachable by a user (default behaviour or a setting that is read).
- **Built, unverified**: implemented against the real APIs, but not exercised on the test Mac because it needs a permission, an app or hardware that machine does not have.
- **Partial**: implemented, but narrower than the changelog line; the note says what is missing.
- **Simulated**: the UI exists but is driven only by `isolactl` / `--gallery` (no real data source on this build).
- **Missing**: not implemented. **Blocked**: needs something this project can't have (Apple entitlements or notarization, a third-party account, hardware).
- **N/A**: a line about the reference product's own history rather than a capability.

**165 items:** ✅ Done 133 · 🔶 Built, unverified 26 · 🟡 Partial 3 · 🧪 Simulated 1 · ⛔ Blocked 2

**Seen live:** 56 of them were exercised on the test Mac (✓ column), with real system data or with simulated input through the same code path (`isolactl`). The rest were checked by reading the code and by the offscreen `--gallery` self-checks.

Evidence paths are relative to `mac/`. Live checks were run on a MacBook Pro (M1 Pro, clamshell, one 2560×1440 display, macOS 27) with `isolactl` and `scripts/tour.sh`; permission-gated paths (system audio capture, location, Bluetooth, calendars) were not triggered on that shared machine.

## 1.7

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 1 | Added extended support for AirPlay | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:452` | AirPlay outputs show their glyph, name and volume. The route picker moved from the top row into the volume row. |
| 2 | Added speed control for Spotify podcasts | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/MediaViews.swift:403; SpotifyWeb.swift:75` | The Web API has no playback-speed endpoint. The existing MediaRemote speed command is unchanged and still untested with Spotify. |
| 3 | Added AutoMix support | 🔶 Built, unverified |  | `Helpers/MediaRemoteHelper.m:99` | The helper reads MediaRemote's IsInTransition and shows an AutoMix tag; needs Apple Music AutoMix playback to see it, none on the test Mac. |
| 4 | Muted native focus banner (macOS 27+) | ⛔ Blocked |  |  | macOS 27 draws it in Control Center's SystemBannerService, anchored to the Focus menu-bar item; no switch exists (only CenterSystemBanners, which moves it). |
| 5 | Muted native connectivity banner (macOS 27+) | ⛔ Blocked |  |  | Same service, anchored to the Bluetooth menu-bar item; hiding it would need a private Control Center API or hiding that menu-bar item. |
| 6 | Added Spotify like | 🔶 Built, unverified | ✓ | `Sources/Isola/Modules/Media/SpotifyWeb.swift:362; NowPlayingSources.swift:169` | Heart saves/removes via PUT/DELETE /me/library; saved state from /me/library/contains each poll; updates at once, reverts with a one-line notice on failure. |
| 7 | Added Spotify explicit tag | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/SpotifyWeb.swift:30,47; MediaViews.swift:580` | The item's explicit flag from GET /me/player drives the existing E badge (gallery shot media-expanded-spotify). |
| 8 | Added Spotify repeat one | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/SpotifyWeb.swift:39,376; NowPlayingSources.swift:255` | Cycles off→context→track via PUT /me/player/repeat; state read from /me/player; a 403 (Premium) shows one line, then uses the app's own repeat. |
| 9 | Added colored outline support | ✅ Done | ✓ | `Sources/Isola/Island/IslandView.swift:181` | Drawn just inside the animated island shape. Media uses the artwork colours, everything else a neutral grey. |
| 10 | Added compact outline support | ✅ Done | ✓ | `Sources/Isola/Island/IslandView.swift:183` | 0.5 pt hairline that fades out as the panel expands. |
| 11 | Added contrast outline (macOS 26+) | ✅ Done | ✓ | `Sources/Isola/Island/IslandView.swift:185` | Brighter white edge on all macOS versions; no glass edge, since glass can't be checked offscreen. |
| 12 | Added specific focus option for waveform replace | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:657` | Focus picker: Any Focus or one mode. Custom modes only appear once seen, which needs Full Disk Access. |
| 13 | Added live waveform (0-1% Total CPU) | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/AudioLevels.swift:20` | Core Audio process tap → 4 biquad bands at 30 Hz, opt-in; DSP self-checked, live tap needs System Audio Recording permission. |
| 14 | Added repeat 1 support for Apple Music | ✅ Done |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:214,289,335-343; Sources/Isola/Modules/Media/MediaViews.swift:372` | Both MediaRemote and Music's AppleScript report repeat-one. The button cycles off→all→one and shows the repeat.1 icon. |
| 15 | Added calendar event indicators | ✅ Done | ✓ | `Sources/Isola/Modules/Calendar/CalendarSource.swift:81` | A week-strip dot on every day an event covers; an event ending at midnight stays on its day. |
| 16 | Added replace waveform with focus mode | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:223` | Trailing wing blur-replaces into the Focus symbol tinted in the mode's colour. FocusState gained `tint` (Focus.swift:50). |
| 17 | Added show notch on all displays option | ✅ Done |  | `Sources/Isola/Support/Preferences.swift:23; Sources/Isola/Island/IslandWindows.swift:91` | "Show on all displays" puts an island on every screen. Screens without a notch get the pill or a simulated notch. |
| 18 | Added hide while gaming option | ✅ Done |  | `Sources/Isola/Support/Fullscreen.swift:38,43-46` | Hides when the front app is fullscreen and declares itself a game. Windowed or unlabelled games are missed. Redundant while "hide in fullscreen" is on. |
| 19 | Added lunar year support to calendar | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarViews.swift:258,352-353,545-570; calendar.lunar` | Chinese lunar day labels and a 丙午年 year header. Leap months aren't marked; the labels replace the event dots. |
| 20 | Added simulated notch toggle | ✅ Done | ✓ | `Sources/Isola/Island/Geometry.swift:20; simulatedNotch (Sources/Isola/Modules/Settings/SettingsWindow.swift:175)` | On screens without a notch, docks the island flush to the top edge, shaped like a notch. |
| 21 | Added duo mode | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:44` | Bubble (IslandView.swift:221) shows the other activity's glyph; click swaps (IslandWindows.swift:62,165). Clicking it is untested live. |
| 22 | Added pill shape for notchless displays | ✅ Done | ✓ | `Sources/Isola/Island/Geometry.swift:19-20; Sources/Isola/Island/Island.swift:194` | Default on screens without a notch: a floating rounded pill 6 pt below the edge. Hidden when idle unless a setting is on. |
| 23 | Added audio formats (Lossless/Dolby Atmos) | 🔶 Built, unverified |  | `Helpers/MediaRemoteHelper.m:73` | Reads the playing item's audio format and shows Lossless / Dolby Atmos tags; no source on the test Mac publishes a format. |
| 24 | Added new AirPods Max support | ✅ Done | ✓ | `Sources/Isola/Modules/System/Bluetooth.swift:189-191` | AirPods Max (Lightning, USB-C, Max 2) by product ID, airpods.max symbol, works even when renamed. |
| 25 | Added calendar onboarding | ✅ Done |  | `Sources/Isola/Modules/Settings/Onboarding.swift:65-70,92-93; Sources/Isola/Modules/Settings/SettingsModule.swift:15` | The first-launch permissions step has a Calendar row that asks for access. Events may not appear until the calendar data reloads. |
| 26 | Added accessibility onboarding | ✅ Done |  | `Sources/Isola/Modules/Settings/Onboarding.swift:63-64,88-91` | The Accessibility row opens the system prompt. The row doesn't update after granting, and the HUD takeover setting stays off. |

## 1.6

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 27 | Added explicit tag support | ✅ Done |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:215; Helpers/MediaRemoteHelper.m:33; Sources/Isola/Modules/Media/MediaViews.swift:345` | Reads MediaRemote's explicit flag, which exists on this macOS. The "E" badge appears in the expanded player only. |
| 28 | Added middle click to cycle | ✅ Done |  | `Sources/Isola/Island/IslandWindows.swift:159-160` | Middle-clicking the island switches to the next activity. Needs two or more running activities. |
| 29 | Added progressive blur | ✅ Done |  | `Sources/Isola/Support/IslandUI.swift:139` | Blurred copy under gradient masks at the panel's bottom edge (IslandView.swift:136) and marquee edges. At-rest panels unchanged. |
| 30 | Added MacBook Neo support | ✅ Done |  | `Sources/Isola/Island/Geometry.swift:15-17` | Generic: notch size comes from the screen's reported notch area, with no per-model table. Untested on that hardware. |
| 31 | Added display symbol for brightness HUD | ✅ Done |  | `Sources/Isola/Modules/Modules/HUD/HUDViews.swift:22; hud.displaySymbol` | A display icon replaces the sun. The brightness HUD only appears with "Replace HUD" on and Accessibility granted. |
| 32 | Added ctrl + brightness support (alternating) | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDControls.swift:147-151,208` | Control+brightness adjusts the next display whose brightness macOS can change. Needs "Replace HUD" and Accessibility. |
| 33 | Added support for Studio Display XDR | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDControls.swift:117-151` | Uses the same system brightness API for any Apple display. No model-specific code; untested on XDR hardware. |
| 34 | Added disable weather on empty day option | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarViews.swift:277,512; weather.emptyDay` | The setting is read; turning it off removes the weather from the empty-day view. |
| 35 | Added weather condition to empty day | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarViews.swift:404-421; Sources/Isola/Modules/Calendar/Weather.swift:56-70` | Shows condition, temperature and rain chance from Open-Meteo on empty days. Needs a city set or location permission. |
| 36 | Added disable overshoot option | ✅ Done |  | `Sources/Isola/Island/Springs.swift:10; overshoot` | Turning it off removes the bounce from every island animation. The toggle is in both Island and HUD settings. |
| 37 | Added hide in Mission Control | ✅ Done |  | `Sources/Isola/Support/Fullscreen.swift:12,33-35,39` | Detects Mission Control from full-screen Dock windows, checked once a second, so hiding can lag up to a second. |
| 38 | Added HUD overshoot | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDModule.swift:256; Sources/Isola/Modules/HUD/HUDViews.swift:16` | Rubber band past 0% or 100%, only with Overshoot on. Needs key-tap mode: macOS sends nothing when the level can't move. |
| 39 | Added calendar display options | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarViews.swift:465-498` | All of these are read: declined, subscribed, calendar colours, all-day split, lunar, open-with app, and per-calendar toggles. |
| 40 | Added swipe down to cycle expanded activity | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:73` | Swipe down while expanded cycles by priority; collapses if the next item has no expanded view (verified live). |
| 41 | Added Notion Calendar support | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarSource.swift:103-107; calendar.openWith` | Notion Calendar (com.cron.electron) can be chosen as the app that today's date opens. Opens the app only, not a specific event. |
| 42 | Added active fullscreen display detection | 🔶 Built, unverified |  | `Sources/Isola/Support/Fullscreen.swift:28` | Per-display hiding; frame matching self-checked, not tried with a real fullscreen app on the shared Mac. |
| 43 | Added initial BetterDisplay volume support | 🔶 Built, unverified | ✓ | `Sources/Isola/Modules/HUD/HUDControls.swift:167` | Listens to BetterDisplay's documented OSD notifications; exercised live with a synthetic notification, BetterDisplay itself not installed. |
| 44 | Added BetterDisplay support | 🔶 Built, unverified | ✓ | `Sources/Isola/Modules/HUD/HUDControls.swift:183` | Brightness HUD for BetterDisplay-controlled monitors; exercised with a synthetic OSD notification only. |
| 45 | Added Fantastical support to calendar | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarSource.swift:103-107; calendar.openWith` | Fantastical (com.flexibits.fantastical2.mac) can be chosen for the today's-date click. Opens the app only, not a specific event. |
| 46 | Added 3rd party calendar open support | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarSource.swift:102-108; Sources/Isola/Modules/Calendar/CalendarViews.swift:471-475` | The picker lists whichever of Calendar, Fantastical and Notion Calendar are installed, and falls back to Calendar.app. |
| 47 | Added restore dismissed calendar events | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarViews.swift:26-31,303-305,476-479; calendar.dismissed` | Swipe up dismisses an event. "Restore N" in the expanded calendar and in Settings brings them back. |
| 48 | Added split days calendar event support | ✅ Done | ✓ | `Sources/Isola/Modules/Calendar/CalendarSource.swift:227; Sources/Isola/Modules/Calendar/CalendarViews.swift:582` | Rows and all-day chips say "Day 2 of 3 · from 22:00 / until 07:10"; in-progress handling below. |
| 49 | Added HomePod support | 🔶 Built, unverified |  | `Sources/Isola/Modules/HUD/HUDModule.swift:84` | HomePod recognised by name or CoreAudio model (AudioAccessoryN,N) for AirPlay outputs; no HomePod on the test Mac. |
| 50 | Added AirPods Max Red support | 🔶 Built, unverified |  | `Sources/Isola/Modules/System/Bluetooth.swift:236` | Code 0x02, labelled "Red" for AirPods Max in Flipper's table, tints rose. Likely the gen-1 Pink finish; no hardware to confirm. |
| 51 | Added AirPods Pro 3 support | ✅ Done | ✓ | `Sources/Isola/Modules/System/Bluetooth.swift:187-188` | AirPods Pro 3 (0x2027/0x2028); this macOS has no Pro 3 symbol, so it uses airpods.pro. |
| 52 | Added copy link support to YouTube Music | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:624` | YouTube Music tab URL via the browser's AppleScript, only with Automation consent; not run on the test Mac. |
| 53 | Restored HUD mute functionality | ✅ Done | ✓ | `Sources/Isola/Modules/HUD/HUDModule.swift:209-214; Sources/Isola/Modules/HUD/HUDControls.swift:93; Sources/Isola/Modules/HUD/HUDViews.swift:27-28` | The mute key toggles mute, and mute changes from elsewhere are caught too. The HUD shows a crossed-out speaker and "Muted". |
| 54 | Added click on todays date to open calendar | ✅ Done |  | `Sources/Isola/Modules/Calendar/CalendarViews.swift:325-326` | Today's cell in the week strip is a button that opens the chosen calendar app. |
| 55 | Added expanded calendar | ✅ Done | ✓ | `Sources/Isola/Modules/Calendar/CalendarViews.swift:227-309,25,51,71` | Month, week strip, agenda, weather and timers. Reachable only with an upcoming event, a running timer, or the idle-date setting on. |
| 56 | Added swipe to dismiss QuickPeek | ✅ Done |  | `Sources/Isola/Island/IslandWindows.swift:166; Sources/Isola/Island/Island.swift:157` | Swipe up hides the quick peek; swipe direction now follows the fingers under natural scrolling (self-checked). |
| 57 | Added idle activity option | ✅ Done |  | `calendar.idleActivity; Sources/Isola/Modules/Calendar/CalendarModule.swift:72-74; Sources/Isola/Modules/Calendar/CalendarViews.swift:62-72` | Opt-in low-priority date activity showing next-event countdown or temperature. |

## 1.5

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 58 | Added opt click support to alternate between activity actions | ✅ Done | ✓ | `Sources/Isola/Modules/System/Power.swift:172; Sources/Isola/Modules/System/Focus.swift:182` | Option-click on charging switches between time to full and "46% · 96 W adapter"; on Focus it opens Focus settings. |
| 59 | Reworked Alcove to fully match Tahoe style | ✅ Done | ✓ | `Sources/Isola/Modules/Settings/SettingsWindow.swift:176; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:364` | Built with the macOS 27 SDK: Settings and widgets take the Tahoe design, plus Liquid Glass on custom surfaces; seen live on macOS 27. |
| 60 | Added multiple live activity support | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:10,24-31,73-76; Sources/Isola/Island/IslandWindows.swift:159-160` | Priority-sorted activity list; swipe down while expanded or middle click cycles. |
| 61 | Added Dia browser support | 🟡 Partial |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:536` | Dia is activated only: as of mid-2025 it had no AppleScript dictionary. Not installed here to recheck. |
| 62 | Added sleep focus sound option | 🔶 Built, unverified |  | `Sources/Isola/Modules/System/Focus.swift:57` | Soft sound when Sleep turns on (off by default); telling Sleep apart needs Full Disk Access. |
| 63 | Added show on screensaver option | ✅ Done |  | `lockscreen.showOnScreensaver; Sources/Isola/Modules/LockScreen/LockScreenModule.swift:15-16,59-62` | Screensaver start/stop distributed notifications present widgets on the SkyLight lock space. |
| 64 | Added time to empty for battery widget | ✅ Done |  | `Sources/Isola/Modules/System/Power.swift:54; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:412-414` | IOKit kIOPSTimeToEmptyKey shown as "Xh Ym left" while discharging. |
| 65 | Added now playing widget offset | ✅ Done |  | `lockscreen.nowPlayingOffset; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:471` | ±120 pt slider moves the card vertically. |
| 66 | Added now playing widget styles | ✅ Done |  | `lockscreen.nowPlayingStyle; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:339-362` | Glass, Dark and Artwork (blurred cover) backgrounds. |
| 67 | Added clear artwork option | ✅ Done | ✓ | `Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:381; Sources/Isola/Modules/LockScreen/LockScreenPreferences.swift:16` | New "Clear" style: no card or rim; artwork, text and controls float on a soft shadow. |
| 68 | Added show declined events option | ✅ Done |  | `calendar.showDeclined; Sources/Isola/Modules/Calendar/CalendarSource.swift:54,115-117` | Filters on the current user's EventKit participant status. |
| 69 | Added calendar list toggle | ✅ Done |  | `calendar.excludedCalendars; Sources/Isola/Modules/Calendar/CalendarViews.swift:481-497; Sources/Isola/Modules/Calendar/CalendarSource.swift:50-52` | Per-calendar toggles in settings filter the EventKit query. |
| 70 | Added grayscale album art option | ✅ Done |  | `Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:250` | Media's grayscale option greys the card's artwork and the Artwork style's blurred backdrop. |
| 71 | Added calendar color option | ✅ Done | ✓ | `Sources/Isola/Modules/Calendar/CalendarViews.swift:86; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:459` | Activity dot, peek and Lock Screen calendar widget follow the toggle; settings section renamed "Display". |

## 1.4

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 72 | Added time to leave notifications | 🔶 Built, unverified |  | `Sources/Isola/Modules/Calendar/TravelTime.swift:48` | Apple Maps ETA from the current location when location access is already granted; else fixed minutes. Leave UI seen live. |
| 73 | Added exclude subscribed calendars option | ✅ Done |  | `calendar.excludeSubscribed; Sources/Isola/Modules/Calendar/CalendarSource.swift:51` | Drops calendars of EKCalendarType .subscription before querying. |
| 74 | Added calendar live activity | ✅ Done | ✓ | `calendar.liveActivity, calendar.leadMinutes; Sources/Isola/Modules/Calendar/CalendarSource.swift:66-84` | Next EventKit event becomes a countdown activity with peek and expanded calendar. |
| 75 | Added rain condition details to precipitation | ✅ Done | ✓ | `Sources/Isola/Modules/Calendar/Weather.swift:79` | "Rain at 18:00 · 60%", "Snow from 07:00 · 80%", "Showers now"; empty-day view and Lock Screen detailed weather. |
| 76 | Added mic symbol to podcasts and live quick peek | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:253` | Peek shows the mic for com.apple.podcasts as well as live streams. |

## 1.3

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 77 | Added calendar widget | ✅ Done | ✓ | `lockscreen.showCalendar; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:430-436; Sources/Isola/Support/SharedState.swift:115` | Next timed EventKit event with colour dot and relative time. |
| 78 | Added ability to toggle slider total duration | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:331` | Clicking the trailing time switches time left ⇄ total. Saved in media.showTotalTime; also a settings toggle. |
| 79 | Added start of localization with focus widget | ✅ Done |  | `Sources/Isola/Modules/System/Focus.swift:190` | it/de/fr/es table using Apple's own wording from macOS string tables; self-check covers each language. |
| 80 | Added notch width fine tuning | ✅ Done |  | `widthTweak; Sources/Isola/Island/Geometry.swift:16,20; Sources/Isola/Modules/Settings/SettingsWindow.swift:185` | ±40 pt width slider applied to hardware and simulated notch. |
| 81 | Added visible mute to volume control | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:472` | Mute toggle in the volume row. When muted, the speaker is slashed there and on the output button, and the bar dims. |
| 82 | Added connectivity widget | ✅ Done | ✓ | `lockscreen.showConnectivity; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:417-429` | Connected Bluetooth devices with battery rings from IOBluetooth/system_profiler. |
| 83 | Added battery widget | ✅ Done | ✓ | `lockscreen.showBattery; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:409-416; Sources/Isola/Modules/System/Power.swift:39-58` | IOKit internal battery level and charging state. |
| 84 | Added weather widget style | ✅ Done | ✓ | `lockscreen.weatherStyle; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:401-406` | Compact (temperature) or detailed (condition plus rain chance). |
| 85 | Added keep awake to Lock Screen | ✅ Done |  | `lockscreen.keepAwake; Sources/Isola/Modules/LockScreen/LockScreenModule.swift:62,125-135` | PreventUserIdleDisplaySleep IOPM assertion while locked. |
| 86 | Added output volume controls | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:472` | Output button reveals a draggable volume slider for the default output (HUD's SystemAudio). HUD stays quiet meanwhile (quietUntil). |
| 87 | Added option to show volume control on widget | ✅ Done | ✓ | `lockscreen.showVolumeControl; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:493` | Adds a draggable output-volume row (VirtualMainVolume) to the Lock Screen card. |
| 88 | Added option to retain volume control on collapse | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:612` | "Keep volume control open" keeps the volume row across collapse/expand (media.keepVolumeOpen). |
| 89 | Added exclude inapt sources option | ✅ Done |  | `media.excludeInapt; Sources/Isola/Modules/Media/MediaModule.swift:52-61` | Ignores FaceTime, Messages, Zoom, Teams, Slack, Discord, Voice Memos by bundle ID. |
| 90 | Added playback speed | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:267-296; Sources/Isola/Modules/Media/NowPlayingSources.swift:116-126; Helpers/MediaRemoteHelper.m:72-73` | 0.5–2× menu sends MediaRemote changePlaybackRate; no-op for AppleScript sources. |
| 91 | Added AirPods Pro 3 to supported outputs | ✅ Done |  | `Sources/Isola/Modules/System/Bluetooth.swift:187` | AirPods Pro 3 recognised by product ID (renamed too) in notifications, HUD and player outputs; seen live with a simulated device. |
| 92 | Added EarPods as supported output device | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:447` | EarPods, AirPods/Pro/Max, Beats, HomePod and HDMI glyph + name come from HUDOutput. Covered by the self-check. |
| 93 | Added option to disable in fullscreen | 🔶 Built, unverified |  | `Sources/Isola/Support/Fullscreen.swift:59` | Accepts the full frame or the frame minus the notch inset (self-checked); no notched display on the test Mac. |
| 94 | Added option to hide now playing widget instantly | ✅ Done |  | `lockscreen.hideInstantly; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:149-154` | Skips the 10 s grace period when hiding an inactive card. |
| 95 | Added option to silence update prompt | ✅ Done | ✓ | `Sources/Isola/Modules/Settings/License.swift:199,257,266,360` | Daily check of releases.json, island notification, "Silence update prompt". Feed not published yet, so "Couldn't check" for now. |
| 96 | Added option to hide note symbol | ✅ Done |  | `media.hideNoteSymbol; Sources/Isola/Modules/Media/MediaViews.swift:134` | Hides the ♪/mic glyph in the quick-peek marquee. |
| 97 | Added Apple displays as supported outputs | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDModule.swift:74` | Outputs whose name contains "display" (Studio Display, UltraFine) get the display glyph, in the player and the HUD. |
| 98 | Added weather widget | ✅ Done | ✓ | `lockscreen.showWeather, weather.city; Sources/Isola/Modules/Calendar/Weather.swift:25-33,56-70; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:398-408` | Open-Meteo current conditions; needs a city or location set in settings. |
| 99 | Added low power mode notification | ✅ Done | ✓ | `system.lowPowerNotification; Sources/Isola/Modules/System/Power.swift:33-36,92-96` | NSProcessInfoPowerStateDidChange posts an On/Off island notification. |
| 100 | Added hide while inactive option to now playing widget | ✅ Done |  | `lockscreen.hideWhileInactive; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:149-154` | Hides the card 10 s after playback stops. |
| 101 | Added lock screen widgets | ✅ Done | ✓ | `lockscreen.enabled; Sources/Isola/Modules/LockScreen/LockScreenModule.swift:49-73; Sources/Isola/Modules/LockScreen/SkyLight.swift:35-59` | Private SkyLight space at level 400 on screenIsLocked; reports unavailable if symbols vanish. |
| 102 | Added now playing widget | ✅ Done | ✓ | `lockscreen.showNowPlaying; Sources/Isola/Modules/LockScreen/LockScreenWidgets.swift:218-363,481-497` | Live track, progress/seek and transport controls wired to the real media commands. |
| 103 | Added focus widget | 🔶 Built, unverified |  | `Sources/Isola/Modules/Settings/Onboarding.swift:95` | Focus Status + Full Disk Access rows with live status; not granted on the shared test Mac. |

## 1.2

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 104 | Added artwork glare effect | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:29` | Glare on wing and player artwork, follows the pointer via a tracking area, on by default. Pointer-follow not run live. |
| 105 | Added show in browser menu option | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:204` | Brings the playing tab to the front when Automation is granted; otherwise activates the app. |
| 106 | Added copy link support for YouTube | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:536` | YouTube tab picked by host + title (self-checked); browser scripts not run without consent. |
| 107 | Added ability to remove other devices | 🧪 Simulated |  | `Sources/Isola/Modules/Settings/License.swift:96` | Deactivate works; other Macs only via the gallery: licensing is a local mock (no payment or licence server). |
| 108 | Improved device recognition support | ✅ Done |  | `Sources/Isola/Modules/System/Bluetooth.swift:137,265; Sources/Isola/Modules/HUD/HUDControls.swift:65` | 33-model table (AirPods + 17 Beats) from AppleDB, matched to system_profiler. The HUD uses it too. |
| 109 | Restored system media support | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaRemoteBridge.swift:22-56; Helpers/MediaRemoteHelper.m:78-101; Sources/Isola/Modules/Media/NowPlayingSources.swift:64-68` | Perl-hosted MediaRemote helper restores system-wide now playing on macOS 15.4+ (private API). |
| 110 | Added copy link functionality | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:179` | Copy link for Apple Music (store id), Spotify and browsers; AppleScript paths compiled, not run without consent. |
| 111 | Added Spotify podcast support | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/SpotifyWeb.swift:28,49; SharedState.swift:38-40; NowPlayingSources.swift:467` | Spotify episode → podcast: show/episode names, mic glyph, ±15/30 s skips, episode link. The AppleScript path flags episodes too. |
| 112 | Added additional AirPods Max colors | 🟡 Partial |  | `Sources/Isola/Modules/System/Bluetooth.swift:234` | Gen-1 codes 0x00/0x02/0x03/0x0F/0x11 tinted. USB-C AirPods Max colours (Midnight, Starlight, Blue, Purple, Orange): no source names their codes, untinted. |
| 113 | Added spectrogram style options | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:136` | Bars/Mirrored/Dots/Wave share one Shape for canned and live bands. Gallery media-style-*; self-check checks bounds. |
| 114 | Added swipe down while expanded | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:160` | Swipe down while expanded cycles to the next live activity (middle click does the same). |
| 115 | Added iCloud settings synchronization option | ✅ Done | ✓ | `Sources/Isola/Support/SettingsSync.swift:90; Sources/Isola/Modules/Settings/SettingsWindow.swift:195` | Settings sync through <iCloud Drive>/Isola/Settings.plist, per-key newest-wins; verified live with a local folder (write, merge, exclusions, placeholders). |
| 116 | Added lock sound option | ✅ Done |  | `Sources/Isola/Modules/System/Lock.swift:27; lockSound` | Fires on real screenIsLocked; reuses unlock.wav at 0.6 volume, no distinct lock sound; off by default. |
| 117 | Added disable expand while inactive option | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:198` | Island › Interaction toggle, default on; blocks tap, hover and swipe expand. Media counts as inactive while paused. |
| 118 | Changed alerts to use system sounds instead | ✅ Done |  | `Sources/Isola/Support/Sounds.swift:17-22` | Battery, device and timer alerts use system Funk/Glass via NSSound(named:). |
| 119 | Added speed options for HUDs (smooth/fast/instant) | ✅ Done |  | `Sources/Isola/Island/Springs.swift:7-12; speed` | Smooth/fast/instant picker on the HUD page, but it applies to the whole island, not HUDs only. |
| 120 | Added ability to disable sync for HUDs | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDModule.swift:36,206; Sources/Isola/Modules/HUD/HUDViews.swift:124` | "Show the HUD for changes made elsewhere", on by default. Disabled unless "Replace the macOS HUD" is on. |
| 121 | Added battery support for AirPods Max | ✅ Done |  | `Sources/Isola/Modules/System/Bluetooth.swift:142-150` | Private IOBluetooth battery keys plus system_profiler fallback cover single-cell AirPods Max. |
| 122 | Added Bluetooth step to onboarding | ✅ Done |  | `Sources/Isola/Modules/Settings/Onboarding.swift:94-96` | Bluetooth is a row on the permissions step (CBCentralManager prompt), not its own step. |
| 123 | Added glow option to display HUD | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDViews.swift:24-25; hud.glow` | Amber glow on the brightness HUD; that HUD needs the Replace-HUD toggle plus Accessibility. |
| 124 | Added decibel option to sound HUD | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDControls.swift:44-50; hud.style` | Uses the device's scalar-to-dB property, falling back to an approximated curve. |
| 125 | Added swipe to skip while expanded | ✅ Done |  | `Sources/Isola/Modules/Media/MediaModule.swift:145-152` | Media onSwipe skips next/previous on horizontal swipes in any state, including expanded. |
| 126 | Added menu bar items (controls) | ✅ Done |  | `Sources/Isola/Modules/Settings/SettingsModule.swift:42` | Status menu adds Previous Track, Shuffle ✓ and Repeat One/All ✓, routed through NowPlayingState.shared.commands. |
| 127 | Added low battery sound | ✅ Done |  | `Sources/Isola/Modules/System/Power.swift:76-81; system.lowBatterySound` | IOKit power-source events; Funk plays at the chosen threshold and again at 10%. |
| 128 | Added low battery sound for connectivity | ✅ Done |  | `Sources/Isola/Modules/System/Bluetooth.swift:85; system.deviceLowBatterySound` | Funk on device low battery; only runs if BluetoothMonitor started (connect notifications on at launch). |
| 129 | Added sound previews | ✅ Done |  | `Sources/Isola/Modules/System/SystemSettings.swift:28,46,58; Sources/Isola/Support/Preferences.swift:48-49` | Turning any of the five sound settings on plays its sound once, on both settings pages. |
| 130 | Added device overview to license tab | 🟡 Partial |  | `Sources/Isola/Modules/Settings/License.swift:204` | Device overview lists this Mac only; a multi-Mac overview needs a real licence server. |
| 131 | Added hide from screen capture option | ✅ Done |  | `Sources/Isola/Island/IslandWindows.swift:46-48; hideFromScreenCapture` | Island panels get sharingType = .none; newer ScreenCaptureKit captures may ignore it. |
| 132 | Improved fullscreen logic (no longer beta) | 🔶 Built, unverified |  | `Sources/Isola/Support/Fullscreen.swift:44` | One hidden flag per display; Mission Control hiding was seen live, fullscreen apps were not tried. |
| 133 | Added swipe to dismiss live activity gesture | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:112` | Hidden until a start/update with a new contentKey, or it ends. Timer and Focus have no key yet. |
| 134 | Added gradient progress bar option | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:306` | "Gradient progress bar" uses the artwork colours, darker at the start and brighter at the playhead. |
| 135 | Added sound on unlock | ✅ Done |  | `Sources/Isola/Modules/System/Lock.swift:34; unlockSound` | Bundled unlock.wav on com.apple.screenIsUnlocked; on by default. |
| 136 | Added album art opacity on pause | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:74,339; media.dimOnPause` | Artwork dims to 60% (wing) / 70% (expanded) while paused; toggle in Media settings. |
| 137 | Improved logic to restore live activity on collapse | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:189` | After cycling while expanded and then collapsing, the most important activity returns 0.4 s later. |
| 138 | Changed natural movement to only affect skip swipe | ✅ Done |  | `Sources/Isola/Island/IslandWindows.swift:177-179` | naturalSwipe multiplies only the horizontal delta, so it affects skip swipes only. |
| 139 | Added controls (shuffle/repeat) | ✅ Done |  | `Sources/Isola/Modules/Media/NowPlayingSources.swift:102-103` | MediaRemote advance shuffle/repeat (commands 6/7) or AppleScript for Music/Spotify; state read back. |
| 140 | Added podcast support | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaViews.swift:576` | Apple Podcasts episodes get 15 s back / 30 s forward (relative seeks) instead of previous/next. |
| 141 | Added live stream support | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:131-135,171-177` | duration <= 0 shows a red Live badge and a mic glyph in the peek. |
| 142 | Added support for all AirPods Max colors (gen. 1) | 🔶 Built, unverified |  | `Sources/Isola/Modules/System/Bluetooth.swift:335` | 10 s BLE scan after a Lightning AirPods Max connects; five source codes paired to five gen-1 finishes (pairing is ours). Untested on hardware. |
| 143 | Added album tap to focus active tab | 🔶 Built, unverified |  | `Sources/Isola/Modules/Media/MediaViews.swift:371` | Album tap runs the same open-source path (tab focus needs Automation consent). |
| 144 | Added clamshell support | ✅ Done |  | `Sources/Isola/Island/IslandWindows.swift:81-83,95-97` | Screen-change refresh falls back to NSScreen.main when the built-in display disappears. |
| 145 | Reworked onboarding | ✅ Done |  | `Sources/Isola/Modules/Settings/Onboarding.swift:12-13,146` | Welcome, permissions with live status, done; no Focus or Full Disk Access rows. |
| 146 | Improved smoothness in progress slider | ✅ Done |  | `Sources/Isola/Support/SharedState.swift:40` | seek(to:) moves the bar at once, with a 1 s stale-snapshot hold (MediaModule.swift:176). Scrubber redraws at 30 fps. |
| 147 | Improved to allow for empty media titles | ✅ Done | ✓ | `Sources/Isola/Modules/Media/MediaModule.swift:158` | Untitled media plays under its app's name, with no stray separator; the helper keeps it while playing. |

## 1.1

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 148 | Added system player support (all media sources) | ✅ Done | ✓ | `Sources/Isola/Modules/Media/NowPlayingSources.swift:51-80; Helpers/MediaRemoteHelper.m` | Private MediaRemote via /usr/bin/perl helper on 15.4+; AppleScript fallback for Music/Spotify. |
| 149 | Added support for focus modes (including custom ones) | 🔶 Built, unverified |  | `Sources/Isola/Modules/System/Focus.swift:80` | Custom Focus modes come from the Focus database, which needs Full Disk Access (not granted on the test Mac). |
| 150 | Added configurable preferred display choice | ✅ Done |  | `Sources/Isola/Island/IslandWindows.swift:88-101; preferredDisplay` | Auto/main/built-in/named screen or all displays; identical monitors share a name. |
| 151 | Added natural movement option for swipes | ✅ Done |  | `Sources/Isola/Island/IslandWindows.swift:177; naturalSwipe` | Toggle in Island settings; inverts the horizontal swipe direction. |
| 152 | Added notification duration options | ✅ Done |  | `Sources/Isola/Island/Island.swift:80-81; notificationDuration` | 1.5-8 s slider; some alerts (low battery, leave) use fixed 5-6 s instead. |
| 153 | Added hover duration option for expand on hover | ✅ Done | ✓ | `Sources/Isola/Island/Island.swift:125; hoverExpandDelay` | Hover delay now expands peek-on-hover items too (media, calendar); verified live with isolactl. |
| 154 | Added ability to hide song title extras | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:57-60; media.hideTitleExtras` | Regex cleaner applies to the peek and expanded player; Lock Screen widget and menu show raw titles. |
| 155 | Improved design on non notch displays | ✅ Done |  | `Sources/Isola/Island/Geometry.swift:19-20; simulatedNotch` | Floating pill or simulated notch with ears; idle pill hidden by default. |
| 156 | Improved low battery warnings for connectivity to be instant | ✅ Done | ✓ | `Sources/Isola/Modules/System/Bluetooth.swift:33,100` | Battery poll every 10 s while a device is connected (was 120 s); IOBluetooth has no battery notification. |
| 157 | Improved marquee design to better match iOS | ✅ Done | ✓ | `Sources/Isola/Support/IslandUI.swift:57` | Rests left-aligned 1.5 s, scrolls one copy, loops. Re-measures when the text changes; scrolls only when it overflows. |
| 158 | Improved fine tuner by adding haptic sound | 🔶 Built, unverified |  | `Sources/Isola/Modules/Settings/SettingsWindow.swift:153` | Haptic + quiet Tink per fine-tuning step; the clamshell test Mac has no Force Touch trackpad. |
| 159 | Improved AirPods connectivity to be more reliable | ✅ Done |  | `Sources/Isola/Modules/System/Bluetooth.swift:19-41` | IOBluetooth connect/disconnect notifications with launch replay guard; no debounce for flapping, reliability unverified. |

## 1.0

| # | Feature | Status | Seen live | Evidence | Note |
|---|---|---|---|---|---|
| 160 | Added percentage option to HUD | ✅ Done | ✓ | `Sources/Isola/Modules/HUD/HUDViews.swift:60-62; hud.style` | Percentage text in the value wing for volume and brightness. |
| 161 | Added additional device symbols to volume HUD | ✅ Done | ✓ | `Sources/Isola/Modules/HUD/HUDModule.swift:66-81` | AirPods/Pro/Max/4, Beats, EarPods, HomePod, AirPlay, HDMI/DP and headphone jack from CoreAudio. |
| 162 | Added ability to fine tune notch height | ✅ Done |  | `Sources/Isola/Island/Geometry.swift:17,19; heightTweak` | Plus/minus 8 pt height slider under General, Fine tuning. |
| 163 | Added AirPods 4 connectivity support | ✅ Done |  | `Sources/Isola/Modules/System/Bluetooth.swift:180-181` | AirPods 4, with and without ANC, by product ID; airpods.gen4 falling back to gen3 or airpods. |
| 164 | Added option to hide labels on HUD | ✅ Done |  | `Sources/Isola/Modules/HUD/HUDModule.swift:166; hud.showLabels` | Label row under the notch only when enabled; otherwise the value wing shows the bar. |
| 165 | Added option to disable spectrogram | ✅ Done |  | `Sources/Isola/Modules/Media/MediaViews.swift:114-122; media.spectrogram` | Toggle swaps the spectrogram for a play/pause glyph. |
