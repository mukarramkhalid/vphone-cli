#!/bin/zsh
# setup_tools.sh — Install all required host tools for vphone-cli
#
# Installs brew packages, builds trustcache from source,
# clones insert_dylib, builds libimobiledevice toolchain, and creates Python venv.
#
# Run: make setup_tools

set -euo pipefail

SCRIPT_DIR="${0:a:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TOOLS_PREFIX="${TOOLS_PREFIX:-$PROJECT_DIR/.tools}"

clone_or_update() {
    local url="$1"
    local dir="$2"

    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" fetch --depth 1 origin --quiet
        git -C "$dir" reset --hard FETCH_HEAD --quiet
        git -C "$dir" clean -fdx --quiet
    else
        git clone --depth 1 "$url" "$dir" --quiet
    fi
}

# ── Brew packages ──────────────────────────────────────────────

echo "[1/5] Checking brew packages..."

BREW_PACKAGES=(gnu-tar openssl@3 ldid-procursus sshpass)
BREW_MISSING=()

for pkg in "${BREW_PACKAGES[@]}"; do
    if ! brew list "$pkg" &>/dev/null; then
        BREW_MISSING+=("$pkg")
    fi
done

if ((${#BREW_MISSING[@]} > 0)); then
    echo "  Installing: ${BREW_MISSING[*]}"
    brew install "${BREW_MISSING[@]}"
else
    echo "  All brew packages installed"
fi

# ── Trustcache ─────────────────────────────────────────────────

echo "[2/5] trustcache"

TRUSTCACHE_BIN="$TOOLS_PREFIX/bin/trustcache"
if [[ -x "$TRUSTCACHE_BIN" ]]; then
    echo "  Already built: $TRUSTCACHE_BIN"
else
    echo "  Building from source (CRKatri/trustcache)..."
    BUILD_DIR=$(mktemp -d)
    trap "rm -rf '$BUILD_DIR'" EXIT

    git clone --depth 1 https://github.com/CRKatri/trustcache.git "$BUILD_DIR/trustcache" --quiet

    OPENSSL_PREFIX="$(brew --prefix openssl@3)"
    make -C "$BUILD_DIR/trustcache" \
        OPENSSL=1 \
        CFLAGS="-I$OPENSSL_PREFIX/include -DOPENSSL -w" \
        LDFLAGS="-L$OPENSSL_PREFIX/lib" \
        -j"$(sysctl -n hw.logicalcpu)" >/dev/null 2>&1

    mkdir -p "$TOOLS_PREFIX/bin"
    cp "$BUILD_DIR/trustcache/trustcache" "$TRUSTCACHE_BIN"
    echo "  Installed: $TRUSTCACHE_BIN"
fi

# ── insert_dylib ───────────────────────────────────────────────

echo "[3/5] insert_dylib"

INSERT_DYLIB_BIN="$TOOLS_PREFIX/bin/insert_dylib"
if [[ -x "$INSERT_DYLIB_BIN" ]]; then
    echo "  Already built: $INSERT_DYLIB_BIN"
else
    INSERT_DYLIB_DIR="$TOOLS_PREFIX/src/insert_dylib"
    mkdir -p "${INSERT_DYLIB_DIR:h}"
    clone_or_update "https://github.com/tyilo/insert_dylib" "$INSERT_DYLIB_DIR"
    echo "  Building insert_dylib..."
    mkdir -p "$TOOLS_PREFIX/bin"
    clang -o "$INSERT_DYLIB_BIN" "$INSERT_DYLIB_DIR/insert_dylib/main.c" -framework Security -O2
    echo "  Installed: $INSERT_DYLIB_BIN"
fi

# ── Libimobiledevice ──────────────────────────────────────────

echo "[4/5] libimobiledevice"
bash "$SCRIPT_DIR/setup_libimobiledevice.sh"

# ── Python venv ────────────────────────────────────────────────

echo "[5/5] Python venv"
zsh "$SCRIPT_DIR/setup_venv.sh"

echo ""
echo "All tools installed."
