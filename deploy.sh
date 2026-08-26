#!/usr/bin/env bash
# Deploys the app to Vercel from git HEAD, not the working tree - so a deploy
# is always provably the committed state, never an uncommitted local edit.
# Deliberately manual: no git connection, no auto-deploy on push. Run this
# by hand, on purpose, after committing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

git show HEAD:index.html > "$BUILD_DIR/index.html"
git show HEAD:supabase-js.2.112.4.js > "$BUILD_DIR/supabase-js.2.112.4.js"

echo "Deploying commit $(git rev-parse --short HEAD) from $BUILD_DIR"
npx --yes vercel@latest deploy "$BUILD_DIR" --prod --yes --project towdah-shop-tracker --token "$(grep '^VERCEL_TOKEN=' .env | cut -d= -f2-)"
