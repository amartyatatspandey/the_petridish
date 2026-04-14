#!/usr/bin/env bash
set -euo pipefail

echo "[hygiene] Checking for CRLF in tracked text files..."
if git grep -I -n $'\r' -- . ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.webp' ':!*.tar.gz'; then
  echo "[hygiene] ERROR: CRLF detected in tracked text files."
  exit 1
fi

echo "[hygiene] Checking for forbidden tracked artifacts..."
if git ls-files | grep -E '^honeypot-project/infra/\.cache/|^\.DS_Store$|__pycache__/|\.pyc$'; then
  echo "[hygiene] ERROR: forbidden generated/local artifacts are tracked."
  exit 1
fi

echo "[hygiene] OK"
