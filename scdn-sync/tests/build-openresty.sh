#!/bin/sh
# Reproducible test build into a caller-selected, separate installation prefix.
set -eu
sync_prefix=${1:?provide an absolute isolated test prefix}
case "$sync_prefix" in /*) ;; *) echo 'prefix must be absolute' >&2; exit 1;; esac
if [ -e "$sync_prefix/nginx/sbin/nginx" ]; then
    echo 'refusing to overwrite an existing OpenResty installation' >&2
    exit 1
fi
sync_plugin=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
sync_work=$(mktemp -d /tmp/scdn-sync-build.XXXXXXXX)
trap 'rm -rf -- "$sync_work"' EXIT
trap 'exit 1' HUP INT TERM
sync_version=1.31.8.1
sync_sha=b569c63b420f80a4ac8466f2deffe73ed93ab760026532e039c3658409a997f4
sync_archive="$sync_work/openresty.tar.gz"
curl --proto '=https' --tlsv1.2 -fsS "https://openresty.org/download/openresty-$sync_version.tar.gz" -o "$sync_archive"
printf '%s  %s\n' "$sync_sha" "$sync_archive" | sha256sum --check --status
tar -xzf "$sync_archive" -C "$sync_work"
sync_source="$sync_work/openresty-$sync_version"
set -- "$sync_source"/bundle/ngx_lua-*
[ "$#" -eq 1 ] && [ -d "$1" ]
sync_lua_name=$(basename -- "$1")
cd "$sync_source"
NGX_LUA_LOC="$sync_source/build/$sync_lua_name" ./configure \
    --prefix="$sync_prefix" --with-http_ssl_module --with-http_v2_module --with-pcre-jit \
    --add-module="$sync_plugin/vendor/lua-resty-openssl-aux-module" -j"${SCDN_SYNC_BUILD_JOBS:-2}"
make -j"${SCDN_SYNC_BUILD_JOBS:-2}"
make install
