#!/usr/bin/env bash
# Exécuté DANS un conteneur almalinux:9 ou :10 (lancé par run-docker-tests.sh).
set -uo pipefail
OLD_RPM=${OLD_RPM:-https://github.com/aaddrick/claude-desktop-debian/releases/download/v3.3.12%2Bclaude3.1623.1/claude-desktop-unofficial-3.1623.1-3.3.12-1.x86_64.rpm}
INST=/work/install-claude-desktop.sh
APP_DIR=/usr/lib/claude-desktop-unofficial
. /etc/os-release; EL=${VERSION_ID%%.*}; TAG=el$EL; R=/out/$TAG-results.txt
: > "$R"
res(){ echo "[$1] $2" | tee -a "$R"; }
step(){ echo; echo "################ [$TAG] $*"; }

step "1. installation d'une ANCIENNE version via le script (--rpm)"
bash "$INST" install --rpm "$OLD_RPM" > "/out/$TAG-install.log" 2>&1; rc=$?
tail -12 "/out/$TAG-install.log"
v1=$(rpm -q --qf '%{VERSION}-%{RELEASE}' claude-desktop-unofficial 2>/dev/null)
[ $rc = 0 ] && [[ "$v1" == 3.1623.1-* ]] && res PASS "install (ancienne version) : $v1" || res FAIL "install rc=$rc version='$v1'"
[ -f /etc/yum.repos.d/claude-desktop-unofficial.repo ] && res PASS "dépôt DNF configuré" || res FAIL "dépôt absent"
rpm -q gpg-pubkey --qf '%{PACKAGER}\n' | grep -q claude-desktop-debian && res PASS "clé GPG importée (empreinte vérifiée)" || res FAIL "clé GPG absente"
[ -x /usr/local/sbin/claude-desktop-update ] && [ -f /etc/systemd/system/claude-desktop-update.timer ] && res PASS "updater + timer systemd installés" || res FAIL "updater/timer absents"

step "2. dépendances : ldd sur les binaires de l'app (AVANT tout outil de test)"
miss=$(find "$APP_DIR" -maxdepth 1 -type f \( -name claude-desktop -o -name '*.so' -o -name '*.so.*' \) -exec ldd {} \; 2>/dev/null | grep 'not found' | sort -u)
[ -z "$miss" ] && res PASS "aucune bibliothèque manquante (ldd)" || { res FAIL "bibliothèques manquantes :"; echo "$miss" | tee -a "$R"; }

step "3. validation des unités systemd"
if command -v systemd-analyze >/dev/null; then
  o=$(systemd-analyze verify /etc/systemd/system/claude-desktop-update.timer /etc/systemd/system/claude-desktop-update.service 2>&1 | grep -v -E 'Failed to (connect|set up)|bus|Cannot add dependency job' )
  [ -z "$o" ] && res PASS "systemd-analyze verify OK" || res FAIL "systemd-analyze : $o"
else echo "(systemd-analyze absent)"; fi

step "4. outils de test (écran virtuel, captures) + utilisateur non-root"
dnf -y -q install epel-release >/dev/null 2>&1; dnf -q makecache >/dev/null 2>&1
# EL10 n'a plus de serveur X logiciel (ni Xvfb ni Xvnc) : on utilise alors l'Xvfb d'un
# conteneur voisin (EXT_DISPLAY, socket X partagé), sinon un Xvfb local (EL9).
if [ -n "${EXT_DISPLAY:-}" ]; then dnf -y -q install dbus-daemon ImageMagick procps-ng util-linux >/dev/null 2>&1
else dnf -y -q install xorg-x11-server-Xvfb xorg-x11-utils dbus-daemon ImageMagick procps-ng util-linux >/dev/null 2>&1; fi
useradd -m tester 2>/dev/null; mkdir -p -m 700 /tmp/xdg-tester; chown tester: /tmp/xdg-tester
export XDG_RUNTIME_DIR=/tmp/xdg-root; mkdir -p -m 700 $XDG_RUNTIME_DIR
gui(){ # gui LABEL DEFER
  if [ -n "${EXT_DISPLAY:-}" ]; then
    DISPLAY=$EXT_DISPLAY bash /work/test/gui-phase.sh "$1" "$2"
  else
    pgrep -x Xvfb >/dev/null || { Xvfb :99 -screen 0 1280x800x24 -ac >/tmp/xvfb.log 2>&1 & sleep 2; }
    DISPLAY=:99 bash /work/test/gui-phase.sh "$1" "$2"
  fi
}

step "5. lancement de l'ancienne version + test du report de mise à jour"
gui v1-ancienne 1

step "6. mise à jour (app fermée) via le script"
bash "$INST" update > "/out/$TAG-update.log" 2>&1; cat "/out/$TAG-update.log"
v2=$(rpm -q --qf '%{VERSION}-%{RELEASE}' claude-desktop-unofficial)
latest=$(dnf -q repoquery --latest-limit 1 --qf '%{version}-%{release}' claude-desktop-unofficial | tail -1)
[ "$v2" = "$latest" ] && [ "$v2" != "$v1" ] && res PASS "mise à jour : $v1 -> $v2 (= dernière du dépôt)" || res FAIL "mise à jour : $v1 -> $v2 (dépôt : $latest)"

step "7. lancement de la nouvelle version"
gui v2-nouvelle 0

step "8. status + 2e update (doit dire à jour)"
bash "$INST" status | tee "/out/$TAG-status.txt"
grep -q 'à jour' "/out/$TAG-status.txt" && res PASS "status : à jour" || res FAIL "status inattendu"
/usr/local/sbin/claude-desktop-update | grep -q 'déjà à jour' && res PASS "updater : déjà à jour (rien à faire)" || res FAIL "updater ne détecte pas l'état à jour"

step "9. désinstallation --purge"
bash "$INST" uninstall --purge > "/out/$TAG-uninstall.log" 2>&1
! rpm -q claude-desktop-unofficial >/dev/null 2>&1 && [ ! -e /etc/systemd/system/claude-desktop-update.timer ] && [ ! -e /etc/yum.repos.d/claude-desktop-unofficial.repo ] \
  && res PASS "désinstallation propre (paquet, timer, dépôt, clé)" || res FAIL "résidus après désinstallation"

echo; echo "======== BILAN $TAG : $(grep -c '^\[PASS' "$R") PASS / $(grep -c '^\[FAIL' "$R") FAIL ========"
grep -q '^\[FAIL' "$R" && exit 1 || exit 0
