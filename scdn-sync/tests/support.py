"""Run the actual Lua modules under LuaJIT; provide only host JSON/base64 APIs.

No cryptographic primitive is mocked. lua-resty-openssl calls a real OpenSSL DLL
on Windows, and the process's libcrypto symbols on Linux.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
deps = os.environ.get("SCDN_TEST_DEPS")
if deps:
    sys.path.insert(0, deps)

from lupa.luajit21 import LuaRuntime


def runtime():
    lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
    globals_ = lua.globals()
    globals_.py_json_encode = lambda value: json.dumps(
        value.decode("utf-8") if isinstance(value, bytes) else value,
        ensure_ascii=True, separators=(",", ":"), allow_nan=False,
    ).encode()
    def decode(value):
        try:
            result = json.loads(value)
            return (result.encode() if isinstance(result, str) else result), None
        except (ValueError, UnicodeError):
            return None, b"invalid JSON"
    globals_.py_json_decode = decode
    globals_.py_b64encode = base64.b64encode
    globals_.py_b64decode = lambda value: base64.b64decode(value, validate=True)
    globals_.test_library_path = str(ROOT / "scdn-sync/lib/?.lua").replace("\\", "/").encode()
    resty = os.environ.get("SCDN_TEST_RESTY_OPENSSL")
    if not resty:
        resty = "/usr/local/openresty/lualib/?.lua"
    globals_.test_openssl_path = (resty + ";" + resty.replace("?.lua", "?/init.lua")).replace("\\", "/").encode()
    dll = os.environ.get("SCDN_TEST_OPENSSL")
    if not dll and os.name == "nt":
        raise RuntimeError("Set SCDN_TEST_OPENSSL to the absolute path of an OpenSSL 3 libcrypto DLL")
    globals_.test_openssl_dll = dll.encode() if dll else None
    lua.execute(b"""
        package.path = test_library_path .. ';' .. test_openssl_path .. ';' .. package.path
        local ffi = require 'ffi'
        if test_openssl_dll then
            local lib = ffi.load(test_openssl_dll)
            local original = ffi.C
            -- Windows has no RTLD_GLOBAL. Redirect the library's FFI lookups.
            ffi.C = setmetatable({}, { __index = function(_, key)
                local ok, value = pcall(function() return lib[key] end)
                if ok then return value end
                return original[key]
            end })
        else
            test_crypto_library = ffi.load('crypto', true)
        end
        package.preload['cjson.safe'] = function()
            return { encode = py_json_encode, decode = py_json_decode, null = {} }
        end
        ngx = { encode_base64 = py_b64encode, decode_base64 = py_b64decode,
            log = function() end, WARN = 4, DEBUG = 8 }
        package.preload['ngx.base64'] = function()
            return { encode_base64url = function(s)
                return (ngx.encode_base64(s):gsub('%+', '-'):gsub('/', '_'):gsub('=', ''))
            end }
        end
    """)
    return lua


def module(lua, name):
    value = lua.eval(b"require")(name.encode())
    return value[0] if isinstance(value, tuple) else value


def table(lua, value):
    return module(lua, "scdn_sync.codec").decode(json.dumps(value, separators=(",", ":")).encode())


def assert_error(fn, *args, code=None):
    lua = getattr(fn, "_test_lua", None)
    try:
        fn(*args)
    except Exception:
        return
    raise AssertionError("Expected rejection")


class DiskStore:
    """Host test adapter; the production Linux openat/fsync adapter is separate."""
    def __init__(self, lua, directory=None):
        self.lua = lua
        self.temp = tempfile.TemporaryDirectory(prefix="scdn-sync-test-") if directory is None else None
        self.root = Path(directory or self.temp.name)
        self.locks = {}
        self.fail_path = None
        self.fail_after_path = None
        self.table = lua.table()
        self.table[b'read'] = lambda _, path, limit=None: self.read(path, limit)
        self.table[b'write'] = lambda _, path, data: self.write(path, data)
        self.table[b'remove'] = lambda _, path: self.remove(path)
        self.table[b'list'] = lambda _, path, maximum=4096: lua.table_from(self.list(path, maximum))
        self.table[b'locked'] = lambda _, path, fn: self.locked(path, fn)

    def path(self, relative):
        value = relative.decode() if isinstance(relative, bytes) else relative
        parts = value.split('/')
        if value.startswith('/') or any(p in ('', '.', '..') for p in parts):
            raise ValueError("unsafe test path")
        return self.root.joinpath(*parts)

    def read(self, relative, limit=None):
        path = self.path(relative)
        if not path.exists():
            return None
        data = path.read_bytes()
        if len(data) > (limit or 8 * 1024 * 1024):
            raise ValueError("oversized test file")
        return data

    def write(self, relative, data):
        path = self.path(relative)
        if self.fail_path and self.fail_path in str(path):
            raise OSError("injected disk failure")
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + '.tmp')
        with temporary.open('wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        if self.fail_after_path and self.fail_after_path in str(path):
            raise OSError('injected failure after atomic rename')
        return True

    def remove(self, relative):
        self.path(relative).unlink(missing_ok=True)
        return True

    def list(self, relative, maximum):
        path = self.path(relative)
        path.mkdir(parents=True, exist_ok=True)
        names = sorted(p.name.encode() for p in path.iterdir())
        if len(names) > maximum:
            raise ValueError("directory capacity")
        return names

    def locked(self, path, fn):
        lock = self.locks.setdefault(path, threading.Lock())
        if not lock.acquire(blocking=False):
            raise ValueError("busy")
        try:
            return fn()
        finally:
            lock.release()


def runtime_doubles(lua):
    lua.execute(b"""
        package.preload['resty.lock'] = function()
            return { new = function() return {
                lock = function() return 0 end, unlock = function() return true end } end }
        end
        function test_dict()
            local values = {}
            return { get = function(_, k) return values[k] end,
                safe_set = function(self, k, v)
                    if self.fail_key == k then return nil, 'no memory' end
                    values[k] = v; return true
                end,
                delete = function(_, k) values[k] = nil end }
        end
        test_ssl = { parse_pem_cert = function(pem) return pem end,
            parse_pem_priv_key = function(pem) return pem end,
            clear_certs = function() return true end,
            set_cert = function() return true end, set_priv_key = function() return true end }
        function test_worker(id, count)
            return { id = function() return id end, pid = function() return 1000 + id end,
                count = function() return count end }
        end
    """)
