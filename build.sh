#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
BIN_DIR="$BUILD_DIR/bin"
NPROC=${NPROC:-$(nproc || echo 4)}
SYSTEM_LIBTOOLIZE=${SYSTEM_LIBTOOLIZE:-/usr/bin/libtoolize}
SYSTEM_AUTORECONF=${SYSTEM_AUTORECONF:-/usr/bin/autoreconf}
SYSTEM_LIBTOOL=${SYSTEM_LIBTOOL:-/usr/bin/libtool}

function ensure_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "skybridge: missing required tool '$1'" >&2
    exit 1
  fi
}

function ensure_submodule() {
  local path="$1"
  if [[ ! -d "$ROOT_DIR/$path" ]]; then
    echo "[SkyBridge] Initializing submodule $path"
    git -C "$ROOT_DIR" submodule update --init --recursive "$path"
  else
    git -C "$ROOT_DIR" submodule update --init "$path"
  fi
}

function prepare_dir() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
}

function build_mavlink_router() {
  local src="$ROOT_DIR/thirdparty/mavlink-router"
  local build_path="$BUILD_DIR/mavlink-router"
  ensure_submodule "thirdparty/mavlink-router"

  echo "[SkyBridge] Building mavlink-router"
  prepare_dir "$build_path"
  meson setup "$build_path" "$src"
  ninja -C "$build_path"
  cp "$build_path/src/mavlink-routerd" "$BIN_DIR/mavlink-routerd"
}

function regenerate_autotools() {
  local src_dir="$1"
  echo "[SkyBridge] Regenerating autotools in $src_dir"
  pushd "$src_dir" >/dev/null
  PATH="/usr/bin:$PATH" LIBTOOLIZE="$SYSTEM_LIBTOOLIZE" "$SYSTEM_AUTORECONF" -fi
  popd >/dev/null
}

function build_gensio() {
  local src="$ROOT_DIR/thirdparty/gensio"
  local build_path="$BUILD_DIR/gensio"
  local prefix="$build_path/install"
  ensure_submodule "thirdparty/gensio"

  regenerate_autotools "$src"
  echo "[SkyBridge] Building gensio (dependency for ser2net)"

  prepare_dir "$build_path"
  pushd "$build_path" >/dev/null
  LIBTOOL="$SYSTEM_LIBTOOL" "$src"/configure \
    --prefix="$prefix" \
    --with-all-gensios=no \
    --with-net=yes \
    --with-serialdev=yes \
    --with-telnet=yes \
    --with-msgdelim=yes \
    --with-ssl=no \
    --with-avahi=no \
    --with-dnssd=no \
    --with-openssl=no \
    --with-sctp=no \
    --with-alsa=no \
    --with-udev=no \
    --with-glib=no \
    --with-tcl=no \
    --with-python=no \
    --with-swig=no \
    --with-go=no \
    --enable-shared=no
  mkdir -p "$prefix/libexec/gensio/3.0.0"
  make -j"$NPROC"
  make install
  popd >/dev/null
}

function build_ser2net() {
  local src="$ROOT_DIR/thirdparty/ser2net"
  local build_path="$BUILD_DIR/ser2net"
  local prefix="$build_path/install"
  ensure_submodule "thirdparty/ser2net"

  regenerate_autotools "$src"
  echo "[SkyBridge] Building ser2net"

  prepare_dir "$build_path"
  pushd "$build_path" >/dev/null
  PKG_CONFIG_PATH="$BUILD_DIR/gensio/install/lib/pkgconfig" \
  CPPFLAGS="-I$BUILD_DIR/gensio/install/include" \
  LDFLAGS="-L$BUILD_DIR/gensio/install/lib" \
  LIBS="-lgensioosh -lpthread" \
    LIBTOOL="$SYSTEM_LIBTOOL" "$src"/configure --prefix="$prefix"
  make -j"$NPROC"
  make install
  popd >/dev/null

  cp "$prefix/sbin/ser2net" "$BIN_DIR/ser2net"
}

function build_remserial() {
  local src="$ROOT_DIR/thirdparty/remserial"
  ensure_submodule "thirdparty/remserial"

  echo "[SkyBridge] Building remserial"
  make -C "$src" clean >/dev/null 2>&1 || true
  make -C "$src" -j"$NPROC"
  cp "$src/remserial" "$BIN_DIR/remserial"
}

function main() {
  ensure_tool git
  ensure_tool meson
  ensure_tool ninja
  ensure_tool make
  ensure_tool pkg-config
  ensure_tool autoconf
  ensure_tool automake
  ensure_tool libtool
  ensure_tool "$SYSTEM_LIBTOOLIZE"
  ensure_tool "$SYSTEM_AUTORECONF"

  mkdir -p "$BIN_DIR"

  build_mavlink_router
  build_gensio
  build_ser2net
  build_remserial

  echo "[SkyBridge] Build artifacts:"
  ls -1 "$BIN_DIR"
}

main "$@"
