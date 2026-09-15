#!/bin/bash

set -e

OUT="/root/config-location-all-reports-$(date +%Y%m%d-%H%M%S).tar.zst"

echo "Packing reports..."

tar -cf - \
-C /root/aop \
$(find /root/aop -maxdepth 1 -type d -name "*report*" -printf "%f\n") \
| zstd -15 -T0 -o "$OUT"

sha256sum "$OUT" > "$OUT.sha256"

echo
echo "DONE"
ls -lh "$OUT"
echo "$OUT.sha256"

