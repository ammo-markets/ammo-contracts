#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONO_CONTRACTS="$(cd "$SCRIPT_DIR/../ammo-exchange/packages/contracts" && pwd)"

if [ ! -d "$MONO_CONTRACTS" ]; then
  echo "Error: monorepo contracts not found at $MONO_CONTRACTS"
  exit 1
fi

rsync -av --delete \
  --exclude='.git' \
  --exclude='node_modules/' \
  --exclude='.turbo/' \
  --exclude='.claude/' \
  --exclude='out/' \
  --exclude='cache/' \
  --exclude='broadcast/' \
  --exclude='.env' \
  --exclude='.env.*' \
  --exclude='package.json' \
  --exclude='src/abis/' \
  --exclude='src/index.ts' \
  --exclude='scripts/' \
  --exclude='tsconfig.json' \
  --exclude='dist/' \
  --exclude='.DS_Store' \
  "$MONO_CONTRACTS/" "$SCRIPT_DIR/" \
  --filter='P .git' \
  --filter='P .gitignore' \
  --filter='P .gitmodules' \
  --filter='P .env.example' \
  --filter='P publish.sh' \
  --filter='P README.md' \
  --filter='P foundry.lock'

echo ""
echo "Synced from monorepo. Review changes:"
echo "  cd $SCRIPT_DIR && git status"
