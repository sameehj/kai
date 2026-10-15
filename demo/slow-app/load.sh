#!/usr/bin/env bash
set -euo pipefail

API_URL="${API_URL:-http://localhost:8081}"
WEB_URL="${WEB_URL:-http://localhost:8080}"

printf "Seeding Redis keys via API...\n"
curl -sf "${API_URL}/seed?n=5000" && echo

printf "Generating load against web...\n"
for i in $(seq 1 200); do
  t0=$(date +%s%3N)
  body=$(curl -sf "${WEB_URL}/")
  t1=$(date +%s%3N)
  printf "%03d latency_ms=%d %s\n" "$i" "$((t1-t0))" "$body"
  sleep 0.05
done
