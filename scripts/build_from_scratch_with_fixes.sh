#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MPS_DIR="$ROOT_DIR/testing-dependencies/mod_pagespeed"
TOOLS_DIR="$SCRIPT_DIR/.scratch-tools"
PY_PREFIX="$TOOLS_DIR/python2"
GPERF_PREFIX="$TOOLS_DIR/gperf"
LOCAL_BIN="$MPS_DIR/.local-bin"
JOBS="${JOBS:-$(nproc)}"

log() {
  printf '[build-fix] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for c in git curl tar make gcc g++ rsync; do
  require_cmd "$c"
done

if [ ! -d "$ROOT_DIR/.git" ]; then
  echo "This script must be run inside a git checkout." >&2
  exit 1
fi

log "Initializing top-level submodules"
git -C "$ROOT_DIR" submodule update --init \
  testing-dependencies/mod_pagespeed \
  testing-dependencies/ngx_cache_purge \
  testing-dependencies/nginx \
  testing-dependencies/set-misc-nginx-module \
  testing-dependencies/ngx_devel_kit \
  testing-dependencies/headers-more-nginx-module \
  testing-dependencies/ngx_psol

if [ ! -f "$MPS_DIR/.gitmodules" ]; then
  echo "Missing $MPS_DIR/.gitmodules" >&2
  exit 1
fi

log "Rewriting legacy git:// Apache submodule URLs to https:// mirrors"
git -C "$MPS_DIR" config -f .gitmodules submodule.third_party/apr/src.url "https://github.com/apache/apr.git"
git -C "$MPS_DIR" config -f .gitmodules submodule.third_party/aprutil/src.url "https://github.com/apache/apr-util.git"
git -C "$MPS_DIR" config -f .gitmodules submodule.third_party/httpd/src.url "https://github.com/apache/httpd.git"
git -C "$MPS_DIR" config -f .gitmodules submodule.third_party/httpd24/src.url "https://github.com/apache/httpd.git"
git -C "$MPS_DIR" config -f .gitmodules submodule.third_party/serf/src.url "https://github.com/apache/serf.git"

git -C "$MPS_DIR" submodule sync --recursive

log "Initializing recursive mod_pagespeed submodules"
if ! git -C "$MPS_DIR" submodule update --init --recursive; then
  log "Recursive submodule fetch hit legacy nested issues; retrying one level only"
  git -C "$MPS_DIR" submodule update --init
fi

GRPC_LOG_LINUX="$MPS_DIR/third_party/grpc/src/src/core/lib/support/log_linux.c"
if [ -f "$GRPC_LOG_LINUX" ] && grep -q 'static long gettid(void)' "$GRPC_LOG_LINUX"; then
  log "Patching gRPC gettid conflict for modern glibc"
  sed -i 's/static long gettid(void)/static long grpc_gettid(void)/' "$GRPC_LOG_LINUX"
  sed -i 's/tid = gettid()/tid = grpc_gettid()/g' "$GRPC_LOG_LINUX"
fi

APR_SIGNALS_C="$MPS_DIR/third_party/apr/src/threadproc/unix/signals.c"
if [ -f "$APR_SIGNALS_C" ] && grep -q 'sys_siglist\[signum\]' "$APR_SIGNALS_C"; then
  log "Patching APR sys_siglist compatibility for modern glibc"
  sed -i 's/sys_siglist\[signum\]/strsignal(signum)/g' "$APR_SIGNALS_C"
fi

mkdir -p "$TOOLS_DIR" "$LOCAL_BIN"

if [ ! -x "$PY_PREFIX/bin/python2.7" ]; then
  log "Bootstrapping Python 2.7.18 locally"
  cd "$TOOLS_DIR"
  if [ ! -f Python-2.7.18.tgz ]; then
    curl -fL -o Python-2.7.18.tgz https://www.python.org/ftp/python/2.7.18/Python-2.7.18.tgz
  fi
  if [ ! -d Python-2.7.18 ]; then
    tar -xzf Python-2.7.18.tgz
  fi
  cd Python-2.7.18
  ./configure --prefix="$PY_PREFIX" --enable-shared --without-ensurepip
  make -j"$JOBS"
  make install
fi

if [ ! -x "$GPERF_PREFIX/bin/gperf" ]; then
  log "Bootstrapping gperf 3.1 locally"
  cd "$TOOLS_DIR"
  if [ ! -f gperf-3.1.tar.gz ]; then
    curl -fL -o gperf-3.1.tar.gz https://ftp.gnu.org/pub/gnu/gperf/gperf-3.1.tar.gz
  fi
  if [ ! -d gperf-3.1 ]; then
    tar -xzf gperf-3.1.tar.gz
  fi
  cd gperf-3.1
  ./configure --prefix="$GPERF_PREFIX"
  make -j"$JOBS"
  make install
fi

ln -sf "$PY_PREFIX/bin/python2.7" "$LOCAL_BIN/python"

export PATH="$GPERF_PREFIX/bin:$LOCAL_BIN:$PATH"
export LD_LIBRARY_PATH="$PY_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$PY_PREFIX/lib:${LIBRARY_PATH:-}"

log "Running PSOL build with local toolchain fixes"
cd "$MPS_DIR"
install/build_psol.sh --skip_deps --skip_tests

TARBALL_PATH="$(ls -1t psol-*.tar.gz 2>/dev/null | head -n 1 || true)"
if [ -z "$TARBALL_PATH" ]; then
  echo "PSOL tarball was not generated (expected psol-*.tar.gz)." >&2
  exit 1
fi

log "Build completed."
log "PSOL tarball: $MPS_DIR/$TARBALL_PATH"
log "Toolchain path: $TOOLS_DIR"
