-- Linux-only durable filesystem adapter for isolated publisher/agent/writer processes.
-- All descendants are accessed relative to no-follow directory descriptors.
local ffi = require 'ffi'
local bit = require 'bit'
local u = require 'scdn_sync.util'
local crypto = require 'scdn_sync.crypto'
u.check(ffi.os == 'Linux' and ffi.abi('64bit'), 'linux_64bit_filesystem_required', 500)
ffi.cdef [[
int open(const char *, int, ...); int openat(int, const char *, int, ...);
int mkdirat(int, const char *, unsigned int); int close(int); int fsync(int);
int fchmod(int, unsigned int); int flock(int, int);
long read(int, void *, unsigned long); long write(int, const void *, unsigned long);
int renameat(int, const char *, int, const char *); int unlinkat(int, const char *, int);
long readlinkat(int, const char *, char *, unsigned long);
typedef struct scdn_dirent { unsigned long ino; long off; unsigned short reclen;
    unsigned char type; char name[256]; } scdn_dirent;
typedef struct scdn_directory scdn_directory;
scdn_directory *fdopendir(int); scdn_dirent *readdir(scdn_directory *); int closedir(scdn_directory *);
]]
local C = ffi.C
local DIR = bit.bor(0x10000, 0x20000, 0x80000)
local FILE = bit.bor(0x20000, 0x80000, 0x800)
local M = {}; M.__index = M
local function checked(rc) u.check(rc >= 0, 'filesystem_error', 503); return rc end
local function components(path)
    u.check(type(path) == 'string' and #path > 0 and #path < 2048
        and not path:find('[%z\\\r\n]') and path:sub(1, 1) ~= '/', 'unsafe_path')
    local out = {}
    for part in path:gmatch('[^/]+') do
        u.check(part ~= '.' and part ~= '..' and #part <= 200, 'unsafe_path')
        out[#out + 1] = part
    end
    u.check(table.concat(out, '/') == path, 'unsafe_path')
    return out
end
local function descend(fd, name, create)
    local next_fd = C.openat(fd, name, DIR)
    if next_fd < 0 and ffi.errno() == 2 and not create then return nil end
    if next_fd < 0 and ffi.errno() == 2 and create then
        local rc = C.mkdirat(fd, name, 448)
        u.check(rc == 0 or ffi.errno() == 17, 'filesystem_error', 503)
        next_fd = C.openat(fd, name, DIR)
    end
    -- Reconfirm existing parent entries too: an earlier mkdir may have become
    -- visible before its parent fsync returned an error in another process.
    if create and C.fsync(fd) ~= 0 then
        if next_fd >= 0 then C.close(next_fd) end
        u.fail('filesystem_error', 503)
    end
    return checked(next_fd)
end
local function open_root(root, readonly)
    u.check(type(root) == 'string' and root:sub(1, 1) == '/' and root ~= '/', 'unsafe_root')
    local parts = components(root:sub(2))
    local fd = checked(C.open('/', DIR))
    for _, part in ipairs(parts) do
        local ok, next_fd = pcall(descend, fd, part, not readonly)
        C.close(fd)
        if not ok then error(next_fd, 0) end
        u.check(next_fd, 'directory_missing', 503)
        fd = next_fd
    end
    if not readonly then
        local ok, err = pcall(function() checked(C.fchmod(fd, 448)); checked(C.fsync(fd)) end)
        if not ok then C.close(fd); error(err, 0) end
    end
    return setmetatable({ readonly = readonly,
        fd = ffi.gc(ffi.new('int[1]', fd), function(p) C.close(p[0]) end) }, M)
end
function M.open(root) return open_root(root, false) end
-- Source directories belong to the existing system: never create or chmod them.
function M.reader(root) return open_root(root, true) end
function M:close()
    if self.fd then ffi.gc(self.fd, nil); C.close(self.fd[0]); self.fd = nil end
end
function M:_parent(path, create)
    local parts = components(path)
    local fd = checked(C.openat(self.fd[0], '.', DIR))
    for i = 1, #parts - 1 do
        local ok, next_fd = pcall(descend, fd, parts[i], create)
        C.close(fd)
        if not ok then error(next_fd, 0) end
        if not next_fd then return nil, parts[#parts] end
        fd = next_fd
    end
    return fd, parts[#parts]
end
local function scoped(fd, fn)
    local ok, a, b = pcall(fn)
    C.close(fd)
    if not ok then error(a, 0) end
    return a, b
end
function M:read(path, limit)
    local dir, name = self:_parent(path, false)
    if not dir then return nil end
    return scoped(dir, function()
        local fd = C.openat(dir, name, FILE)
        if fd < 0 and ffi.errno() == 2 then return nil end
        checked(fd)
        return scoped(fd, function()
            local out, size, buffer = {}, 0, ffi.new('char[65536]')
            while true do
                local n = C.read(fd, buffer, 65536)
                if n < 0 and ffi.errno() ~= 4 then u.fail('filesystem_error', 503) end
                if n == 0 then break end
                if n > 0 then
                    size = size + tonumber(n)
                    u.check(size <= (limit or u.MAX_BYTES * 2), 'file_size', 413)
                    out[#out + 1] = ffi.string(buffer, n)
                end
            end
            return table.concat(out)
        end)
    end)
end
function M:write(path, bytes)
    u.check(not self.readonly, 'readonly_store', 403)
    u.check(type(bytes) == 'string' and #bytes <= u.MAX_BYTES * 2, 'file_size', 413)
    local dir, name = self:_parent(path, true)
    return scoped(dir, function()
        local temporary = '.tmp-' .. crypto.sha256(crypto.random(32)):sub(1, 32)
        local fd = checked(C.openat(dir, temporary, bit.bor(FILE, 1, 0x40, 0x80), ffi.new('int', 384)))
        local ok, err = pcall(function()
            local offset = 0
            while offset < #bytes do
                local n = C.write(fd, bytes:sub(offset + 1), #bytes - offset)
                if n < 0 and ffi.errno() ~= 4 then u.fail('filesystem_error', 503) end
                u.check(n ~= 0, 'filesystem_error', 503)
                if n > 0 then offset = offset + tonumber(n) end
            end
            checked(C.fsync(fd))
        end)
        C.close(fd)
        if not ok then C.unlinkat(dir, temporary, 0); error(err, 0) end
        local rc = C.renameat(dir, temporary, dir, name)
        if rc ~= 0 then C.unlinkat(dir, temporary, 0); u.fail('filesystem_error', 503) end
        checked(C.fsync(dir))
        return true
    end)
end
function M:remove(path)
    u.check(not self.readonly, 'readonly_store', 403)
    local dir, name = self:_parent(path, false)
    if not dir then return true end
    return scoped(dir, function()
        local rc = C.unlinkat(dir, name, 0)
        u.check(rc == 0 or ffi.errno() == 2, 'filesystem_error', 503)
        checked(C.fsync(dir)); return true
    end)
end
function M:list(path, maximum)
    local fd
    if path == nil then fd = checked(C.openat(self.fd[0], '.', DIR))
    else
        local parent, name = self:_parent(path, not self.readonly)
        u.check(parent, 'directory_missing', 503)
        fd = scoped(parent, function() return descend(parent, name, not self.readonly) end)
        u.check(fd, 'directory_missing', 503)
    end
    local stream = C.fdopendir(fd)
    if stream == nil then C.close(fd); u.fail('filesystem_error', 503) end
    local ok, result = pcall(function()
        local names = {}
        while true do
            ffi.errno(0)
            local entry = C.readdir(stream)
            if entry == nil then u.check(ffi.errno() == 0, 'filesystem_error', 503); break end
            local item = ffi.string(entry.name)
            if item ~= '.' and item ~= '..' then
                names[#names + 1] = item
                u.check(#names <= (maximum or 4096), 'directory_capacity', 503)
            end
        end
        table.sort(names); return names
    end)
    C.closedir(stream)
    if not ok then error(result, 0) end
    return result
end
function M:lock(path)
    u.check(not self.readonly, 'readonly_store', 403)
    local dir, name = self:_parent(path, true)
    local fd = scoped(dir, function() return checked(C.openat(dir, name, bit.bor(FILE, 2, 0x40), ffi.new('int', 384))) end)
    if C.flock(fd, 6) ~= 0 then C.close(fd); u.fail('operation_busy', 409) end
    local guard = { fd = fd }
    function guard:release() if self.fd then C.close(self.fd); self.fd = nil end end
    return guard
end
function M:locked(path, fn)
    local guard = self:lock(path)
    local ok, a, b = pcall(fn)
    guard:release()
    if not ok then error(a, 0) end
    return a, b
end
function M.verify_directory(path)
    u.check(type(path) == 'string' and path:sub(1, 1) == '/' and path ~= '/', 'unsafe_root')
    local fd = checked(C.open('/', DIR))
    for _, part in ipairs(components(path:sub(2))) do
        local ok, next_fd = pcall(descend, fd, part, false)
        C.close(fd)
        if not ok then error(next_fd, 0) end
        u.check(next_fd, 'directory_missing', 503)
        fd = next_fd
    end
    C.close(fd)
    return true
end
return M
