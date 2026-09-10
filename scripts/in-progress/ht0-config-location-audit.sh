#!/usr/bin/env bash

set -u

OUT="/root/HT0-CONFIG-LOCATION-BASELINE-$(date +%Y%m%d-%H%M%S).txt"

exec > >(tee "$OUT") 2>&1

echo "============================================================"
echo " CONFIG LOCATION - HT0 BASELINE / ISOLATION AUDIT"
echo "============================================================"
echo
echo "DATE: $(date -Is)"
echo "HOSTNAME: $(hostname)"
echo

echo "============================================================"
echo "1. OS"
echo "============================================================"

cat /etc/os-release 2>/dev/null || true
echo
uname -a || true
echo


echo "============================================================"
echo "2. CPU / RAM / DISK"
echo "============================================================"

nproc || true
free -h || true
df -h / /opt /var 2>/dev/null || true
echo


echo "============================================================"
echo "3. CONFIG LOCATION DIRECTORIES"
echo "============================================================"

for p in \
    /opt/config-location \
    /etc/config-location \
    /var/lib/config-location \
    /var/log/config-location \
    /run/config-location
do
    echo
    echo "----- $p -----"
    ls -ld "$p" 2>&1 || true
done

echo


echo "============================================================"
echo "4. SYSTEMD SERVICES"
echo "============================================================"

for s in \
    config-location-fetcher.service \
    config-location-panel.service
do
    echo
    echo "----- $s -----"

    systemctl is-enabled "$s" 2>&1 || true
    systemctl is-active "$s" 2>&1 || true
    systemctl status "$s" --no-pager -l 2>&1 | head -n 60 || true

    echo
    echo "UNIT:"
    systemctl cat "$s" 2>&1 || true
done

echo


echo "============================================================"
echo "5. PORT 4040"
echo "============================================================"

ss -lntp 2>&1 | grep -E '(^|[[:space:]])[^ ]*:4040([[:space:]]|$)' || true

echo
curl \
    --max-time 5 \
    -sS \
    -o /dev/null \
    -w 'HTTP_CODE=%{http_code}\n' \
    http://127.0.0.1:4040/ 2>&1 || true

echo


echo "============================================================"
echo "6. ALL LISTENING PORTS"
echo "============================================================"

ss -lntup 2>&1 || true
echo


echo "============================================================"
echo "7. CONFIGLOC USER"
echo "============================================================"

id configloc 2>&1 || true
getent passwd configloc 2>&1 || true
getent group configloc 2>&1 || true
echo


echo "============================================================"
echo "8. XRAY BINARIES"
echo "============================================================"

command -v xray 2>&1 || true

echo
echo "----- /usr/local/bin/xray -----"

if [ -e /usr/local/bin/xray ]; then

    ls -lah /usr/local/bin/xray
    sha256sum /usr/local/bin/xray 2>&1 || true
    /usr/local/bin/xray version 2>&1 | head -n 20 || true

else

    echo "NOT FOUND"

fi

echo
echo "----- all xray executables -----"

find \
    /opt \
    /usr/local \
    /root \
    -type f \
    \( -name 'xray' -o -name 'xray-linux-*' \) \
    -print \
    2>/dev/null || true

echo


echo "============================================================"
echo "9. RUNNING XRAY PROCESSES"
echo "============================================================"

ps -eo \
    user,pid,ppid,lstart,cmd \
    | grep -i '[x]ray' \
    || true

echo


echo "============================================================"
echo "10. WHO REFERENCES XRAY"
echo "============================================================"

grep -RIn \
    --exclude='*.log' \
    --exclude='*.gz' \
    --exclude='*.tar' \
    --exclude='*.zip' \
    '/usr/local/bin/xray\|/opt/.*/xray' \
    /etc/systemd/system \
    /opt \
    2>/dev/null \
    | head -n 500 \
    || true

echo


echo "============================================================"
echo "11. CONFIG LOCATION FILE TREE"
echo "============================================================"

find \
    /opt/config-location \
    -maxdepth 4 \
    -type f \
    -printf '%p\n' \
    2>/dev/null \
    | sort \
    || true

echo


echo "============================================================"
echo "12. IMPORTANT PROJECT HASHES"
echo "============================================================"

find \
    /opt/config-location/app \
    -type f \
    -name '*.py' \
    -print0 \
    2>/dev/null \
    | sort -z \
    | xargs -0 -r sha256sum

echo


echo "============================================================"
echo "13. CONFIG STORE"
echo "============================================================"

CONFIG_DIR="/var/lib/config-location/configs"

if [ -d "$CONFIG_DIR" ]; then

    echo "Config files:"
    find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.json' | wc -l

    echo
    echo "Config directory:"
    du -sh "$CONFIG_DIR" 2>/dev/null || true

else

    echo "CONFIG DIRECTORY NOT FOUND"

fi

echo


echo "============================================================"
echo "14. SOURCES"
echo "============================================================"

find \
    /var/lib/config-location/sources \
    -maxdepth 2 \
    -type f \
    -print \
    2>/dev/null \
    || true

echo

if [ -f /var/lib/config-location/sources/sources.json ]; then

    echo "----- sources.json summary -----"

    jq '
      if type == "array" then
        {
          type: "array",
          total: length,
          enabled: ([.[] | select(.enabled == true)] | length),
          disabled: ([.[] | select(.enabled == false)] | length)
        }
      elif type == "object" then
        {
          type: "object",
          keys: keys
        }
      else
        {
          type: type
        }
      end
    ' /var/lib/config-location/sources/sources.json 2>&1 || true

fi

echo


echo "============================================================"
echo "15. DATA TREE"
echo "============================================================"

find \
    /var/lib/config-location \
    -maxdepth 3 \
    -type d \
    -printf '%p\n' \
    2>/dev/null \
    | sort \
    || true

echo


echo "============================================================"
echo "16. DATA OWNERSHIP"
echo "============================================================"

find \
    /opt/config-location \
    /etc/config-location \
    /var/lib/config-location \
    /var/log/config-location \
    -maxdepth 2 \
    -printf '%u:%g %m %p\n' \
    2>/dev/null \
    | head -n 500 \
    || true

echo


echo "============================================================"
echo "17. ENVIRONMENT / SETTINGS"
echo "============================================================"

for f in \
    /etc/config-location/panel.env \
    /etc/config-location/config-location/project.env \
    /etc/config-location/config-location/settings.json
do

    echo
    echo "----- $f -----"

    if [ -f "$f" ]; then

        sed \
            -E \
            's/(PASSWORD|SECRET|TOKEN|KEY)=.*/\1=***REDACTED***/I' \
            "$f"

    else

        echo "NOT FOUND"

    fi

done

echo


echo "============================================================"
echo "18. CONFIG LOCATION PROCESSES"
echo "============================================================"

ps -eo \
    user,pid,ppid,%cpu,%mem,lstart,cmd \
    | grep '[c]onfig-location' \
    || true

echo


echo "============================================================"
echo "19. PYTHON"
echo "============================================================"

python3 --version 2>&1 || true

if [ -x /opt/config-location/venv/bin/python ]; then

    /opt/config-location/venv/bin/python --version 2>&1 || true

    echo
    /opt/config-location/venv/bin/pip freeze 2>&1 || true

fi

echo


echo "============================================================"
echo "20. PROJECT SYNTAX CHECK - READ ONLY"
echo "============================================================"

if [ -d /opt/config-location/app ]; then

    /opt/config-location/venv/bin/python \
        -m compileall \
        -q \
        /opt/config-location/app \
        2>&1

    RC=$?

    echo "compileall_exit_code=$RC"

else

    echo "PROJECT APP DIRECTORY NOT FOUND"

fi

echo


echo "============================================================"
echo "21. RECENT SERVICE LOGS"
echo "============================================================"

echo
echo "----- FETCHER -----"

journalctl \
    -u config-location-fetcher.service \
    -n 120 \
    --no-pager \
    2>&1 || true

echo
echo "----- PANEL -----"

journalctl \
    -u config-location-panel.service \
    -n 120 \
    --no-pager \
    2>&1 || true

echo


echo "============================================================"
echo "22. OTHER PROJECT SERVICES"
echo "============================================================"

systemctl \
    list-units \
    --type=service \
    --state=running \
    --no-pager \
    2>&1 || true

echo


echo "============================================================"
echo "23. POTENTIAL CONFIG LOCATION NAME COLLISIONS"
echo "============================================================"

find \
    /etc/systemd/system \
    /opt \
    /etc \
    /var/lib \
    -maxdepth 4 \
    -iname '*config-location*' \
    -print \
    2>/dev/null \
    | head -n 500 \
    || true

echo


echo "============================================================"
echo "24. BASELINE COMPLETE"
echo "============================================================"

echo "AUDIT_FILE=$OUT"
echo
echo "HT0 READ-ONLY AUDIT FINISHED."
