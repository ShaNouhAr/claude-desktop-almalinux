#!/usr/bin/env bash
# =============================================================================
# install-claude-desktop.sh — Claude Desktop sur AlmaLinux (et autres EL9+/Fedora)
#
# Anthropic publie Claude Desktop pour Linux (bêta depuis le 30/06/2026) uniquement
# en .deb. Le projet communautaire aaddrick/claude-desktop-debian reconditionne ce
# .deb officiel en RPM (fichiers d'Anthropic non modifiés) et le publie dans un
# dépôt DNF signé. Ce script :
#   - vérifie la clé GPG du dépôt (empreinte épinglée) puis ajoute le dépôt ;
#   - installe les bibliothèques d'exécution (le RPM n'en déclare aucune) ;
#   - installe claude-desktop-unofficial ;
#   - met en place une mise à jour automatique qui ne touche QUE ce paquet et
#     qui attend que l'application soit fermée (timer systemd toutes les 6 h).
#
# Usage :
#   sudo ./install-claude-desktop.sh [install] [--no-auto-update] [--epel] [--rpm FICHIER|URL]
#   sudo ./install-claude-desktop.sh update [--force]   # mettre à jour maintenant
#   sudo ./install-claude-desktop.sh status             # version installée / dispo, timer
#   sudo ./install-claude-desktop.sh uninstall [--purge]
#
#   --no-auto-update  ne pas installer le timer de mise à jour automatique
#   --epel            activer EPEL (+CRB) pour l'icône de barre système (appindicator)
#   --rpm X           installer un RPM précis (fichier ou URL) au lieu du dépôt
#   --force           (update) mettre à jour même si l'application est ouverte
#   --purge           (uninstall) retirer aussi le dépôt et sa clé GPG
# =============================================================================
set -euo pipefail

PKG=claude-desktop-unofficial
APP_DIR=/usr/lib/claude-desktop-unofficial
REPO_FILE=/etc/yum.repos.d/claude-desktop-unofficial.repo
REPO_HOST=https://pkg.claude-desktop-debian.dev
KEY_URL=$REPO_HOST/KEY.gpg
KEY_FPR=87494CF73ACC0F23AA9557B86E29E413B912E0F1
UPDATER=/usr/local/sbin/claude-desktop-update
SVC=claude-desktop-update.service
TMR=claude-desktop-update.timer

# Bibliothèques demandées par le .deb officiel (Depends), traduites en noms EL.
DEPS_CORE="gtk3 libnotify nss nspr xdg-utils at-spi2-core at-spi2-atk libdrm mesa-libgbm
  mesa-libEGL libxcb libxkbcommon libsecret glib2 libXtst libXcomposite libXdamage libXrandr
  libuuid alsa-lib cups-libs pipewire-libs xdg-desktop-portal xdg-desktop-portal-gtk ca-certificates"
# Confort (Recommends) : installés si disponibles, sans faire échouer le script.
DEPS_OPT="gnome-keyring bubblewrap socat openssh-clients libXScrnSaver dejavu-sans-fonts"
DEPS_EPEL="libayatana-appindicator-gtk3"

c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_0=$'\e[0m'
[ -t 1 ] || { c_info=; c_ok=; c_warn=; c_err=; c_0=; }
info() { echo "${c_info}==>${c_0} $*"; }
ok()   { echo "${c_ok} ok${c_0} $*"; }
warn() { echo "${c_warn}  ! ${c_0}$*" >&2; }
die()  { echo "${c_err}ERREUR:${c_0} $*" >&2; exit 1; }

LOG=/var/log/claude-desktop-install.log
TMPD=""
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; return 0; }
trap cleanup EXIT
# Exécute une commande en journalisant sa sortie ; en cas d'échec, montre la fin du journal.
run() {
  echo "+ $*" >>"$LOG"
  if ! "$@" >>"$LOG" 2>&1; then echo "--- fin de $LOG ---" >&2; tail -20 "$LOG" >&2; return 1; fi
}

usage() { sed -n '2,/^# ====/{/^# ====/d;s/^# \{0,1\}//;p}' "$0"; exit "${1:-0}"; }

need_root() {
  [ "$(id -u)" -eq 0 ] && return
  command -v sudo >/dev/null || die "lance ce script en root (sudo absent)"
  exec sudo -- "$0" "$@"
}

has_systemd() { [ -d /run/systemd/system ]; }

check_platform() {
  [ -r /etc/os-release ] || die "/etc/os-release introuvable"
  . /etc/os-release
  local like=" ${ID:-} ${ID_LIKE:-} "
  case "$like" in
    *" rhel "*|*" fedora "*|*" centos "*|*" almalinux "*|*" rocky "*) ;;
    *) die "distribution non prise en charge : ${PRETTY_NAME:-$ID} (attendu AlmaLinux/RHEL/Rocky/Fedora)";;
  esac
  local major=${VERSION_ID%%.*}
  if [ "${ID:-}" != fedora ] && [ "${major:-0}" -lt 9 ]; then
    die "${PRETTY_NAME} trop ancienne : glibc ≥ 2.34 requise (EL9 minimum)"
  fi
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "architecture $(uname -m) non prise en charge";; esac
  command -v dnf >/dev/null || die "dnf introuvable"
  ok "plateforme : ${PRETTY_NAME} ($(uname -m))"
}

app_running() { pgrep -f "$APP_DIR/claude-desktop" >/dev/null 2>&1; }
installed_version() { rpm -q --qf '%{VERSION}-%{RELEASE}' "$PKG" 2>/dev/null || true; }

setup_repo() {
  info "Clé GPG du dépôt (vérification de l'empreinte)"
  local need=""
  command -v curl >/dev/null || need="$need curl"
  command -v gpg  >/dev/null || need="$need gnupg2"
  # shellcheck disable=SC2086
  [ -n "$need" ] && { run dnf -y install $need || die "installation de$need impossible"; }
  TMPD=$(mktemp -d)
  curl -fsSL --retry 3 "$KEY_URL" -o "$TMPD/key.gpg" || die "téléchargement de la clé impossible ($KEY_URL)"
  local fpr
  fpr=$(gpg --homedir "$TMPD" --show-keys --with-colons "$TMPD/key.gpg" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
  [ "$fpr" = "$KEY_FPR" ] || die "empreinte inattendue : '$fpr' (attendue $KEY_FPR) — installation annulée"
  rpm --import "$TMPD/key.gpg"
  ok "clé $KEY_FPR importée"

  info "Dépôt DNF $REPO_FILE"
  cat > "$REPO_FILE" <<EOF
[claude-desktop-unofficial]
name=Claude Desktop (unofficial packaging) for Fedora/RHEL
baseurl=$REPO_HOST/rpm/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$KEY_URL
metadata_expire=1h
EOF
  ok "dépôt ajouté"
}

install_deps() {
  local epel=$1
  info "Bibliothèques d'exécution"
  # shellcheck disable=SC2086
  run dnf -y install $DEPS_CORE || die "échec de l'installation des dépendances principales"
  ok "dépendances principales installées"
  local p opt=$DEPS_OPT
  if [ "$epel" = 1 ]; then
    info "EPEL + CRB (icône de barre système)"
    run dnf -y install epel-release dnf-plugins-core || warn "epel-release indisponible"
    dnf config-manager --set-enabled crb >>"$LOG" 2>&1 || true
    opt="$opt $DEPS_EPEL"
  fi
  for p in $opt; do
    if dnf -y install "$p" >>"$LOG" 2>&1; then ok "$p"; else warn "$p indisponible (facultatif)"; fi
  done
}

install_updater() {
  info "Mise à jour automatique (uniquement $PKG, application fermée)"
  cat > "$UPDATER" <<'EOF'
#!/usr/bin/env bash
# Met à jour claude-desktop-unofficial, sauf si l'application est ouverte
# (remplacer les fichiers d'une app Electron en cours d'exécution peut la faire planter).
# Usage : claude-desktop-update [--force]
set -uo pipefail
PKG=claude-desktop-unofficial
APP_DIR=/usr/lib/claude-desktop-unofficial
FORCE=0; [ "${1:-}" = --force ] && FORCE=1
log() { echo "[claude-desktop-update] $*"; command -v logger >/dev/null && logger -t claude-desktop-update "$*"; return 0; }
[ "$(id -u)" -eq 0 ] || { echo "à lancer en root" >&2; exit 1; }
before=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$PKG" 2>/dev/null) || { log "$PKG non installé"; exit 0; }
dnf -q --refresh check-update "$PKG" >/dev/null 2>&1; rc=$?
case $rc in
  0)   log "déjà à jour ($before)"; exit 0;;
  100) ;;
  *)   log "échec de la vérification (dnf rc=$rc)"; exit 1;;
esac
if [ "$FORCE" = 0 ] && pgrep -f "$APP_DIR/claude-desktop" >/dev/null 2>&1; then
  log "mise à jour disponible mais Claude Desktop est ouvert : reportée (relance après fermeture ou --force)"
  exit 0
fi
dnf -y -q upgrade "$PKG" || { log "échec de la mise à jour"; exit 1; }
log "mis à jour : $before -> $(rpm -q --qf '%{VERSION}-%{RELEASE}' "$PKG")"
EOF
  chmod 0755 "$UPDATER"

  cat > "/etc/systemd/system/$SVC" <<EOF
[Unit]
Description=Mise à jour de Claude Desktop (si l'application est fermée)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATER
Nice=10
IOSchedulingClass=idle
EOF
  cat > "/etc/systemd/system/$TMR" <<EOF
[Unit]
Description=Vérification périodique des mises à jour de Claude Desktop

[Timer]
OnBootSec=3min
OnUnitActiveSec=6h
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if has_systemd; then
    systemctl daemon-reload
    systemctl enable --now "$TMR" >/dev/null 2>&1 && ok "timer $TMR actif (toutes les 6 h et 3 min après le démarrage)"
  else
    systemctl enable "$TMR" >/dev/null 2>&1 || true
    warn "systemd n'est pas actif (conteneur ?) : timer installé, il démarrera au prochain boot"
  fi
}

remove_updater() {
  if has_systemd; then systemctl disable --now "$TMR" >/dev/null 2>&1 || true; else systemctl disable "$TMR" >/dev/null 2>&1 || true; fi
  rm -f "/etc/systemd/system/$TMR" "/etc/systemd/system/$SVC" "$UPDATER"
  has_systemd && systemctl daemon-reload || true
}

cmd_install() {
  local auto=1 epel=0 rpm_src=""
  while [ $# -gt 0 ]; do
    case $1 in
      --no-auto-update) auto=0;;
      --epel) epel=1;;
      --rpm) rpm_src=${2:?--rpm attend un fichier ou une URL}; shift;;
      -h|--help) usage;;
      *) die "option inconnue : $1";;
    esac; shift
  done
  echo "===== $(date -Is) install $* =====" >>"$LOG"
  check_platform
  setup_repo
  install_deps "$epel"
  if [ -n "$rpm_src" ]; then
    info "Installation de $rpm_src"
    run dnf -y install "$rpm_src" || die "échec de l'installation de $rpm_src"
  else
    info "Installation de $PKG depuis le dépôt"
    run dnf -y --refresh install "$PKG" || die "échec de l'installation de $PKG"
  fi
  ok "$PKG $(installed_version) installé"
  if [ "$auto" = 1 ]; then install_updater; else remove_updater; warn "mise à jour automatique désactivée"; fi
  cat <<EOF

${c_ok}Claude Desktop est installé.${c_0}
  Lancer      : menu « Claude » ou  claude-desktop-unofficial
  Diagnostic  : claude-desktop-unofficial --doctor
  Mettre à jour maintenant : sudo $0 update   (ou : sudo dnf upgrade $PKG)
  État        : sudo $0 status
  Journal     : $LOG
EOF
}

cmd_update() {
  local force=""
  [ "${1:-}" = --force ] && force=--force
  [ -n "$(installed_version)" ] || die "$PKG n'est pas installé"
  if [ -x "$UPDATER" ]; then "$UPDATER" $force; else
    if [ -z "$force" ] && app_running; then die "Claude Desktop est ouvert : ferme-le ou utilise --force"; fi
    dnf -y --refresh upgrade "$PKG"
  fi
}

cmd_status() {
  local inst latest
  inst=$(installed_version)
  latest=$(dnf -q --refresh repoquery --latest-limit 1 --qf '%{version}-%{release}' "$PKG" 2>/dev/null | tail -1 || true)
  echo "installé    : ${inst:-non installé}"
  echo "dépôt       : ${latest:-inconnu}"
  echo "en cours    : $(app_running && echo oui || echo non)"
  if [ -n "$inst" ] && [ -n "$latest" ]; then
    if [ "$inst" = "$latest" ]; then echo "état        : à jour"; else echo "état        : mise à jour disponible"; fi
  fi
  if [ -f "/etc/systemd/system/$TMR" ]; then
    if has_systemd; then systemctl list-timers "$TMR" --no-pager 2>/dev/null | sed -n '1,2p'; else echo "timer       : installé (systemd inactif)"; fi
  else
    echo "timer       : absent (mise à jour automatique désactivée)"
  fi
}

cmd_uninstall() {
  local purge=0; [ "${1:-}" = --purge ] && purge=1
  app_running && warn "Claude Desktop est ouvert : il sera interrompu"
  remove_updater
  dnf -y -q remove "$PKG" >/dev/null 2>&1 || true
  ok "$PKG désinstallé (la config utilisateur ~/.config/Claude est conservée)"
  if [ "$purge" = 1 ]; then
    rm -f "$REPO_FILE"
    local k; k=$(rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE} %{PACKAGER}\n' 2>/dev/null | awk '/claude-desktop-debian/{print $1}')
    [ -n "$k" ] && rpm -e $k
    ok "dépôt et clé GPG retirés"
  fi
}

main() {
  need_root "$@"
  local cmd=install
  case "${1:-}" in
    install|update|status|uninstall) cmd=$1; shift;;
    -h|--help) usage;;
  esac
  "cmd_$cmd" "$@"
}
main "$@"
