#!/bin/bash

set -e

OUT="/root/real-tree-report-$(date +%Y%m%d-%H%M%S).tar.zst"

DIR=$(ls -td /root/aop/real-tree-report-* | head -1)

echo "Using:"
echo "$DIR"


tar -cf - \
-C "$(dirname "$DIR")" \
"$(basename "$DIR")" \
| zstd -15 -T0 -o "$OUT"


sha256sum "$OUT" > "$OUT.sha256"


echo
echo "DONE"
ls -lh "$OUT"
echo "$OUT.sha256"

