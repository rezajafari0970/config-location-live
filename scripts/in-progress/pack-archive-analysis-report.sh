#!/bin/bash

set -e

OUT="/root/archive-analysis-report-$(date +%Y%m%d-%H%M%S).tar.zst"

echo "Packing archive analysis reports..."


tar -cf - \
-C /root/aop \
$(find /root/aop -maxdepth 1 -type d -name "archive-structure-analysis-*" -printf "%f\n") \
| zstd -15 -T0 -o "$OUT"


sha256sum "$OUT" > "$OUT.sha256"


echo
echo "DONE"
ls -lh "$OUT"
echo "$OUT.sha256"

