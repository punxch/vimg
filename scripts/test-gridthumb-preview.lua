-- Run with: lua scripts/test-gridthumb-preview.lua
-- Exercise the combined helper, per-file fallback, cache reuse and DDS metadata.
local state, calls, meta, output, image, events, sent
local original = { format = { duration = "12.500000" }, streams = {
    { codec_type = "video", codec_name = "h264", width = 1920, height = 1080,
      time_base = "1/1000", disposition = { attached_pic = 0 } },
} }
local function reset()
    state, calls, meta, image, events, sent = {}, {}, original, false, {}, nil
    output = { status = { success = true, code = 0 }, stdout = "json" }
end
reset()
Url = function(value) return value end
Err = function(...) return string.format(...) end
cx = { active = { current = { hovered = { url = "a video.mkv" } } } }
rt = { preview = {max_width=600,max_height=900,image_quality=75} }
ya = {
    sync = function(fn) return function(...) return fn(state, ...) end end,
    json_decode = function() return meta end,
    file_cache = function() return "cache" end,
    dbg = function() end,
    emit = function(name, args) events[#events+1] = {name, args} end,
}
fs = { cha = function(path)
    if path == "a video.mkv" then return {len=123,mtime=1000} end
    if path == "cache" and image then return {len=12} end
end }
ps = { pub_to = function(_, _, body) sent = body end }
Command = function(name)
    local command = { name = name, args = {} }
    calls[#calls+1] = command
    function command:arg(args)
        for _, value in ipairs(args) do self.args[#self.args+1] = value end
        return self
    end
    function command:output()
        if output and output.status.success and meta and meta.preview_written then image = true end
        return output
    end
    function command:status() image = true; return {success=true,code=0} end
    return command
end
local plugin = dofile("gridthumb.yazi/main.lua")
local probes = 0
plugin.list_preview_meta = function() probes = probes+1; return original end
local job = { file = {url="a video.mkv"}, skip=0 }
original.native_preview, original.preview_written = true, true
assert(plugin:preload(job))
assert(#calls == 1 and probes == 0 and calls[1].args[1] == "preview")
local args = calls[1].args
assert(args[2] == "--output" and args[3] == "cache" and args[#args-1] == "--" and args[#args] == job.file.url)
plugin:generate_avif(job, "cache")
assert(sent.duration_s == 12.5 and sent.codec == "h264" and sent.source_time_base_denominator == 1000)
assert(plugin:preload(job) and #calls == 1 and probes == 1, "existing static image must skip combined helper and extraction")

reset()
original.preview_written = false
assert(plugin:preload(job) and #calls == 2 and calls[2].name == "ffmpeg" and probes == 1,
    "per-file fallback must reuse metadata without another probe")
assert(state.vimg_preview_available ~= false)
image = false
original.preview_written = true
assert(plugin:preload(job) and #calls == 3 and calls[3].name == "vimg")

for _, mode in ipairs({"missing", "old", "standard"}) do
    reset()
    if mode == "missing" then output = nil
    elseif mode == "old" then output.status = {success=false,code=2}
    else meta = {native_preview=false,native_probe=false} end
    assert(plugin:preload(job) and state.vimg_preview_available == false)
    local count = #calls
    image = false
    assert(plugin:preload(job) and #calls == count+1 and calls[#calls].name == "ffmpeg")
    if mode == "old" then assert(state.vimg_probe_available ~= false)
    else assert(state.vimg_probe_available == false) end
end
for _, mode in ipairs({"error", "json", "incomplete"}) do
    reset()
    if mode == "error" then output.status = {success=false,code=1}
    elseif mode == "json" then meta = nil
    else meta = {format={},streams={}} end
    assert(plugin:preload(job) and calls[#calls].name == "ffmpeg")
    assert(state.vimg_preview_available ~= false, "a per-file failure must not disable native capability")
end
reset()
job.skip = 91
original.preview_written = false
assert(plugin:preload(job) == false and #calls == 1)
assert(events[1][1] == "peek" and events[1][2][1] == 90 and events[1][2].upper_bound)
print("gridthumb combined preview: native, metadata reuse, cached image, fallbacks, capability cache, upper-bound passed")
