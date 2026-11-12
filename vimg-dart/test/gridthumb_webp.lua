-- Run from the repository root with luajit vimg-dart/test/gridthumb_webp.lua.
local state, remote, sent, shown, emitted = {}, {}, {}, {}, {}
local files = { ["video.mkv"] = { len = 100, mtime = 25 } }
local jpeg = false
local metadata = {
    format = { duration = "8.000000" },
    streams = { { codec_type = "video", codec_name = "mjpeg", width = 32, height = 24 } },
}
cx = { active = { current = { hovered = { url = "video.mkv" } } } }
rt = { preview = { image_delay = 0, max_width = 600, max_height = 900, image_quality = 75 } }
Url = function(value) return value end
Err = string.format
fs = { stat = function(path) return files[path] end }
ya = {
    sync = function(fn) return function(...) return fn(state, ...) end end,
    dbg = function() end,
    sleep = function() end,
    file_cache = function() return "cache" end,
    json_decode = function() return metadata end,
    image_show = function(path) shown[#shown + 1] = path end,
    preview_widget = function(_, err) return err end,
    emit = function(event, payload) emitted[#emitted + 1] = { event, payload } end,
}
ps = {
    sub = function() end,
    sub_remote = function(event, handler) remote[event] = handler end,
    pub_to = function(recipient, event, body)
        assert(recipient == 0)
        sent[#sent + 1] = { event, body }
    end,
}
Command = function(executable)
    assert(executable == "vimg-dart", "Dart mode must use the configured CLI for media")
    return { arg = function(_, args)
        assert(args[1] == "preview")
        return { output = function()
            if jpeg then files.cache = { len = 10 } end
            return { status = { success = true }, stdout = "{}" }
        end }
    end }
end

local plugin = dofile("gridthumb.yazi/main.lua")
plugin.setup(state, { grid_format = "webp", vimg = "vimg-dart", auto_start = false })
local job = { file = { url = "video.mkv" }, skip = 0 }
metadata.preview_fallback = "codec unavailable"
assert(plugin:peek(job) == "codec unavailable" and #shown == 0 and #sent == 0)

jpeg = true
plugin:peek(job)
assert(shown[1] == "cache" and sent[1][1] == "vimg-gridthumb-webp-request")
assert(sent[1][2].cache == "cache.webp" and sent[1][2].source_modified_s == 25)
assert(remote["gridthumb-avif-ready"] == nil)
files["cache.webp"] = { len = 10 }
files["cache.webp.100-25.json"] = { len = 10 }
remote["gridthumb-webp-ready"] { file = "video.mkv", cache = "cache.webp" }
assert(emitted[1][1] == "peek" and emitted[1][2].force)
plugin:peek(job)
assert(shown[2] == "cache.webp" and #sent == 1)
print("gridthumb WebP mode: Dart preview, DDS request, ready refresh, and cache display passed")
