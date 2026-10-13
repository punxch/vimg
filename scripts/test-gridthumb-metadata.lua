-- Run with: lua scripts/test-gridthumb-metadata.lua
-- Exercise preload -> descriptor -> DDS payload with local Yazi stubs.
local sent, meta
Command = function() return { arg = function(self) return self end, output = function() return nil end } end
local state = {}
cx = { active = { current = { hovered = { url = "video.mkv" } } } }
Url = function(value) return value end
ya = {
    sync = function(fn) return function(request) return fn(state, request) end end,
    file_cache = function() return "preview" end,
    dbg = function() end,
}
ps = { pub_to = function(_, event, request)
    assert(event == "vimg-gridthumb-request")
    sent = request
end }
fs = { cha = function(url)
    if url == "video.mkv" then return { len = 123, mtime = 1000 } end
    if url == "preview" then return { len = 12 } end
end }
local plugin = dofile("gridthumb.yazi/main.lua")
plugin.list_meta = function(_, entries)
    assert(entries:find("codec_name", 1, true))
    return meta
end
local video = { codec_type = "video", codec_name = "h264", width = 1920, height = 1080,
                time_base = "1/1000" }
local job = { file = { url = "video.mkv" }, skip = 0 }
local function request(streams)
    meta = { format = { duration = "12.5" }, streams = streams }
    assert(plugin:preload(job))
    plugin:generate_avif(job, "preview")
    return sent
end
local single = request({ video })
assert(single.codec == "h264" and single.duration_s == 12.5)
assert(single.source_time_base_numerator == 1 and single.source_time_base_denominator == 1000)
local multiple = request({ video, video })
assert(multiple.codec == nil and multiple.source_time_base_numerator == nil)
local cover = { codec_type = "video", codec_name = "mjpeg", width = 600, height = 600,
                disposition = { attached_pic = 1 } }
local with_cover = request({ cover, video })
assert(with_cover.codec == "h264" and with_cover.width == 1920)
print("gridthumb metadata: single stream, ambiguous streams, cover art passed")
