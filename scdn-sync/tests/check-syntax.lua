local count = 0
for _, path in ipairs(arg) do
    local chunk, err = loadfile(path)
    assert(chunk, err)
    count = count + 1
end
print(count .. ' Lua files parsed by ' .. jit.version)
