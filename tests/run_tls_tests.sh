#!/usr/bin/env bash
# Real-TLS integration test: runs the plugin's network code with real LuaSocket/LuaSec
# against local HTTPS servers (trusted CA, self-signed, hostname mismatch, redirect).
# Requires: luajit, lua-socket, lua-sec, lua-cjson, lua-filesystem, openssl, python3.
#   Debian/Ubuntu: sudo apt install luajit lua-socket lua-sec lua-cjson lua-filesystem
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/../paperless.koplugin"
for port in 8443 8444 8446; do
  if python3 -c "import socket,sys; s=socket.socket(); sys.exit(s.connect_ex(('127.0.0.1',$port))!=0)"; then
    echo "Port $port is already in use; stop whatever is listening there first." >&2; exit 1
  fi
done
D="$(mktemp -d)"
trap 'kill $SRV 2>/dev/null || true; rm -rf "$D"' EXIT
cd "$D"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=Test CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=localhost" 2>/dev/null
printf "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\n" > ext.cnf
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile ext.cnf 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout self.key -out self.pem -days 2 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
python3 -I "$HERE/tls_server.py" "$D" > server.log 2>&1 &
SRV=$!
sleep 1.5
luajit "$HERE/tls_integration.lua" "$PLUGIN" "$D"
echo "Requests that reached the servers (secrets must only appear for x=2 and the first redirect hop):"
cat "$D/hits.log"
if grep -q "/steal" "$D/hits.log"; then echo "FAIL: redirect leaked headers"; exit 1; fi
