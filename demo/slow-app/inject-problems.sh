#!/bin/bash
set -euo pipefail

echo "Injecting performance problems..."

if command -v iptables >/dev/null 2>&1; then
  sudo iptables -C OUTPUT -p tcp --dport 5432 -m statistic --mode random --probability 0.05 -j DROP 2>/dev/null || \
    sudo iptables -A OUTPUT -p tcp --dport 5432 -m statistic --mode random --probability 0.05 -j DROP
  echo "✓ 5% packet loss to PostgreSQL"
else
  echo "⚠ iptables not found; skipping packet loss injection"
fi

docker exec -d slow-app-db-1 sh -c 'while true; do dd if=/dev/zero of=/tmp/io_load bs=1M count=100 conv=fsync 2>/dev/null; rm -f /tmp/io_load; sleep 1; done'
echo "✓ I/O pressure injected"

docker exec -d slow-app-app-1 sh -c 'dd if=/dev/urandom of=/dev/null bs=1M'
echo "✓ CPU pressure injected"

echo ""
echo "Problems injected. Run:"
echo "  kai --target local \"my web app is slow, figure out why\""
