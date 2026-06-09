#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${SESSION_MANAGER_VENDOR_DIR:-$ROOT_DIR/Vendor/CodexMM}"
STAGING_DIR="${SESSION_MANAGER_STAGING_DIR:-$ROOT_DIR/.build/session-manager}"
OUTPUT_DIR="${1:-}"

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "usage: $0 <session-manager-output-dir>" >&2
  exit 1
fi

if [[ ! -d "$VENDOR_DIR" ]]; then
  echo "error: vendored CodexMM directory not found: $VENDOR_DIR" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to build the bundled session manager." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm is required to build the bundled session manager." >&2
  exit 1
fi

if [[ -n "${SESSION_MANAGER_NODE_BIN:-}" ]]; then
  NODE_BIN="$SESSION_MANAGER_NODE_BIN"
else
  NODE_BIN="$(node -p 'process.execPath')"
fi

if [[ ! -x "$NODE_BIN" ]]; then
  echo "error: node runtime is not executable: $NODE_BIN" >&2
  exit 1
fi

STAGING_SOURCE_DIR="$STAGING_DIR/source"
APP_OUTPUT_DIR="$OUTPUT_DIR/App"
RUNTIME_OUTPUT_DIR="$OUTPUT_DIR/Runtime"

rm -rf "$STAGING_DIR" "$OUTPUT_DIR"
mkdir -p "$STAGING_SOURCE_DIR" "$APP_OUTPUT_DIR" "$RUNTIME_OUTPUT_DIR/bin" "$RUNTIME_OUTPUT_DIR/lib"

rsync -a \
  --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.DS_Store' \
  "$VENDOR_DIR"/ "$STAGING_SOURCE_DIR"/

cd "$STAGING_SOURCE_DIR"
npm ci
npm run build
npm prune --omit=dev

mkdir -p "$APP_OUTPUT_DIR/dist" "$APP_OUTPUT_DIR/node_modules"
rsync -a --delete dist/ "$APP_OUTPUT_DIR/dist/"
rsync -a --delete node_modules/ "$APP_OUTPUT_DIR/node_modules/"
cp package.json "$APP_OUTPUT_DIR/package.json"
cp package-lock.json "$APP_OUTPUT_DIR/package-lock.json"
cp "$NODE_BIN" "$RUNTIME_OUTPUT_DIR/bin/node"
chmod +x "$RUNTIME_OUTPUT_DIR/bin/node"

LIBNODE_NAME="$(otool -L "$NODE_BIN" | awk '$1 ~ /@rpath\/libnode.*\.dylib/ { print $1; exit }' | sed 's#@rpath/##')"
if [[ -n "$LIBNODE_NAME" ]]; then
  NODE_PREFIX="$(dirname "$(dirname "$NODE_BIN")")"
  LIBNODE_SOURCE="$NODE_PREFIX/lib/$LIBNODE_NAME"
  if [[ ! -f "$LIBNODE_SOURCE" ]]; then
    echo "error: node runtime requires $LIBNODE_NAME, but it was not found at $LIBNODE_SOURCE" >&2
    exit 1
  fi
  cp "$LIBNODE_SOURCE" "$RUNTIME_OUTPUT_DIR/lib/$LIBNODE_NAME"
fi

echo "Bundled session manager prepared at: $OUTPUT_DIR"
