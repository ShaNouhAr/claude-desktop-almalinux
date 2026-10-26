#!/usr/bin/env bash
# Lancé avec DISPLAY défini (Xvfb sur EL9, xwfb-run+cage sur EL10).
# Usage : gui-phase.sh LABEL TEST_REPORT(0|1)
LABEL=$1; DEFER=${2:-0}
. /etc/os-release; TAG=el${VERSION_ID%%.*}; R=/out/$TAG-results.txt
APP=/usr/lib/claude-desktop-unofficial/claude-desktop
res(){ echo "[$1] $2" | tee -a "$R"; }
IM=$(command -v magick || command -v convert)
shot(){ import -display "$DISPLAY" -window root "$1" 2>/dev/null; }
sdev(){ $IM "$1" -format '%[fx:standard_deviation]' info: 2>/dev/null || echo 0; }
# pixels de la couleur du logo Claude (#D97757) : preuve que l'interface est vraiment rendue
logo(){ $IM "$1" -fuzz 15% -fill white +opaque '#D97757' -fill black -opaque '#D97757' -negate -format '%[fx:round(mean*w*h)]' info: 2>/dev/null || echo 0; }

su tester -s /bin/bash -c "export DISPLAY=$DISPLAY XDG_RUNTIME_DIR=/tmp/xdg-tester; \
  dbus-run-session -- /usr/bin/claude-desktop-unofficial --no-sandbox --disable-gpu" >/tmp/app-$LABEL.out 2>&1 &

ready=0
for i in $(seq 1 25); do
  sleep 3
  shot /tmp/s.png
  sd=$(sdev /tmp/s.png)
  if pgrep -f "$APP" >/dev/null && [ "$(logo /tmp/s.png)" -gt 200 ]; then ready=1; break; fi
done
sleep 4; shot "/out/$TAG-$LABEL.png"
ver=$(rpm -q --qf '%{VERSION}' claude-desktop-unofficial)
if [ $ready = 1 ]; then res PASS "$LABEL : interface rendue, logo Claude détecté ($(logo /out/$TAG-$LABEL.png) px, v$ver)"
else res FAIL "$LABEL : interface non rendue après 75 s (processus: $(pgrep -fc "$APP"), logo: $(logo /tmp/s.png) px)"; tail -15 /tmp/app-$LABEL.out; fi
if command -v xwininfo >/dev/null; then
  w=$(xwininfo -root -tree 2>/dev/null | grep -ciE 'claude')
  [ "$w" -gt 0 ] && res PASS "$LABEL : $w fenêtre(s) X nommée(s) « Claude »" || res FAIL "$LABEL : aucune fenêtre X « Claude »"
fi

if [ "$DEFER" = 1 ]; then
  before=$(rpm -q --qf '%{VERSION}' claude-desktop-unofficial)
  out=$(/usr/local/sbin/claude-desktop-update 2>&1); echo "$out" > "/out/$TAG-updater-app-ouverte.txt"
  after=$(rpm -q --qf '%{VERSION}' claude-desktop-unofficial)
  if echo "$out" | grep -q reportée && [ "$before" = "$after" ]; then res PASS "mise à jour reportée pendant que l'app tourne (reste en v$after)"
  else res FAIL "report de mise à jour : sortie='$out' version $before -> $after"; fi
fi

pkill -f "$APP"; for i in $(seq 1 15); do pgrep -f "$APP" >/dev/null || break; sleep 1; done
pgrep -f "$APP" >/dev/null && { pkill -9 -f "$APP"; sleep 1; }
pgrep -f "$APP" >/dev/null && res FAIL "$LABEL : l'app ne s'arrête pas" || res PASS "$LABEL : app fermée proprement"
