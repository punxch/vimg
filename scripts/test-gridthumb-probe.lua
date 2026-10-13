-- Run with: lua scripts/test-gridthumb-probe.lua
local output, decoded, commands, fallback = nil, nil, {}, 0
local state = {}
ya = {
    sync = function(fn) return function(...) return fn(state, ...) end end,
    json_decode = function() return decoded end,
}
Command = function(name)
    assert(name == "vimg")
    return {
        arg = function(self, args) commands[#commands + 1] = args; return self end,
        output = function() return output end,
    }
end
local plugin = dofile("gridthumb.yazi/main.lua")
local original = { format = { duration = "12.500000" }, streams = {
    { codec_type = "video", codec_name = "mjpeg", width = 600, height = 600,
      time_base = "1/90000", disposition = { attached_pic = 1 } },
    { codec_type = "video", codec_name = "h264", width = 1920, height = 1080,
      time_base = "1/1000", disposition = { attached_pic = 0 } },
} }
plugin.list_meta = function(url, entries)
    assert(url == "a video.mkv" and entries:find("attached_pic", 1, true))
    fallback = fallback + 1
    return original, "fallback marker"
end
local function expect_fallback()
    state.vimg_probe_available = nil
    local before = fallback
    local meta, err = plugin.list_preview_meta("a video.mkv")
    assert(meta == original and err == "fallback marker" and fallback == before + 1)
end
expect_fallback() -- missing executable
output = { status = { success = false, code = 2 }, stdout = "old version" }
decoded = original
expect_fallback() -- an older CLI can print output yet exit unsuccessfully
output.status.success = true
output.status.code = 0
decoded = nil
expect_fallback() -- malformed JSON
decoded = { format = {}, streams = original.streams }
expect_fallback() -- missing duration
decoded = { format = original.format, streams = {} }
expect_fallback() -- missing streams
decoded = { format = { duration = "N/A" }, streams = original.streams }
expect_fallback()
decoded = { format = { duration = "0" }, streams = original.streams }
expect_fallback()
decoded = original
local before = fallback
assert(plugin.list_preview_meta("a video.mkv") == original and fallback == before)
assert(plugin.has_pic(original), "native metadata must retain attached pictures")
-- Keep capability state in Yazi's sync plugin, across separate async peeks.
original.native_probe = false
assert(plugin.list_preview_meta("a video.mkv") == original)
local count = #commands
assert(state.vimg_probe_available == false)
plugin.list_preview_meta("a video.mkv")
assert(#commands == count and fallback == before + 1, "feature-off helpers must be bypassed on later previews")
for _, missing in ipairs({ "missing", "old" }) do
    state.vimg_probe_available = nil
    if missing == "missing" then
        output = nil
    else
        output = { status = { success = false, code = 2 } }
    end
    plugin.list_preview_meta("a video.mkv")
    count = #commands
    plugin.list_preview_meta("a video.mkv")
    assert(#commands == count, "missing/old helpers must only be attempted once per session")
end
state.vimg_probe_available = nil
output = { status = { success = false, code = 1 } }
plugin.list_preview_meta("a video.mkv")
assert(state.vimg_probe_available ~= false, "a bad input must not disable native probing for other files")
for _, args in ipairs(commands) do
    assert(#args == 3 and args[1] == "probe" and args[2] == "--" and args[3] == "a video.mkv")
end
print("gridthumb probe: native metadata, cover art, old/missing executable, malformed/incomplete JSON fallback passed")
