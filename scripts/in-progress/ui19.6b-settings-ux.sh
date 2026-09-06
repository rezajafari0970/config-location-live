#!/usr/bin/env bash
set -Eeuo pipefail

R="/opt/config-location"
PY="$R/venv/bin/python"
MOD="$R/app/health/panel_adaptive.py"
PANEL="config-location-panel.service"
B="/root/ui19.6b-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$B"

echo "============================================================"
echo " UI19.6B — SETTINGS UX CLEANUP"
echo "============================================================"

test -f "$MOD"
systemctl is-active "$PANEL"
grep -q 'def validate_policy' "$MOD"
grep -q 'async def adaptive_post' "$MOD"
grep -q 'ADAPTIVE_HTML' "$MOD"

cp -a "$MOD" "$B/panel_adaptive.py"
echo "BACKUP=$B/panel_adaptive.py"

rollback() {
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "===== AUTO ROLLBACK ====="
    cp -a "$B/panel_adaptive.py" "$MOD"
    "$PY" -m py_compile "$MOD" || true
    systemctl restart "$PANEL" || true
    echo "[ROLLBACK] Original Adaptive UI restored"
  fi
  return "$RC"
}
trap rollback EXIT

BACKEND_BEFORE="$("$PY" - "$MOD" <<'PY'
from pathlib import Path
import hashlib,sys
s=Path(sys.argv[1]).read_text(encoding="utf-8")
prefix=s.split("ADAPTIVE_HTML =",1)[0]
print(hashlib.sha256(prefix.encode()).hexdigest())
PY
)"
echo "BACKEND_BEFORE=$BACKEND_BEFORE"

export UI19_HTML_B64='PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImZhIiBkaXI9InJ0bCI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJ1dGYtOCI+CjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPtiq2YbYuNuM2YXYp9iqIEhlYWx0aCBBZGFwdGl2ZTwvdGl0bGU+CjxzdHlsZT4KOnJvb3R7LS1vcmFuZ2U6I2Y5NzMxNjstLW9yYW5nZS1kYXJrOiNjMjQxMGM7LS1vcmFuZ2Utc29mdDojZmZmN2VkOy0tZ3JlZW46IzE2YTM0YTstLXJlZDojZGMyNjI2Oy0tYmc6I2Y4ZmFmYzstLWNhcmQ6I2ZmZjstLWJvcmRlcjojZTJlOGYwOy0tdGV4dDojMGYxNzJhOy0tbXV0ZWQ6IzY0NzQ4Yn0KKntib3gtc2l6aW5nOmJvcmRlci1ib3h9CmJvZHl7bWFyZ2luOjA7Zm9udC1mYW1pbHk6QXJpYWwsVGFob21hLHNhbnMtc2VyaWY7YmFja2dyb3VuZDp2YXIoLS1iZyk7Y29sb3I6dmFyKC0tdGV4dCk7ZGlyZWN0aW9uOnJ0bH0KLndyYXB7bWF4LXdpZHRoOjExMDBweDttYXJnaW46YXV0bztwYWRkaW5nOjE0cHh9Ci50b3B7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTBweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tYm90dG9tOjE0cHh9Ci50b3AgaDJ7bWFyZ2luOjA7Zm9udC1zaXplOjIwcHh9Ci5uYXZ7ZGlzcGxheTpmbGV4O2dhcDo3cHg7ZmxleC13cmFwOndyYXB9Ci5idXR0b24sYnV0dG9ue2Rpc3BsYXk6aW5saW5lLWJsb2NrO2JvcmRlcjowO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6MTBweCAxNHB4O2JhY2tncm91bmQ6dmFyKC0tb3JhbmdlKTtjb2xvcjojZmZmO3RleHQtZGVjb3JhdGlvbjpub25lO2N1cnNvcjpwb2ludGVyO2ZvbnQtd2VpZ2h0OjcwMDtmb250LXNpemU6MTNweH0KLmJ1dHRvbi5zZWNvbmRhcnl7YmFja2dyb3VuZDojNjQ3NDhifQouY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItdG9wOjNweCBzb2xpZCB2YXIoLS1vcmFuZ2UpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHg7bWFyZ2luLWJvdHRvbToxMnB4O2JveC1zaGFkb3c6MCAxcHggMnB4IHJnYmEoMTUsMjMsNDIsLjA0KX0KLmNhcmQgaDN7bWFyZ2luOjAgMCAxMnB4O2ZvbnQtc2l6ZToxNnB4fQouZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOnJlcGVhdChhdXRvLWZpdCxtaW5tYXgoMTkwcHgsMWZyKSk7Z2FwOjEwcHh9CmxhYmVse2Rpc3BsYXk6YmxvY2s7Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NXB4fQouaGVscHtkaXNwbGF5OmJsb2NrO2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTFweDtsaW5lLWhlaWdodDoxLjY7bWFyZ2luLXRvcDo1cHh9CmlucHV0e3dpZHRoOjEwMCU7Ym9yZGVyOjFweCBzb2xpZCAjY2JkNWUxO2JhY2tncm91bmQ6I2ZmZjtjb2xvcjp2YXIoLS10ZXh0KTtwYWRkaW5nOjEwcHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjE0cHg7ZGlyZWN0aW9uOmx0cjt0ZXh0LWFsaWduOmxlZnR9CmlucHV0OmZvY3Vze291dGxpbmU6MnB4IHNvbGlkIHJnYmEoMjQ5LDExNSwyMiwuMTgpO2JvcmRlci1jb2xvcjp2YXIoLS1vcmFuZ2UpfQouc3RhdHVzLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoYXV0by1maXQsbWlubWF4KDE0MHB4LDFmcikpO2dhcDo4cHh9Ci5zdGF0e2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyLXJhZGl1czo5cHg7cGFkZGluZzoxMHB4O3RleHQtYWxpZ246Y2VudGVyO2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTJweH0KLnN0YXQgc3Ryb25ne2Rpc3BsYXk6YmxvY2s7Y29sb3I6dmFyKC0tdGV4dCk7Zm9udC1zaXplOjE2cHg7bWFyZ2luLWJvdHRvbTo0cHg7d29yZC1icmVhazpicmVhay13b3JkfQoubm90aWNle2JhY2tncm91bmQ6dmFyKC0tb3JhbmdlLXNvZnQpO2JvcmRlcjoxcHggc29saWQgI2ZlZDdhYTtjb2xvcjojOWEzNDEyO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweDtmb250LXNpemU6MTJweDtsaW5lLWhlaWdodDoxLjg7bWFyZ2luLWJvdHRvbToxMnB4fQoubm90aWNlLmRhbmdlcntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyLWNvbG9yOiNmZWNhY2E7Y29sb3I6Izk5MWIxYn0KI21zZ3tkaXNwbGF5OmJsb2NrO21hcmdpbi10b3A6MTBweDtmb250LXNpemU6MTNweDtmb250LXdlaWdodDo3MDB9Ci5va3tjb2xvcjp2YXIoLS1ncmVlbil9IC5iYWR7Y29sb3I6dmFyKC0tcmVkKX0KZGV0YWlsc3ttYXJnaW4tdG9wOjEwcHh9IHN1bW1hcnl7Y3Vyc29yOnBvaW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLW9yYW5nZS1kYXJrKX0KcHJle3doaXRlLXNwYWNlOnByZS13cmFwO3dvcmQtYnJlYWs6YnJlYWstd29yZDtkaXJlY3Rpb246bHRyO3RleHQtYWxpZ246bGVmdDtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO3BhZGRpbmc6MTBweDtib3JkZXItcmFkaXVzOjhweDttYXgtaGVpZ2h0OjMyMHB4O292ZXJmbG93OmF1dG87Zm9udC1zaXplOjExcHh9CkBtZWRpYShtYXgtd2lkdGg6NzIwcHgpey53cmFwe3BhZGRpbmc6OXB4fS5ncmlkLC5zdGF0dXMtZ3JpZHtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDIsbWlubWF4KDAsMWZyKSk7Z2FwOjdweH0uY2FyZHtwYWRkaW5nOjExcHh9LmJ1dHRvbixidXR0b257cGFkZGluZzo5cHggMTFweH19Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9IndyYXAiPgo8ZGl2IGNsYXNzPSJ0b3AiPjxoMj7YqtmG2LjbjNmF2KfYqiBIZWFsdGggQWRhcHRpdmU8L2gyPjxkaXYgY2xhc3M9Im5hdiI+PGEgY2xhc3M9ImJ1dHRvbiBzZWNvbmRhcnkiIGhyZWY9Ii8iPtio2KfYstqv2LTYqiDYqNmHINm+2YbZhDwvYT48YSBjbGFzcz0iYnV0dG9uIHNlY29uZGFyeSIgaHJlZj0iL2xpZmVjeWNsZSI+2LPZhNin2YXYqiAvINqG2LHYrtmHINi52YXYsTwvYT48L2Rpdj48L2Rpdj4KPGRpdiBjbGFzcz0iY2FyZCI+PGgzPtmI2LbYuduM2Kog2YTYrdi42YfigIzYp9uMPC9oMz48ZGl2IGlkPSJydW50aW1lIiBjbGFzcz0ic3RhdHVzLWdyaWQiPjxkaXYgY2xhc3M9InN0YXQiPjxzdHJvbmc+Li4uPC9zdHJvbmc+2K/YsSDYrdin2YQg2K/YsduM2KfZgdiqPC9kaXY+PC9kaXY+PC9kaXY+CjxkaXYgY2xhc3M9Im5vdGljZSI+2KrYutuM24zYsdin2Kog2KfbjNmGINi12YHYrdmHINm+2LMg2KfYsiDYsNiu24zYsdmHINiq2YjYs9i3IEhlYWx0aCBBZGFwdGl2ZSBEYWVtb24g2KjZh+KAjNi12YjYsdiqIEhvdCBSZWxvYWQg2KfYudmF2KfZhCDZhduM4oCM2LTZiNmG2K8uINmF2YLYp9iv24zYsSDYrtin2LHYrCDYp9iyINmF2K3Yr9mI2K/ZhyDYqtmI2LPYtyBCYWNrZW5kINix2K8g2K7ZiNin2YfZhtivINi02K8uPC9kaXY+Cjxmb3JtIGlkPSJmb3JtIj4KPGRpdiBjbGFzcz0iY2FyZCI+PGgzPldvcmtlctmH2Kc8L2gzPjxkaXYgY2xhc3M9ImdyaWQiPgo8ZGl2PjxsYWJlbD7Yrdiv2KfZgtmEIFdvcmtlcjwvbGFiZWw+PGlucHV0IGlkPSJ3bWluIiB0eXBlPSJudW1iZXIiPjxzcGFuIGNsYXNzPSJoZWxwIj7YrdivINmF2KzYp9iyOiAxINiq2KcgMjAwPC9zcGFuPjwvZGl2Pgo8ZGl2PjxsYWJlbD7YrdivINmG2LHZhSBXb3JrZXI8L2xhYmVsPjxpbnB1dCBpZD0id3NvZnQiIHR5cGU9Im51bWJlciI+PHNwYW4gY2xhc3M9ImhlbHAiPtit2K8g2YXYrNin2LI6IDEg2KrYpyA1MDA8L3NwYW4+PC9kaXY+CjxkaXY+PGxhYmVsPtit2K8g2LPYrtiqIFdvcmtlcjwvbGFiZWw+PGlucHV0IGlkPSJ3aGFyZCIgdHlwZT0ibnVtYmVyIj48c3BhbiBjbGFzcz0iaGVscCI+2KjYp9uM2K8gbWluIOKJpCBzb2Z0IOKJpCBoYXJkINio2KfYtNivLjwvc3Bhbj48L2Rpdj4KPC9kaXY+PC9kaXY+CjxkaXYgY2xhc3M9ImNhcmQiPjxoMz5CYXRjaCDYqti32KjbjNmC24w8L2gzPjxkaXYgY2xhc3M9ImdyaWQiPgo8ZGl2PjxsYWJlbD7Yrdiv2KfZgtmEIEJhdGNoPC9sYWJlbD48aW5wdXQgaWQ9ImJtaW4iIHR5cGU9Im51bWJlciI+PHNwYW4gY2xhc3M9ImhlbHAiPtit2K8g2YXYrNin2LI6IDEg2KrYpyAxMDAwMDwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+2K3Yr9in2qnYq9ixIEJhdGNoPC9sYWJlbD48aW5wdXQgaWQ9ImJtYXgiIHR5cGU9Im51bWJlciI+PHNwYW4gY2xhc3M9ImhlbHAiPtit2K8g2YXYrNin2LI6IDEg2KrYpyA1MDAwMDwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+2LLZhdin2YYg2YfYr9mBINmH2LEgQ3ljbGU8L2xhYmVsPjxpbnB1dCBpZD0iY3ljbGUiIHR5cGU9Im51bWJlciI+PHNwYW4gY2xhc3M9ImhlbHAiPjEwINiq2KcgMzYwMCDYq9in2YbbjNmHPC9zcGFuPjwvZGl2Pgo8L2Rpdj48L2Rpdj4KPGRpdiBjbGFzcz0iY2FyZCI+PGgzPtmF2K3Yp9mB2Lgg2YXZhtin2KjYuSDYs9ix2YjYsTwvaDM+PGRpdiBjbGFzcz0ibm90aWNlIGRhbmdlciI+2KfbjNmGINio2K7YtCBTYWZldHktc2Vuc2l0aXZlINin2LPYqi4g2YXZgtin2K/bjNixIENQVSDYqNin24zYryDYqNmHINiq2LHYqtuM2KggVGFyZ2V0ICZsdDsgTWF4ICZsdDsgQ3JpdGljYWwg2KjYp9i02YbYry48L2Rpdj48ZGl2IGNsYXNzPSJncmlkIj4KPGRpdj48bGFiZWw+Q1BVINmH2K/ZgSAoJSk8L2xhYmVsPjxpbnB1dCBpZD0iY3RhcmdldCIgdHlwZT0ibnVtYmVyIj48c3BhbiBjbGFzcz0iaGVscCI+MTAg2KrYpyA5MDwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+Q1BVINit2K/Yp9qp2KvYsSAoJSk8L2xhYmVsPjxpbnB1dCBpZD0iY21heCIgdHlwZT0ibnVtYmVyIj48c3BhbiBjbGFzcz0iaGVscCI+MjAg2KrYpyA5ODwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+Q1BVINio2K3Ysdin2YbbjCAoJSk8L2xhYmVsPjxpbnB1dCBpZD0iY2NyaXRpY2FsIiB0eXBlPSJudW1iZXIiPjxzcGFuIGNsYXNzPSJoZWxwIj4zMCDYqtinIDEwMDwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+UkFNINix2LLYsdmIIChNQik8L2xhYmVsPjxpbnB1dCBpZD0icmFtIiB0eXBlPSJudW1iZXIiPjxzcGFuIGNsYXNzPSJoZWxwIj4yNTYg2KrYpyA2NTUzNiBNQjwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+2K3Yr9in2qnYq9ixIEZEICglKTwvbGFiZWw+PGlucHV0IGlkPSJmZCIgdHlwZT0ibnVtYmVyIj48c3BhbiBjbGFzcz0iaGVscCI+MTAg2KrYpyA5NTwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+2K3Yr9in2qnYq9ixIFhyYXnZh9in24wgSGVhbHRoPC9sYWJlbD48aW5wdXQgaWQ9InhyYXkiIHR5cGU9Im51bWJlciI+PHNwYW4gY2xhc3M9ImhlbHAiPjEg2KrYpyA1MDA8L3NwYW4+PC9kaXY+CjwvZGl2PjwvZGl2Pgo8ZGl2IGNsYXNzPSJjYXJkIj48aDM+UnVudGltZSDZvtin24zZhzwvaDM+PGRpdiBjbGFzcz0iZ3JpZCI+CjxkaXY+PGxhYmVsPlRpbWVvdXQg2LTYsdmI2Lk8L2xhYmVsPjxpbnB1dCBpZD0ic3RhcnR1cCIgdHlwZT0ibnVtYmVyIj48c3BhbiBjbGFzcz0iaGVscCI+MiDYqtinIDYwINir2KfZhtuM2Yc8L3NwYW4+PC9kaXY+CjxkaXY+PGxhYmVsPlRpbWVvdXQg2K/Yp9mG2YTZiNivPC9sYWJlbD48aW5wdXQgaWQ9ImRvd25sb2FkIiB0eXBlPSJudW1iZXIiPjxzcGFuIGNsYXNzPSJoZWxwIj4yINiq2KcgNjAg2KvYp9mG24zZhzwvc3Bhbj48L2Rpdj4KPGRpdj48bGFiZWw+VGltZW91dCDYotm+2YTZiNivPC9sYWJlbD48aW5wdXQgaWQ9InVwbG9hZCIgdHlwZT0ibnVtYmVyIj48c3BhbiBjbGFzcz0iaGVscCI+MiDYqtinIDYwINir2KfZhtuM2Yc8L3NwYW4+PC9kaXY+CjxkaXY+PGxhYmVsPtiq2LnYr9in2K8gUmV0cnk8L2xhYmVsPjxpbnB1dCBpZD0icmV0cnkiIHR5cGU9Im51bWJlciI+PHNwYW4gY2xhc3M9ImhlbHAiPjAg2KrYpyAxMCDYqNin2LE8L3NwYW4+PC9kaXY+CjwvZGl2PjwvZGl2Pgo8ZGl2IGNsYXNzPSJjYXJkIj48YnV0dG9uIHR5cGU9InN1Ym1pdCI+2LDYrtuM2LHZhyDYqtmG2LjbjNmF2KfYqiBBZGFwdGl2ZTwvYnV0dG9uPjxzcGFuIGlkPSJtc2ciPjwvc3Bhbj48L2Rpdj4KPC9mb3JtPgo8ZGl2IGNsYXNzPSJjYXJkIj48aDM+2KfYt9mE2KfYudin2Kog2YHZhtuMPC9oMz48ZGV0YWlscz48c3VtbWFyeT7ZhtmF2KfbjNi0IEpTT04g2YjYtti524zYqiDaqdin2YXZhDwvc3VtbWFyeT48cHJlIGlkPSJyYXciPjwvcHJlPjwvZGV0YWlscz48L2Rpdj4KPC9kaXY+CjxzY3JpcHQ+CmNvbnN0ICQ9aWQ9PmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKbGV0IGRhdGE9e307CmZ1bmN0aW9uIGdldChwYXRoLGRlZil7bGV0IHg9ZGF0YS5wb2xpY3l8fHt9O2Zvcihjb25zdCBrIG9mIHBhdGgpe3g9KHh8fHt9KVtrXX1yZXR1cm4geCA/PyBkZWZ9CmZ1bmN0aW9uIHNhZmUodixkZWY9J+KAlCcpe3JldHVybiAodj09PXVuZGVmaW5lZHx8dj09PW51bGx8fHY9PT0nJyk/ZGVmOlN0cmluZyh2KX0KZnVuY3Rpb24gcnVudGltZUNhcmQodGl0bGUsdmFsdWUpe3JldHVybiBgPGRpdiBjbGFzcz0ic3RhdCI+PHN0cm9uZz4ke3NhZmUodmFsdWUpfTwvc3Ryb25nPiR7dGl0bGV9PC9kaXY+YH0KYXN5bmMgZnVuY3Rpb24gbG9hZCgpewogY29uc3QgcnVudGltZT0kKCdydW50aW1lJyk7CiB0cnl7CiAgIGNvbnN0IHI9YXdhaXQgZmV0Y2goJy9hcGkvaGVhbHRoL2FkYXB0aXZlJyx7Y2FjaGU6J25vLXN0b3JlJ30pOwogICBpZighci5vaykgdGhyb3cgbmV3IEVycm9yKCdIVFRQICcrci5zdGF0dXMpOwogICBkYXRhPWF3YWl0IHIuanNvbigpOwogICAkKCd3bWluJykudmFsdWU9Z2V0KFsnd29ya2VycycsJ21pbiddLDUpOyAkKCd3c29mdCcpLnZhbHVlPWdldChbJ3dvcmtlcnMnLCdzb2Z0X21heCddLDEwMCk7ICQoJ3doYXJkJykudmFsdWU9Z2V0KFsnd29ya2VycycsJ2hhcmRfbWF4J10sMjAwKTsKICAgJCgnYm1pbicpLnZhbHVlPWdldChbJ2JhdGNoJywnbWluJ10sNTApOyAkKCdibWF4JykudmFsdWU9Z2V0KFsnYmF0Y2gnLCdtYXgnXSwzMDAwKTsgJCgnY3ljbGUnKS52YWx1ZT1nZXQoWydiYXRjaCcsJ3RhcmdldF9jeWNsZV9zZWNvbmRzJ10sMTgwKTsKICAgJCgnY3RhcmdldCcpLnZhbHVlPWdldChbJ3NlcnZlcl9ndWFyZCcsJ3RhcmdldF9jcHVfcGVyY2VudCddLDYwKTsgJCgnY21heCcpLnZhbHVlPWdldChbJ3NlcnZlcl9ndWFyZCcsJ21heF9jcHVfcGVyY2VudCddLDgyKTsgJCgnY2NyaXRpY2FsJykudmFsdWU9Z2V0KFsnc2VydmVyX2d1YXJkJywnY3JpdGljYWxfY3B1X3BlcmNlbnQnXSw5NCk7CiAgICQoJ3JhbScpLnZhbHVlPWdldChbJ3NlcnZlcl9ndWFyZCcsJ3Jlc2VydmVfcmFtX21iJ10sMTUzNik7ICQoJ2ZkJykudmFsdWU9Z2V0KFsnc2VydmVyX2d1YXJkJywnbWF4X2ZkX3BlcmNlbnQnXSw3MCk7ICQoJ3hyYXknKS52YWx1ZT1nZXQoWydzZXJ2ZXJfZ3VhcmQnLCdtYXhfaGVhbHRoX3hyYXknXSwyMDApOwogICAkKCdzdGFydHVwJykudmFsdWU9Z2V0KFsnZXhlY3V0aW9uJywnc3RhcnR1cF90aW1lb3V0J10sNik7ICQoJ2Rvd25sb2FkJykudmFsdWU9Z2V0KFsnZXhlY3V0aW9uJywnZG93bmxvYWRfdGltZW91dCddLDYpOyAkKCd1cGxvYWQnKS52YWx1ZT1nZXQoWydleGVjdXRpb24nLCd1cGxvYWRfdGltZW91dCddLDYpOyAkKCdyZXRyeScpLnZhbHVlPWdldChbJ2V4ZWN1dGlvbicsJ3J1bnRpbWVfcmV0cmllcyddLDMpOwogICBjb25zdCBkYWVtb249ZGF0YS5kYWVtb258fHt9LCBlZmZlY3RpdmU9ZGF0YS5lZmZlY3RpdmV8fHt9LCBsYXN0PWRhdGEubGFzdF9ydW58fHt9OwogICBydW50aW1lLmlubmVySFRNTD1ydW50aW1lQ2FyZCgnRGFlbW9uJyxkYWVtb24uc3RhdGV8fGRhZW1vbi5zdGF0dXN8fCfZhtin2YXYtNiu2LUnKStydW50aW1lQ2FyZCgnV29ya2VyINmF2YjYq9ixJyxlZmZlY3RpdmUud29ya2Vycz8/ZWZmZWN0aXZlLndvcmtlcl9jb3VudD8/ZWZmZWN0aXZlLndvcmtlcj8/J+KAlCcpK3J1bnRpbWVDYXJkKCdCYXRjaCDZhdmI2KvYsScsZWZmZWN0aXZlLmJhdGNoPz9lZmZlY3RpdmUuYmF0Y2hfc2l6ZT8/J+KAlCcpK3J1bnRpbWVDYXJkKCfYotiu2LHbjNmGINmG2KrbjNis2YcnLGxhc3QucmVzdWx0fHxsYXN0LnN0YXRlfHxsYXN0LnN0YXR1c3x8J+KAlCcpOwogICAkKCdyYXcnKS50ZXh0Q29udGVudD1KU09OLnN0cmluZ2lmeShkYXRhLG51bGwsMik7CiB9Y2F0Y2goZXJyKXtydW50aW1lLmlubmVySFRNTD1gPGRpdiBjbGFzcz0ibm90aWNlIGRhbmdlciI+2K/YsduM2KfZgdiqINmI2LbYuduM2KogQWRhcHRpdmUg2YbYp9mF2YjZgdmCINio2YjYrzogJHtzYWZlKGVyci5tZXNzYWdlKX08L2Rpdj5gOyQoJ3JhdycpLnRleHRDb250ZW50PVN0cmluZyhlcnIpfQp9CiQoJ2Zvcm0nKS5hZGRFdmVudExpc3RlbmVyKCdzdWJtaXQnLGFzeW5jIGU9PnsKIGUucHJldmVudERlZmF1bHQoKTsgY29uc3QgbXNnPSQoJ21zZycpOyBtc2cuY2xhc3NOYW1lPScnOyBtc2cudGV4dENvbnRlbnQ9J9iv2LEg2K3Yp9mEINin2LnYqtio2KfYsdiz2YbYrNuMINmIINiw2K7bjNix2YcuLi4nOwogY29uc3QgYm9keT17CiAgIHdvcmtlcnM6e21pbjpOdW1iZXIoJCgnd21pbicpLnZhbHVlKSxzb2Z0X21heDpOdW1iZXIoJCgnd3NvZnQnKS52YWx1ZSksaGFyZF9tYXg6TnVtYmVyKCQoJ3doYXJkJykudmFsdWUpfSwKICAgYmF0Y2g6e21pbjpOdW1iZXIoJCgnYm1pbicpLnZhbHVlKSxtYXg6TnVtYmVyKCQoJ2JtYXgnKS52YWx1ZSksdGFyZ2V0X2N5Y2xlX3NlY29uZHM6TnVtYmVyKCQoJ2N5Y2xlJykudmFsdWUpfSwKICAgc2VydmVyX2d1YXJkOnt0YXJnZXRfY3B1X3BlcmNlbnQ6TnVtYmVyKCQoJ2N0YXJnZXQnKS52YWx1ZSksbWF4X2NwdV9wZXJjZW50Ok51bWJlcigkKCdjbWF4JykudmFsdWUpLGNyaXRpY2FsX2NwdV9wZXJjZW50Ok51bWJlcigkKCdjY3JpdGljYWwnKS52YWx1ZSkscmVzZXJ2ZV9yYW1fbWI6TnVtYmVyKCQoJ3JhbScpLnZhbHVlKSxtYXhfZmRfcGVyY2VudDpOdW1iZXIoJCgnZmQnKS52YWx1ZSksbWF4X2hlYWx0aF94cmF5Ok51bWJlcigkKCd4cmF5JykudmFsdWUpfSwKICAgZXhlY3V0aW9uOntzdGFydHVwX3RpbWVvdXQ6TnVtYmVyKCQoJ3N0YXJ0dXAnKS52YWx1ZSksZG93bmxvYWRfdGltZW91dDpOdW1iZXIoJCgnZG93bmxvYWQnKS52YWx1ZSksdXBsb2FkX3RpbWVvdXQ6TnVtYmVyKCQoJ3VwbG9hZCcpLnZhbHVlKSxydW50aW1lX3JldHJpZXM6TnVtYmVyKCQoJ3JldHJ5JykudmFsdWUpfQogfTsKIHRyeXsKICAgY29uc3Qgcj1hd2FpdCBmZXRjaCgnL2FwaS9oZWFsdGgvYWRhcHRpdmUnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX0pOwogICBsZXQgcmVzcG9uc2U9e307IHRyeXtyZXNwb25zZT1hd2FpdCByLmpzb24oKX1jYXRjaChfKXt9CiAgIGlmKCFyLm9rfHxyZXNwb25zZS5vaz09PWZhbHNlKSB0aHJvdyBuZXcgRXJyb3IocmVzcG9uc2UuZXJyb3J8fHJlc3BvbnNlLm1lc3NhZ2V8fCgnSFRUUCAnK3Iuc3RhdHVzKSk7CiAgIG1zZy5jbGFzc05hbWU9J29rJzsgbXNnLnRleHRDb250ZW50PSfYsNiu24zYsdmHINi02K/YmyBEYWVtb24g2KrZhti424zZhdin2Kog2LHYpyBIb3QgUmVsb2FkINmF24zigIzaqdmG2K8uJzsgYXdhaXQgbG9hZCgpOwogfWNhdGNoKGVycil7bXNnLmNsYXNzTmFtZT0nYmFkJzttc2cudGV4dENvbnRlbnQ9J9iu2LfYpzogJytzYWZlKGVyci5tZXNzYWdlKX0KfSk7CmxvYWQoKTsgc2V0SW50ZXJ2YWwobG9hZCwxNTAwMCk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4='

"$PY" - "$MOD" <<'PY'
from pathlib import Path
import base64, os, re, sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
html=base64.b64decode(os.environ["UI19_HTML_B64"]).decode("utf-8")
patterns=[
    re.compile("ADAPTIVE_HTML\\s*=\\s*r'{3}[\\s\\S]*?'{3}", re.M),
    re.compile('ADAPTIVE_HTML\\s*=\\s*r"{3}[\\s\\S]*?"{3}', re.M),
]
for pat in patterns:
    if pat.search(s):
        s=pat.sub("ADAPTIVE_HTML = r'''"+html+"'''", s, count=1)
        break
else:
    raise SystemExit("[FAIL] ADAPTIVE_HTML literal not found")
p.write_text(s,encoding="utf-8")
print("[PASS] ADAPTIVE_HTML replaced only")
PY

unset UI19_HTML_B64

BACKEND_AFTER="$("$PY" - "$MOD" <<'PY'
from pathlib import Path
import hashlib,sys
s=Path(sys.argv[1]).read_text(encoding="utf-8")
prefix=s.split("ADAPTIVE_HTML =",1)[0]
print(hashlib.sha256(prefix.encode()).hexdigest())
PY
)"
echo "BACKEND_AFTER=$BACKEND_AFTER"
test "$BACKEND_BEFORE" = "$BACKEND_AFTER"
echo "[PASS] Backend unchanged"

cd "$R"
"$PY" -m py_compile app/health/panel_adaptive.py
echo "[PASS] compile"

PYTHONPATH="$R" "$PY" - <<'PY'
from app.health.panel_adaptive import validate_policy, ADAPTIVE_HTML, snapshot
valid=validate_policy({
 "workers":{"min":5,"soft_max":100,"hard_max":200},
 "batch":{"min":50,"max":3000,"target_cycle_seconds":180},
 "server_guard":{"target_cpu_percent":60,"max_cpu_percent":82,"critical_cpu_percent":94,"reserve_ram_mb":1536,"max_fd_percent":70,"max_health_xray":200},
 "execution":{"startup_timeout":6,"download_timeout":6,"upload_timeout":6,"runtime_retries":3}
})
assert valid["workers"]["min"] == 5
try:
    validate_policy({"workers":{"min":200,"soft_max":10,"hard_max":20}})
except ValueError:
    pass
else:
    raise SystemExit("[FAIL] worker validation weakened")
for marker in ('lang="fa"','dir="rtl"','تنظیمات Health Adaptive','محافظ منابع سرور','ذخیره تنظیمات Adaptive','/api/health/adaptive'):
    assert marker in ADAPTIVE_HTML, marker
assert "background:#111827" not in ADAPTIVE_HTML
o=snapshot()
assert all(k in o for k in ("policy","daemon","effective","last_run"))
print("[PASS] validation + UI + snapshot")
PY

systemctl restart "$PANEL"

READY=0
for I in $(seq 1 30); do
  ACTIVE="$(systemctl is-active "$PANEL" 2>/dev/null || true)"
  LISTEN=no
  if ss -lnt | awk '{print $4}' | grep -qE ':4040$'; then LISTEN=yes; fi
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:4040/ 2>/dev/null || true)"
  echo "READY[$I] active=$ACTIVE listen=$LISTEN http=$CODE"
  if [ "$ACTIVE" = active ] && [ "$LISTEN" = yes ]; then
    case "$CODE" in 200|302|303|307|308) READY=1; break;; esac
  fi
  sleep 1
done
test "$READY" = 1
echo "[PASS] Panel ready"

PAGE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:4040/health/adaptive || true)"
API="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:4040/api/health/adaptive || true)"
PUB="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:4040/api/publish/status || true)"
echo "ADAPTIVE_PAGE_HTTP=$PAGE"
echo "ADAPTIVE_API_HTTP=$API"
echo "PUBLISH_HTTP=$PUB"
case "$PAGE" in 200|302|303|307|308|401|403) ;; *) exit 1;; esac
case "$API" in 200|302|303|307|308|401|403) ;; *) exit 1;; esac
test "$PUB" = 200

for S in config-location-panel.service config-location-fetcher.service config-location-health-adaptive.service config-location-lifecycle-sync.service config-location-lifecycle-watchdog.service; do
  X="$(systemctl is-active "$S" 2>/dev/null || true)"
  echo "$S=$X"
  test "$X" = active
done

trap - EXIT

echo "============================================================"
echo " UI19.6B PASS"
echo "============================================================"
echo "ADAPTIVE_UI=EXISTING_PANEL_STYLE"
echo "RTL=YES"
echo "PERSIAN_LABELS=YES"
echo "MOBILE_RESPONSIVE=YES"
echo "VALIDATION_BACKEND=PRESERVED"
echo "HOT_RELOAD_BACKEND=PRESERVED"
echo "POLICY_PATH=PRESERVED"
echo "NEXT=UI19.7_FINAL_PANEL_SOAK"
echo "============================================================"
