-- Run with: lua scripts/test-gridthumb-requests.lua [plugin-path]
local plugin, sent, local_events, remote_events, refreshes = nil, {}, {}, {}, 0
Url = function(value) return value end
cx = { active = { current = { hovered = { url = "a.mkv" } } } }
ya = {
    sync = function(fn) return function(request) return fn(plugin, request) end end,
    dbg = function() end,
    emit = function(action, args)
        assert(action == "peek" and args.force == true, "ready must bypass Yazi's unchanged-file preview lock")
        assert(args.only_if == cx.active.current.hovered.url and args[1] == nil,
            "ready must target the hovered file without resetting its preview position")
        refreshes = refreshes + 1
    end,
}
fs = { cha = function(url)
    if url:match("%.mkv$") then return { len = 123, mtime = 1000 } end
end }
ps = {
    pub_to = function(receiver, event, body)
        assert(receiver == 0)
        sent[#sent + 1] = { event = event, body = body }
    end,
    sub = function(event, callback) local_events[event] = callback end,
    sub_remote = function(event, callback) remote_events[event] = callback end,
}
plugin = dofile(arg[1] or "gridthumb.yazi/main.lua")
plugin:setup()
local function request(file, cache)
    plugin:generate_avif({ file = { url = file } }, cache)
end
request("a.mkv", "a")
assert(#sent == 1 and sent[1].body.latest == true, "preview must opt into latest interest")
local_events.hover({})
assert(#sent == 1, "repeated hover must not cancel current preview")
cx.active.current.hovered = { url = "b.mkv" }
local_events.hover({})
assert(#sent == 2 and sent[2].event == "vimg-gridthumb-cancel")
assert(sent[2].body.cache == "a.avif")
request("a.mkv", "a")
assert(#sent == 2, "late async completion must not requeue an abandoned preview")
request("b.mkv", "b")
assert(#sent == 3 and sent[3].body.file == "b.mkv")
-- A cache hit, non-video file, or tab switch may never call generate_avif.
cx.active.current.hovered = { url = "cached-or-text.txt" }
local_events.tab({})
assert(#sent == 4 and sent[4].body.cache == "b.avif")
cx.active.current.hovered = nil
local_events.hover({})
assert(#sent == 4, "one interest must be cancelled at most once")
-- Publishing also checks current selection if it precedes the hover callback.
cx.active.current.hovered = { url = "a.mkv" }
request("a.mkv", "a")
cx.active.current.hovered = { url = "b.mkv" }
request("b.mkv", "b")
assert(#sent == 7 and sent[6].event == "vimg-gridthumb-cancel")
remote_events["gridthumb-avif-ready"]({ file = "a.mkv", cache = "a.avif" })
assert(refreshes == 0)
remote_events["gridthumb-avif-ready"]({ file = "b.mkv", cache = "b.avif" })
assert(refreshes == 1)
print("gridthumb requests: latest interest, hover/tab cancellation, stale completion, ready refresh passed")
