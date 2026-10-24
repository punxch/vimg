-- Run with: lua scripts/test-gridthumb-helper.lua
-- Exercise configured helper selection without hiding full-vimg fallback.
local state, calls, responses, in_setup
local metadata = { format = { duration = "12.500000" }, streams = {
    { codec_type = "video", codec_name = "h264", width = 640, height = 360,
      time_base = "1/1000", disposition = { attached_pic = 0 } },
}, native_preview = true, preview_written = true }
ya = {
    sync = function(fn) return function(...)
        assert(not in_setup, "setup writes its synchronous state directly")
        return fn(state, ...)
    end end,
    json_decode = function(value) return value end,
}
ps = { sub = function() end, sub_remote = function() end }
rt = { preview = { max_width = 600, max_height = 900, image_quality = 75 } }
Command = function(name)
    local command = { name = name }
    calls[#calls + 1] = command
    function command:arg(args) self.args = args; return self end
    function command:output() return responses[name] end
    return command
end
local plugin = dofile("gridthumb.yazi/main.lua")
local helper = "D:/preview tools/vimg-preview.exe"
local function reset(response)
    state, calls = {}, {}
    responses = { vimg = { status = { success = true, code = 0 }, stdout = metadata } }
    responses[helper] = response
    in_setup = true
    plugin.setup(state, { preview_helper = helper })
    in_setup = false
end
local function prepare(file)
    return plugin.prepare_preview({ file = { url = file or "a video.MKV" }, skip = 0 }, "cache.jpg")
end
reset({ status = { success = true, code = 0 }, stdout = metadata })
assert(prepare() == metadata and #calls == 1 and calls[1].name == helper)
assert(calls[1].args[1] == "preview" and calls[1].args[#calls[1].args] == "a video.MKV")
for _, extension in ipairs({ "ts", "avi", "mxf", "unknown" }) do
    calls = {}
    assert(prepare("file." .. extension) == metadata and #calls == 1 and calls[1].name == "vimg")
end
for _, mode in ipairs({ "missing", "old", "feature-off" }) do
    local response
    if mode == "old" then response = { status = { success = false, code = 2 } }
    elseif mode == "feature-off" then
        response = { status = { success = true, code = 0 }, stdout = {
            native_preview = false, native_probe = false, preview_written = false } }
    end
    reset(response)
    assert(prepare() == metadata and #calls == 2 and calls[2].name == "vimg", mode)
    assert(state.vimg_preview_available ~= false and state.vimg_probe_available ~= false)
    assert(prepare() == metadata and #calls == 3 and calls[3].name == "vimg", mode)
end
reset({ status = { success = false, code = 1 } })
assert(prepare() == nil and state.preview_helper == helper)
assert(plugin.list_preview_meta("input.mkv") == metadata and calls[2].name == "vimg")
reset({ status = { success = true, code = 0 }, stdout = metadata })
plugin.setup(state)
assert(prepare() == metadata and calls[1].name == "vimg")
print("configured helper, extension routing, unavailable-helper fallback and per-file metadata fallback passed")
