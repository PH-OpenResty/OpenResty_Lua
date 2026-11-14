#!/bin/sh
# 编译所有 Lua 源码为 LuaJIT 字节码 (.ljbc)
set -e
LJ=/usr/local/openresty/luajit/bin/luajit
BASE=/usr/local/openresty/lua_files
compile() {
    src="$1"; out="$2"
    "$LJ" -b "$src" "$out"
    echo "compiled ${src#$BASE/} -> ${out#$BASE/}"
}
for f in "$BASE"/src/*.lua; do
    [ -f "$f" ] || continue
    compile "$f" "$BASE/$(basename "${f%.lua}").ljbc"
done
for d in lib sites cli; do
    find "$BASE/$d" -name '*.lua' 2>/dev/null | while read -r f; do
        compile "$f" "${f%.lua}.ljbc"
    done
done
