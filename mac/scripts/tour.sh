#!/bin/bash
# Drives a running Isola through every state with isolactl and screenshots the top of
# the main display after each step. Usage: scripts/tour.sh <outDir>
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/tour}
mkdir -p "$OUT"
CTL=build/isolactl
# Region around the island on the main display (points); override for other screens.
W=$(system_profiler SPDisplaysDataType 2>/dev/null | awk '/Main Display: Yes/{print prev} {prev=$0}' | head -1 | grep -oE '[0-9]+ x' | head -1 | tr -d ' x')
W=${W:-2560}
X=$(( W / 2 - 330 ))
n=0
shot() { # shot <name> [height]
  n=$((n + 1))
  sleep "${WAIT:-0.9}"
  screencapture -x -R "$X,0,660,${2:-140}" "$OUT/$(printf %02d $n)-$1.png"
}
step() { $CTL "$@"; }

step pref showIdlePill=1;               shot idle-pill
step pref showIdlePill=0 simulatedNotch=1; shot idle-simulated-notch
step pref simulatedNotch=0

step system.unlock;                     shot unlock
step system.lock;                       shot locked
step system.unlock;                     WAIT=1.2 shot unlocked-collapse

step system.bluetooth name="AirPods Pro" kind=airpodspro battery=0.76 on=1; shot bluetooth
step dismiss
step system.charging on=1 level=0.64;   shot charging
step dismiss
step system.battery level=0.09;         shot low-battery
step dismiss
step system.lowpower on=1;              shot low-power
step dismiss
step system.focus name=Work symbol=person.crop.square.fill on=1; shot focus
step dismiss

step hud.volume level=0.35 device=speaker; shot hud-volume
step hud.volume level=0 muted=1;        shot hud-muted
step hud.volume level=0.7 device=airpods; shot hud-volume-airpods
step hud.brightness level=0.6;          shot hud-brightness
step dismiss

step media.play title="Ocean Breeze" artist="Isola Ensemble" album="Pill"; WAIT=1.4 shot media-playing
step peek on=1;                         shot media-peek
step peek on=0
step expand on=1;                       WAIT=1.2 shot media-expanded 260
step expand on=0
step media.pause;                       shot media-paused
step media.resume

step cal.event title="Design review" in=4; shot calendar-activity
step expand on=1;                       WAIT=1.2 shot calendar-expanded 300
step expand on=0
step cycle;                             shot cycled-activity
step cal.leave title="Design review";   shot time-to-leave
step dismiss
step timer.start seconds=95;            shot timer
step timer.stop
step cal.clear
step media.end

step pref showIdlePill=1
step hover on=1;                        shot hover
step hover on=0
step pref showIdlePill=0

# Full-screen views: settings window and the Lock Screen widget preview.
big() { n=$((n + 1)); sleep "${WAIT:-1.5}"; screencapture -x "$OUT/$(printf %02d $n)-$1.png"; }
step settings.open section=general;     big settings-general
step settings.open section=media;       big settings-media
step settings.open section=hud;         big settings-hud
step settings.open section=license;     big settings-license
step settings.close
step media.play title="Ocean Breeze" artist="Isola Ensemble"
step lock.preview on=1;                 WAIT=2 big lockscreen-preview
step lock.preview on=0
step media.end
echo "tour: $n screenshots in $OUT"
