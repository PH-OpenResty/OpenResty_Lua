#!/bin/sh
# reload / stop 之前把 L1 独有的缓存文件落盘到 L2, 保证内存层不丢数据
LJ=/usr/local/openresty/luajit/bin/luajit
FLUSH=/usr/local/openresty/lua_files/flush_l1_to_l2.ljbc
NG=/usr/local/openresty/nginx/sbin/nginx

if [ -x "$LJ" ] && [ -f "$FLUSH" ]; then
    "$LJ" "$FLUSH" || echo "WARN: L1->L2 flush failed, continuing" >&2
fi

case "$1" in
    reload) exec "$NG" -s reload ;;
    stop)   exec "$NG" -s quit ;;
    *)      echo "usage: $0 {reload|stop}" >&2; exit 2 ;;
esac
