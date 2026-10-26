-- Run with: lua scripts/test-gridthumb-refresh.lua [plugin-path]
local state, files, sent, events, notifications, removed, disabled, fail, switch
local video = { url = "video.mkv", mime = function() return "video/x-matroska" end }
Url = function(value) return value end
cx = { active = { current = {}, preview = { skip = 20 } } }
ya = {
    sync = function(fn) return function(...) return fn(state, ...) end end,
    file_cache = function(job)
        assert(job.file == (video.bare or video) and job.skip == 20, "refresh must use the current file and skip")
        return not disabled and "cache-20" or nil
    end,
    dbg = function() end,
    emit = function(action, args) events[#events + 1] = { action, args } end,
    notify = function(body) notifications[#notifications + 1] = body end,
}
fs = {
    cha = function(path) return files[path] end,
    remove = function(kind, path)
        assert(kind == "file")
        removed[#removed + 1] = path
        if switch then cx.active.current.hovered = { url = "another.mkv" } end
        if fail then return false, { kind = "PermissionDenied" } end
        if not files[path] then return false, { kind = "NotFound" } end
        files[path] = nil
        return true
    end,
}
ps = { pub_to = function(_, event, body) sent[#sent + 1] = { event, body } end }
local plugin = dofile(arg[1] or "gridthumb.yazi/main.lua")
local function reset()
    state, sent, events, notifications, removed = {}, {}, {}, {}, {}
    disabled, fail, switch = false, false, false
    files = {
        ["video.mkv"] = { len = 123, mtime = 1000 },
        ["cache-20"] = { len = 10 },
        ["cache-20.avif"] = { len = 20 },
        ["cache-20.avif.123-1000.json"] = { len = 30 },
        ["unrelated-cache"] = { len = 40 },
    }
    cx.active.current.hovered = video
end
local function refresh() plugin:entry { args = { "refresh" } } end
reset()
refresh()
assert(#removed == 3 and not files["cache-20"] and not files["cache-20.avif"])
assert(not files["cache-20.avif.123-1000.json"] and files["unrelated-cache"])
assert(#sent == 1 and sent[1][1] == "vimg-gridthumb-request")
assert(sent[1][2].refresh and sent[1][2].latest and sent[1][2].cache == "cache-20.avif")
assert(sent[1][2].source_size == 123 and sent[1][2].file == video.url)
assert(#events == 1 and events[1][1] == "peek" and events[1][2].force)
assert(events[1][2].only_if == video.url and events[1][2][1] == nil)
-- New Yazi contexts and timestamps must use the same cache identity.
reset()
cx.tab, cx.active = cx.active, nil
fs.stat, fs.cha = fs.cha, nil
files["video.mkv"].mtime = { unix = 1000.75 }
refresh()
assert(sent[1][2].source_modified_s == 1000 and #removed == 3)
cx.active, cx.tab = cx.tab, nil
fs.cha, fs.stat = fs.stat, nil
reset()
video.bare = { raw_file = true }
refresh()
assert(#sent == 1, "older Yazi file_cache requires the owned bare File")
video.bare = nil
-- Late async work from another tab must still follow the active selection.
reset()
cx.tab = { current = { hovered = { mime = function() return "text/plain" end } } }
refresh()
assert(#sent == 1 and sent[1][2].file == video.url)
cx.tab = nil
reset()
refresh()
refresh() -- Already missing caches are also refreshable.
assert(#sent == 2 and #notifications == 0)
for _, mode in ipairs({ "no-hover", "non-video", "no-cache", "other-command" }) do
    reset()
    if mode == "no-hover" then cx.active.current.hovered = nil
    elseif mode == "non-video" then cx.active.current.hovered = { mime = function() return "text/plain" end }
    elseif mode == "no-cache" then disabled = true end
    if mode == "other-command" then plugin:entry { args = {} } else refresh() end
    assert(#removed == 0 and #sent == 0 and #events == 0)
end
reset()
fail = true
refresh()
assert(#notifications == 1 and notifications[1].level == "error")
assert(#sent == 0 and #events == 0, "deletion errors must not be reported as a refresh")
reset()
switch = true
refresh()
assert(#sent == 0, "a late refresh must not queue a file that is no longer hovered")
assert(events[1][2].only_if == video.url)
print("gridthumb refresh: cache removal, forced DDS regeneration, skip, missing files, errors and stale hover passed")
