#!/bin/bash
# Check the installed app's data state (downloads, persisted torrents, verified sidecar).
# Usage: check_app_state.sh <simulator-udid> [bundle-id]
set -e
UDID="${1:?usage: check_app_state.sh <simulator-udid> [bundle-id]}"
BUNDLE="${2:-com.stupidtech.stupid-torrent-client}"

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)
if [ -z "$DATA" ]; then
  echo "app '$BUNDLE' not installed on $UDID"
  exit 1
fi
echo "container: $DATA"
echo
echo "=== Documents/torrents (restored .torrent files) ==="
ls -la "$DATA/Documents/torrents/" 2>/dev/null || echo "(none)"
echo
echo "=== Documents/downloads (data + resume sidecars) ==="
ls -la "$DATA/Documents/downloads/" 2>/dev/null || echo "(none)"
echo
echo "=== verified sidecars (bits set / total pieces) ==="
shopt -s nullglob
for f in "$DATA"/Documents/downloads/.*.verified; do
  python3 -c "
import struct, sys
d = open('$f','rb').read()
if len(d) < 4: print('$f: too small'); sys.exit(0)
c = struct.unpack('>I', d[:4])[0]
print(f'{sys.argv[1]}: {sum(bin(b).count(\"1\") for b in d[4:])} / {c} pieces', '(', f'{100*sum(bin(b).count(\"1\") for b in d[4:])/c:.0f}%' if c else '', ')')
" "$f"
done
echo
echo "=== downloads .verified count ==="
echo "look for a .<40-hex-hash>.verified file; 0 bits means resume state was lost"
