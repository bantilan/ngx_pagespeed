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

# Keep PSOL source compatibility fixes with the PSOL build, rather than in the
# outer Nginx/Debian packaging script.
MPS_IMAGE_CC="$MPS_DIR/net/instaweb/rewriter/image.cc"
AVIFENC_QUIET_PATCH_MODE="${AVIFENC_QUIET_PATCH_MODE:-auto}"

patch_avifenc_quiet_flag() {
  if [ -f "$MPS_IMAGE_CC" ] && grep -q 'avifenc --quiet' "$MPS_IMAGE_CC"; then
    sed -i 's/avifenc --quiet --jobs/avifenc --jobs/g' "$MPS_IMAGE_CC"
    log "Removed unsupported avifenc --quiet option from image.cc"
  fi
}

case "$AVIFENC_QUIET_PATCH_MODE" in
  auto)
    if command -v avifenc >/dev/null 2>&1 && \
        ! avifenc --help 2>&1 | grep -q -- '--quiet'; then
      patch_avifenc_quiet_flag
    fi
    ;;
  force) patch_avifenc_quiet_flag ;;
  off) ;;
  *)
    echo "Invalid AVIFENC_QUIET_PATCH_MODE='$AVIFENC_QUIET_PATCH_MODE' (expected: auto|force|off)" >&2
    exit 1
    ;;
esac

has_filter_name() {
  if command -v rg >/dev/null 2>&1; then
    rg -q "$1" "$2"
  else
    grep -q "$1" "$2"
  fi
}

apply_jsbuild_compat_fixes() {
  local closure_gypi="$MPS_DIR/net/instaweb/closure.gypi"
  local instaweb_gyp="$MPS_DIR/net/instaweb/instaweb.gyp"

  # Keep Closure primitive processing enabled; disabling it can break generated JS.
  if [ -f "$closure_gypi" ] && grep -q -- '--process_closure_primitives=false' "$closure_gypi"; then
    sed -i '/--process_closure_primitives=false/d' "$closure_gypi"
    log "Removed unsafe Closure flag --process_closure_primitives=false"
  fi
  if [ -f "$closure_gypi" ] && grep -q -- '--jscomp_off=undefinedVars' "$closure_gypi"; then
    sed -i '/--jscomp_off=undefinedVars/d' "$closure_gypi"
    log "Removed temporary jscomp_off=undefinedVars suppression"
  fi

  if [ -f "$instaweb_gyp" ]; then
    if grep -q '/goog/labs/' "$instaweb_gyp"; then
      sed -i '\|/goog/labs/|d' "$instaweb_gyp"
      log "Removed over-broad goog/labs exclusion in instaweb.gyp"
    fi
    if ! grep -q '/goog/demos/' "$instaweb_gyp"; then
      sed -i '/grep -v _test\.js/a\        '\''           | grep -v "/goog/demos/"'\''\n        '\''           | grep -v "/goog/testing/"'\''\n        '\''           | grep -v "/goog/test_module.js"'\''' "$instaweb_gyp"
      log "Applied JS build compatibility exclusions in instaweb.gyp"
    fi
  fi
}

apply_jsbuild_compat_fixes

REQUIRED_FILTER="${NGX_PAGESPEED_REQUIRED_FILTER:-prioritize_lcp_images}"
if [ -n "$REQUIRED_FILTER" ] && ! has_filter_name \
    "$REQUIRED_FILTER" "$MPS_DIR/net/instaweb/rewriter/rewrite_filter_names.gperf"; then
  echo "Required filter '$REQUIRED_FILTER' not found in mod_pagespeed source." >&2
  echo "Set NGX_PAGESPEED_REQUIRED_FILTER to a source filter name or an empty string to disable this check." >&2
  exit 1
fi

bootstrap_legacy_build_tooling() {
  # Some forks omit legacy checked-in build helpers required by build_psol.sh.
  if [ -x "$MPS_DIR/build/gyp_chromium" ] && [ -d "$MPS_DIR/tools/gyp" ]; then
    return 0
  fi

  local upstream_repo="${MPS_BOOTSTRAP_REPO:-https://github.com/apache/incubator-pagespeed-mod.git}"
  local upstream_ref="${MPS_BOOTSTRAP_REF:-master}"
  local bootstrap_dir="$TOOLS_DIR/.mps-bootstrap-src"

  log "Missing legacy build tooling in mod_pagespeed fork; bootstrapping from $upstream_repo ($upstream_ref)"
  rm -rf "$bootstrap_dir"
  git clone --depth 1 --branch "$upstream_ref" "$upstream_repo" "$bootstrap_dir"
  git -C "$bootstrap_dir" submodule update --init --recursive \
    third_party/chromium/src/build \
    tools/gyp || true

  mkdir -p "$MPS_DIR/build" "$MPS_DIR/tools"

  if [ ! -e "$MPS_DIR/build/gyp_chromium" ] && [ -f "$bootstrap_dir/build/gyp_chromium" ]; then
    cp "$bootstrap_dir/build/gyp_chromium" "$MPS_DIR/build/gyp_chromium"
    chmod +x "$MPS_DIR/build/gyp_chromium"
  fi
  if [ ! -e "$MPS_DIR/build/gyp_helper.py" ] && [ -f "$bootstrap_dir/build/gyp_helper.py" ]; then
    cp "$bootstrap_dir/build/gyp_helper.py" "$MPS_DIR/build/gyp_helper.py"
  fi
  if [ ! -e "$MPS_DIR/build/common.gypi" ] && [ -f "$bootstrap_dir/build/common.gypi" ]; then
    cp "$bootstrap_dir/build/common.gypi" "$MPS_DIR/build/common.gypi"
  fi
  if [ ! -e "$MPS_DIR/tools/gyp" ] && [ -d "$bootstrap_dir/tools/gyp" ]; then
    cp -a "$bootstrap_dir/tools/gyp" "$MPS_DIR/tools/gyp"
  fi
  if [ ! -e "$MPS_DIR/third_party/chromium/src/build" ] && [ -d "$bootstrap_dir/third_party/chromium/src/build" ]; then
    mkdir -p "$MPS_DIR/third_party/chromium/src"
    cp -a "$bootstrap_dir/third_party/chromium/src/build" "$MPS_DIR/third_party/chromium/src/build"
  fi

  if [ ! -x "$MPS_DIR/build/gyp_chromium" ]; then
    echo "Failed to bootstrap build/gyp_chromium into $MPS_DIR" >&2
    exit 1
  fi
}

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

X25519_ASM="$MPS_DIR/third_party/boringssl/src/crypto/curve25519/asm/x25519-asm-x86_64.S"
if [ "$(uname -m)" = x86_64 ] && [ -f "$X25519_ASM" ] && \
    ! grep -q '\.note\.GNU-stack' "$X25519_ASM"; then
  log "Marking BoringSSL X25519 assembly as non-executable-stack"
  printf '\n.section .note.GNU-stack,"",%%progbits\n' >> "$X25519_ASM"
fi

# The bundled OpenSSL RSA assembly is linked into the PSOL archive and also
# needs to declare a non-executable stack for modern GNU linkers.
if [ "$(uname -m)" = x86_64 ]; then
  for asm in \
      "$MPS_DIR/third_party/serf/linux-x86_64/crypto/bn/rsaz-x86_64.S" \
      "$MPS_DIR/third_party/serf/linux-x86_64/crypto/bn/rsaz-avx2.S"; do
    if [ -f "$asm" ] && ! grep -q '\.note\.GNU-stack' "$asm"; then
      log "Marking $(basename "$asm") as non-executable-stack"
      printf '\n.section .note.GNU-stack,"",%%progbits\n' >> "$asm"
    fi
  done
fi

mkdir -p "$TOOLS_DIR" "$LOCAL_BIN"

PYTHON_SOURCE_DIR="$TOOLS_DIR/Python-2.7.18"
NEED_PYTHON_BUILD=0
if [ ! -x "$PY_PREFIX/bin/python2.7" ]; then
  NEED_PYTHON_BUILD=1
elif ! LD_LIBRARY_PATH="$PY_PREFIX/lib:${LD_LIBRARY_PATH:-}" \
    "$PY_PREFIX/bin/python2.7" -c 'import _hashlib' >/dev/null 2>&1; then
  log "Local Python 2 lacks _hashlib; rebuilding it with OpenSSL version detection fixed"
  NEED_PYTHON_BUILD=1
elif [ ! -f "$PY_PREFIX/.python_compat_patches_v2" ]; then
  log "Rebuilding local Python 2 with deprecated APIs disabled or modernized"
  NEED_PYTHON_BUILD=1
fi

if [ "$NEED_PYTHON_BUILD" = "1" ]; then
  log "Preparing local Python 2.7.18 (including _hashlib support)"
  cd "$TOOLS_DIR"
  if [ ! -f Python-2.7.18.tgz ]; then
    curl -fL -o Python-2.7.18.tgz https://www.python.org/ftp/python/2.7.18/Python-2.7.18.tgz
  fi
  if [ ! -d "$PYTHON_SOURCE_DIR" ]; then
    tar -xzf Python-2.7.18.tgz
  fi
  cd "$PYTHON_SOURCE_DIR"

  # Python 2.7 does not parse OpenSSL 3's computed OPENSSL_VERSION_NUMBER.
  python3 - setup.py <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
version_pattern = """        openssl_ver_re = re.compile(
            '^\\s*#\\s*define\\s+OPENSSL_VERSION_NUMBER\\s+(0x[0-9a-fA-F]+)' )"""
version_with_major = version_pattern + """
        openssl_major_re = re.compile(
            '^\\s*#\\s*define\\s+OPENSSL_VERSION_MAJOR\\s+(\\d+)' )"""
if "openssl_major_re = re.compile(" not in text:
    if version_pattern not in text:
        raise SystemExit("Could not find Python 2 OpenSSL version parser to patch")
    text = text.replace(version_pattern, version_with_major, 1)
    old = """                    if m:
                        openssl_ver = eval(m.group(1))"""
    new = """                    if m:
                        openssl_ver = eval(m.group(1))
                    else:
                        m = openssl_major_re.match(line)
                        if m:
                            openssl_ver = int(m.group(1)) << 28"""
    if old not in text:
        raise SystemExit("Could not find Python 2 OpenSSL parser loop to patch")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("Patched Python 2 to recognize OpenSSL 3 version macros.")
PY

  # OpenSSL 3 removed the function field from its error codes and deprecated
  # ERR_func_error_string(). Keep the extra detail on older OpenSSL versions.
  python3 - Modules/_hashopenssl.c <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "    func = ERR_func_error_string(errcode);"
new = """#if OPENSSL_VERSION_NUMBER < 0x30000000L
    func = ERR_func_error_string(errcode);
#else
    func = NULL;
#endif"""
if new not in text and old in text:
    text = text.replace(old, new, 1)
if new not in text:
    raise SystemExit("Could not verify OpenSSL 3 error-function compatibility patch")
path.write_text(text)
print("Avoided deprecated ERR_func_error_string() on OpenSSL 3.")
PY

  # Fix misleading indentation in Python 2's legacy AST source.
  python3 - Python/ast.c <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
replacements = (
    ("            if (!import_alias)\n                return NULL;\n                asdl_seq_SET(aliases, 0, import_alias);",
     "            if (!import_alias)\n                return NULL;\n            asdl_seq_SET(aliases, 0, import_alias);"),
    ("                if (!import_alias)\n                    return NULL;\n                    asdl_seq_SET(aliases, i / 2, import_alias);",
     "                if (!import_alias)\n                    return NULL;\n                asdl_seq_SET(aliases, i / 2, import_alias);"),
)
for old, new in replacements:
    if old in text:
        text = text.replace(old, new, 1)
if any(new not in text for _, new in replacements):
    raise SystemExit("Could not verify Python AST indentation fix")
path.write_text(text)
print("Fixed misleading indentation in Python 2 AST source.")
PY

  # GCC can conservatively report the Expat encoding buffer as uninitialized;
  # zero-initialize it so the legacy source builds cleanly with modern GCC.
  python3 - Modules/expat/xmltok_ns.c <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "  char buf[ENCODING_MAX];"
new = "  char buf[ENCODING_MAX] = {0};"
if old in text:
    text = text.replace(old, new, 1)
if new not in text:
    raise SystemExit("Could not verify Expat encoding-buffer initialization")
path.write_text(text)
print("Initialized Python 2's Expat encoding buffer.")
PY

  # libffi uses these truncations only as best-effort cleanup after mmap fails.
  # Check their status explicitly to satisfy modern warn_unused_result checks.
  python3 - Modules/_ctypes/libffi/src/closures.c <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old1 = "      ftruncate (execfd, offset);\n      return MFAIL;"
new1 = "      if (ftruncate (execfd, offset) < 0) {\n        /* Best-effort cleanup; mmap has already failed. */\n      }\n      return MFAIL;"
old2 = "      ftruncate (execfd, offset);\n      return start;"
new2 = "      if (ftruncate (execfd, offset) < 0) {\n        /* Best-effort cleanup; mmap has already failed. */\n      }\n      return start;"
if old1 in text:
    text = text.replace(old1, new1, 1)
if old2 in text:
    text = text.replace(old2, new2, 1)
if old1 in text or old2 in text or new1 not in text or new2 not in text:
    raise SystemExit("Could not verify libffi ftruncate return-value checks")
path.write_text(text)
print("Checked libffi cleanup ftruncate return values.")
PY

  # siginterrupt() is deprecated on current glibc. Match its behavior by
  # toggling SA_RESTART on the existing sigaction instead.
  python3 - Modules/signalmodule.c <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """    if (siginterrupt(sig_num, flag)<0) {
        PyErr_SetFromErrno(PyExc_RuntimeError);
        return NULL;
    }"""
new = """    {
        struct sigaction act;
        if (sigaction(sig_num, NULL, &act) < 0) {
            PyErr_SetFromErrno(PyExc_RuntimeError);
            return NULL;
        }
        if (flag)
            act.sa_flags &= ~SA_RESTART;
        else
            act.sa_flags |= SA_RESTART;
        if (sigaction(sig_num, &act, NULL) < 0) {
            PyErr_SetFromErrno(PyExc_RuntimeError);
            return NULL;
        }
    }"""
if old in text:
    text = text.replace(old, new, 1)
if old in text or new not in text:
    raise SystemExit("Could not verify Python signalmodule sigaction patch")
path.write_text(text)
print("Replaced deprecated siginterrupt() with sigaction().")
PY

  CXX="${CXX:-g++}" ./configure --prefix="$PY_PREFIX" --enable-shared --without-ensurepip
  # Python 2 exposes insecure tempnam()/tmpnam() APIs and an obsolete ftime()
  # fallback; disable them where gettimeofday() or tempfile is available.
  python3 - pyconfig.h <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
macros = ["HAVE_TEMPNAM", "HAVE_TMPNAM", "HAVE_TMPNAM_R"]
if re.search(r"^#define HAVE_GETTIMEOFDAY\b", text, flags=re.MULTILINE):
    macros.append("HAVE_FTIME")
for macro in macros:
    text = re.sub(r"^#define " + macro + r"\s+1\s*$",
                  "/* #undef " + macro + " */", text, flags=re.MULTILINE)
    if re.search(r"^#define " + macro + r"\b", text, flags=re.MULTILINE):
        raise SystemExit("Could not disable legacy Python feature: " + macro)
path.write_text(text)
print("Disabled Python 2's insecure temp-name APIs and deprecated ftime() fallback.")
PY
  make -j"$JOBS"
  make install
  touch "$PY_PREFIX/.python_compat_patches_v2"
  if ! LD_LIBRARY_PATH="$PY_PREFIX/lib:${LD_LIBRARY_PATH:-}" \
      "$PY_PREFIX/bin/python2.7" -c 'import _hashlib' >/dev/null 2>&1; then
    log "WARNING: Python 2 _hashlib still unavailable after rebuilding."
  fi
fi

GPERF_PATCH_MARKER="$GPERF_PREFIX/.source_warnings_fixed"
if [ ! -x "$GPERF_PREFIX/bin/gperf" ] || [ ! -f "$GPERF_PATCH_MARKER" ]; then
  log "Preparing gperf 3.1 locally"
  cd "$TOOLS_DIR"
  if [ ! -f gperf-3.1.tar.gz ]; then
    curl -fL -o gperf-3.1.tar.gz https://ftp.gnu.org/pub/gnu/gperf/gperf-3.1.tar.gz
  fi
  if [ ! -d gperf-3.1 ]; then
    tar -xzf gperf-3.1.tar.gz
  fi
  cd gperf-3.1
  python3 - lib/getline.cc src/input.cc <<'PY'
from pathlib import Path
import sys

getline = Path(sys.argv[1])
text = getline.read_text()
text = text.replace('register int c = getc (stream);', 'int c = getc (stream);')
getline.write_text(text)

input_cc = Path(sys.argv[2])
text = input_cc.read_text()
old = """                    char *line_rest = new char[line_end - lp + 1];
                    memcpy (line_rest, lp, line_end - lp);
                    line_rest[line_end - lp -
                              (line_end > lp && line_end[-1] == '\\n' ? 1 : 0)]
                      = '\\0';"""
new = """                    size_t line_rest_length = lp < line_end
                      ? static_cast<size_t>(line_end - lp) : 0;
                    char *line_rest = new char[line_rest_length + 1];
                    memcpy (line_rest, lp, line_rest_length);
                    if (line_rest_length > 0 && line_end[-1] == '\\n')
                      --line_rest_length;
                    line_rest[line_rest_length] = '\\0';"""
if old in text:
    text = text.replace(old, new, 1)
elif 'size_t line_rest_length = lp < line_end' not in text:
    raise SystemExit('Could not find gperf memcpy code to patch')
input_cc.write_text(text)
print('Patched gperf 3.1 legacy warnings in getline.cc and input.cc.')
PY
  ./configure --prefix="$GPERF_PREFIX"
  make -j"$JOBS"
  make install
  touch "$GPERF_PATCH_MARKER"
fi

ln -sf "$PY_PREFIX/bin/python2.7" "$LOCAL_BIN/python"

export PATH="$GPERF_PREFIX/bin:$LOCAL_BIN:$PATH"
export LD_LIBRARY_PATH="$PY_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$PY_PREFIX/lib:${LIBRARY_PATH:-}"

bootstrap_legacy_build_tooling

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
