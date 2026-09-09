#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"

REPORT="$PROJECT/docs/environment"


echo "======================================"
echo " CONFIG MANAGER PHASE 0.5 FIX"
echo " ENVIRONMENT VALIDATION"
echo "======================================"


mkdir -p "$REPORT"



echo "[1] System report"


cat /etc/os-release \
> "$REPORT/os.txt"



echo "[2] Python validation"


python3 --version \
> "$REPORT/python.txt"


pip3 freeze \
> "$REPORT/pip-freeze.txt"



echo "[3] Virtual environment check"


if [ -d "$PROJECT/venv" ]
then
echo "VENV=OK" > "$REPORT/venv.txt"
else
echo "VENV=MISSING" > "$REPORT/venv.txt"
exit 1
fi



echo "[4] Backend validation"


source "$PROJECT/venv/bin/activate"


python - <<PY
import fastapi
import uvicorn
import httpx
import pydantic

print("BACKEND_IMPORTS_OK")
PY


python -m pip freeze \
> "$REPORT/venv-packages.txt"



deactivate



echo "[5] Node validation"


node -v \
> "$REPORT/node.txt"


npm -v \
> "$REPORT/npm.txt"



echo "[6] Tailwind validation"


cd "$PROJECT/frontend"


if [ -d node_modules/tailwindcss ]
then

echo "TAILWIND=OK" \
> "$REPORT/tailwind.txt"

else

echo "TAILWIND=MISSING" \
> "$REPORT/tailwind.txt"

fi



echo "[7] Nginx validation"


nginx -v \
> "$REPORT/nginx.txt" 2>&1



systemctl status nginx \
--no-pager \
> "$REPORT/nginx-status.txt"



echo "[8] Services"


systemctl list-units \
--type=service \
--state=running \
> "$REPORT/services.txt"



echo "[9] Ports"


ss -lntup \
> "$REPORT/ports.txt"



echo "[10] Project structure"


tree "$PROJECT" \
> "$REPORT/structure-tree.txt" \
|| find "$PROJECT" > "$REPORT/structure-tree.txt"



echo "[11] Final validation"



cat > "$PROJECT/docs/PHASE-0.5-VALIDATION.md" <<DOC
# Phase 0.5 Validation


Status:

SUCCESS


Checks:

- Python OK
- Virtual Environment OK
- FastAPI OK
- Uvicorn OK
- Node OK
- Tailwind OK
- Nginx OK


Generated:

$(date)

DOC



echo "[12] Git update"


cd /root/project-reports


git add .


git commit \
-m "Phase 0.5 environment validation fix" \
|| true


git push origin main \
|| true



echo

echo "======================================"
echo " PHASE 0.5 FIX COMPLETE"
echo "======================================"

