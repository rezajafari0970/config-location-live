#!/bin/bash
set -Eeuo pipefail

BASE="/root/3245"
SRC="/opt/config-location"
OUT="$BASE/runtime-pass2-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"

echo "===== RUNTIME PASS 2 FULL REPORT =====" > "$OUT/info.txt"
date >> "$OUT/info.txt"

#######################################
# 1) BIN FILE LIST + FULL CONTENT
#######################################

echo "[1] BIN FILES"

mkdir -p "$OUT/bin"

if [ -d "$SRC/bin" ]; then
    find "$SRC/bin" -maxdepth 1 -type f -printf '%p\n' | sort \
        > "$OUT/bin-file-list.txt"

    while read -r FILE; do
        {
            echo
            echo "=================================================="
            echo "FILE: $FILE"
            echo "=================================================="
            cat "$FILE"
            echo
        } >> "$OUT/bin-full-content.txt"
    done < "$OUT/bin-file-list.txt"

    cp -a "$SRC/bin/." "$OUT/bin/" 2>/dev/null || true
fi

#######################################
# 2) PROJECT SYSTEMD FILES
#######################################

echo "[2] PROJECT SYSTEMD FILES"

mkdir -p "$OUT/project-systemd"

find "$SRC" -type f \
    \( -name "*.service" -o -name "*.timer" -o -name "*.socket" \) \
    -not -path "*/venv/*" \
    -not -path "*/backups/*" \
    -print | sort > "$OUT/project-systemd-file-list.txt"

while read -r FILE; do
    {
        echo
        echo "=================================================="
        echo "FILE: $FILE"
        echo "=================================================="
        cat "$FILE"
        echo
    } >> "$OUT/project-systemd-full-content.txt"
done < "$OUT/project-systemd-file-list.txt"

#######################################
# 3) INSTALLED SYSTEMD UNITS
#######################################

echo "[3] INSTALLED SYSTEMD UNITS"

mkdir -p "$OUT/installed-systemd"

find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system \
    -maxdepth 2 \
    -type f \
    \( -iname "*config-location*" -o -iname "*configloc*" \) \
    -print 2>/dev/null | sort -u \
    > "$OUT/installed-systemd-file-list.txt"

while read -r FILE; do
    SAFE_NAME="$(echo "$FILE" | sed 's#/#__#g')"
    cp -a "$FILE" "$OUT/installed-systemd/$SAFE_NAME" 2>/dev/null || true

    {
        echo
        echo "=================================================="
        echo "FILE: $FILE"
        echo "=================================================="
        cat "$FILE"
        echo
    } >> "$OUT/installed-systemd-full-content.txt"
done < "$OUT/installed-systemd-file-list.txt"

#######################################
# 4) SYSTEMCTL UNIT LIST
#######################################

echo "[4] SYSTEMCTL UNIT LIST"

systemctl list-unit-files --no-pager \
    | grep -Ei 'config-location|configloc' \
    > "$OUT/systemctl-unit-files.txt" || true

systemctl list-units --all --no-pager \
    | grep -Ei 'config-location|configloc' \
    > "$OUT/systemctl-units-all.txt" || true

#######################################
# 5) FULL STATUS
#######################################

echo "[5] SYSTEMD STATUS"

mapfile -t UNITS < <(
    systemctl list-unit-files --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | grep -Ei 'config-location|configloc' \
    | sort -u
)

for UNIT in "${UNITS[@]:-}"; do
    [ -n "$UNIT" ] || continue

    {
        echo
        echo "##################################################"
        echo "UNIT: $UNIT"
        echo "##################################################"

        echo "===== STATUS ====="
        systemctl status "$UNIT" --no-pager -l 2>&1 || true

        echo
        echo "===== CAT ====="
        systemctl cat "$UNIT" --no-pager 2>&1 || true

        echo
        echo "===== SHOW ====="
        systemctl show "$UNIT" --no-pager \
            -p Id \
            -p Names \
            -p Description \
            -p LoadState \
            -p ActiveState \
            -p SubState \
            -p UnitFileState \
            -p MainPID \
            -p ExecMainPID \
            -p ExecMainStatus \
            -p ExecMainCode \
            -p User \
            -p Group \
            -p FragmentPath \
            -p DropInPaths \
            -p ExecStart \
            -p ExecStop \
            -p Restart \
            -p RestartUSec \
            -p TimeoutStartUSec \
            -p TimeoutStopUSec \
            -p KillMode \
            -p TasksMax \
            -p LimitNOFILE \
            -p After \
            -p Before \
            -p Wants \
            -p Requires \
            -p WantedBy \
            2>&1 || true

    } >> "$OUT/systemd-status-full.txt"
done

#######################################
# 6) DROP-INS
#######################################

echo "[6] SYSTEMD DROP-INS"

find /etc/systemd/system \
    -type f \
    -path '*.service.d/*' \
    | grep -Ei 'config-location|configloc' \
    | sort \
    > "$OUT/dropin-file-list.txt" || true

while read -r FILE; do
    [ -n "$FILE" ] || continue
    {
        echo
        echo "=================================================="
        echo "DROP-IN: $FILE"
        echo "=================================================="
        cat "$FILE"
        echo
    } >> "$OUT/dropins-full-content.txt"
done < "$OUT/dropin-file-list.txt"

#######################################
# 7) PROCESS TREE
#######################################

echo "[7] PROCESS TREE"

ps -eo \
pid,ppid,user,group,stat,lstart,etimes,%cpu,%mem,args \
    --sort=pid \
    > "$OUT/processes-all.txt"

grep -Ei \
'config-location|configloc|app\.fetcher|app\.health|app\.country|app\.panel|xray' \
"$OUT/processes-all.txt" \
    > "$OUT/processes-project.txt" || true

pstree -ap 2>/dev/null \
    > "$OUT/pstree-all.txt" || true

#######################################
# 8) LISTENING PORTS
#######################################

echo "[8] PORTS"

ss -lntup > "$OUT/listening-ports.txt" 2>&1 || true

#######################################
# 9) RUNTIME LOCKS / PID / TRIGGERS
#######################################

echo "[9] RUNTIME FILES"

for DIR in \
    /run/config-location \
    /var/lib/config-location/runtime \
    /var/lib/config-location/state \
    /var/lib/config-location/source-triggers
do
    {
        echo
        echo "=================================================="
        echo "DIR: $DIR"
        echo "=================================================="
        find "$DIR" -maxdepth 2 -printf \
            '%M %u:%g %s %TY-%Tm-%Td %TH:%TM:%TS %p\n' \
            2>/dev/null | sort || true
    } >> "$OUT/runtime-files.txt"
done

#######################################
# 10) RECENT JOURNAL
#######################################

echo "[10] RECENT JOURNAL"

for UNIT in "${UNITS[@]:-}"; do
    [ -n "$UNIT" ] || continue
    {
        echo
        echo "##################################################"
        echo "UNIT: $UNIT"
        echo "##################################################"
        journalctl -u "$UNIT" \
            --since "24 hours ago" \
            --no-pager \
            -n 500 \
            2>&1 || true
    } >> "$OUT/journal-last24h.txt"
done

#######################################
# 11) FILE METADATA / HASHES
#######################################

echo "[11] HASHES"

{
    find "$SRC/bin" -maxdepth 1 -type f 2>/dev/null
    cat "$OUT/project-systemd-file-list.txt" 2>/dev/null || true
    cat "$OUT/installed-systemd-file-list.txt" 2>/dev/null || true
} | sort -u | while read -r FILE; do
    [ -f "$FILE" ] || continue
    sha256sum "$FILE"
done > "$OUT/runtime-file-sha256.txt"

#######################################
# 12) PACK
#######################################

echo "[12] PACK"

ARCHIVE="${OUT}.tar.zst"

tar -cf - \
    -C "$BASE" \
    "$(basename "$OUT")" \
| zstd -15 -T0 -o "$ARCHIVE"

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

echo
echo "DONE"
echo "$ARCHIVE"
echo "$ARCHIVE.sha256"
