#!/usr/bin/env bash
# Lance les tests dans des conteneurs AlmaLinux 9 et 10, l'un après l'autre.
# Usage : test/run-docker-tests.sh [9] [10]     (DOCKER="sudo docker" si besoin)
# EL10 n'ayant plus de serveur X logiciel, son affichage est fourni par un Xvfb tournant
# dans un conteneur AlmaLinux 9 voisin (socket X11 et mémoire partagée).
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd); OUT=$DIR/test/out; DOCKER=${DOCKER:-docker}
mkdir -p "$OUT"; rc=0
X=cda-xvfb; VOL=cda-x11
stop_x() { $DOCKER rm -f $X >/dev/null 2>&1; $DOCKER volume rm $VOL >/dev/null 2>&1; true; }
start_x() {
  stop_x
  $DOCKER run -d --name $X --ipc=shareable --shm-size 1g -v $VOL:/tmp/.X11-unix almalinux:9 \
    bash -c "dnf -y -q install xorg-x11-server-Xvfb >/dev/null && chmod 1777 /tmp/.X11-unix && exec Xvfb :99 -screen 0 1280x800x24 -ac -nolisten tcp" >/dev/null
  for i in $(seq 1 90); do $DOCKER exec $X test -S /tmp/.X11-unix/X99 2>/dev/null && return 0; sleep 2; done
  echo "Xvfb voisin indisponible" >&2; return 1
}
trap stop_x EXIT
for vv in ${*:-9 10}; do
  echo "=================== almalinux:$vv ==================="
  extra=(--shm-size 1g)
  if [ "$vv" -ge 10 ]; then start_x || { rc=1; continue; }; extra=(--ipc=container:$X -v $VOL:/tmp/.X11-unix -e EXT_DISPLAY=:99); fi
  $DOCKER run --rm --memory 2500m "${extra[@]}" -v "$DIR":/work:ro -v "$OUT":/out almalinux:$vv bash /work/test/in-container.sh || rc=1
  [ "$vv" -ge 10 ] && stop_x
done
echo; for f in "$OUT"/el*-results.txt; do echo "== $(basename "$f")"; cat "$f"; done
exit $rc
