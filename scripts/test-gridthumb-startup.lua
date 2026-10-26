-- Run with: lua scripts/test-gridthumb-startup.lua [plugin-path]
local plugin, state, local_events, remote_events, events, sent, notifications
local alive, ticks, launched, sleep_hook
Url = function(value) return value end
cx = { active = { current = { hovered = { url = "a.mkv" } } } }
fs = { cha = function(path)
    if path:match("%.mkv$") then return { len = 123, mtime = 1000 } end
end }
ya = {
    sync = function(fn) return function(...) return fn(state, ...) end end,
    quote = function(value) return '"' .. value .. '"' end,
    dbg = function() end,
    emit = function(action, args)
        events[#events + 1] = { action, args }
        if action == "shell" then
            assert(args.orphan == true, "service must survive plugin job/Yazi exit")
            launched = launched + 1
        end
    end,
    sleep = function()
        ticks = ticks + 1
        if launched > 0 and ticks >= 6 and alive ~= "never" then alive = true end
        if sleep_hook then sleep_hook() end
    end,
    notify = function(body) notifications[#notifications + 1] = body end,
}
ps = {
    sub = function(event, fn) local_events[event] = fn end,
    sub_remote = function(event, fn) remote_events[event] = fn end,
    pub_to = function(receiver, event, body)
        assert(receiver == 0)
        sent[#sent + 1] = { event, body }
        if event == "vimg-gridthumb-ping" and alive == true then
            remote_events["gridthumb-service-ready"] { token = body.token }
        end
    end,
}
plugin = dofile(arg[1] or "gridthumb.yazi/main.lua")
local function reset(options)
    state, local_events, remote_events, events, sent, notifications = {}, {}, {}, {}, {}, {}
    alive, ticks, launched, sleep_hook = false, 0, 0, nil
    cx.active.current.hovered = { url = "a.mkv" }
    plugin.setup(state, options)
end
local function request(file, refresh)
    plugin:generate_avif({ file = { url = file or "a.mkv" } }, "cache", refresh)
end
local function run_start()
    local token = assert(events[1][2][2]:match("^start (%d+)$"))
    plugin:entry { args = { "start", token } }
end
local function requests()
    local result = {}
    for _, message in ipairs(sent) do
        if message[1] == "vimg-gridthumb-request" then result[#result + 1] = message[2] end
    end
    return result
end
reset { vimg = "D:/preview tools/vimg.exe", ya = "D:/Yazi tools/ya.exe", service_args = { "--jobs", "2" } }
request()
assert(#requests() == 0 and #events == 1, "first request must wait for service readiness")
request(nil, true)
request() -- A following normal preview must not erase the pending refresh.
assert(#events == 1)
run_start()
assert(launched == 1 and #requests() == 1 and requests()[1].refresh)
assert(requests()[1].latest and not state.service_starting)
assert(events[2][2][1] == '"D:/preview tools/vimg.exe" serve --ya "D:/Yazi tools/ya.exe" "--jobs" "2"')
assert(#notifications == 0)
-- Already running: probe it without starting another executable.
request()
local token = state.service_token
plugin:entry { args = { "start", tostring(token) } }
assert(launched == 1 and #requests() == 2)
-- A service that later dies is started again on the next request.
alive, ticks = false, 0
request()
plugin:entry { args = { "start", tostring(state.service_token) } }
assert(launched == 2 and #requests() == 3)
-- Switching files while starting only publishes the latest hovered request.
reset()
request()
cx.active.current.hovered = { url = "b.mkv" }
local_events.hover()
request("a.mkv")
request("b.mkv", true)
run_start()
assert(#requests() == 1 and requests()[1].file == "b.mkv" and requests()[1].refresh)
-- A late response and an old async startup cannot affect a newer probe.
reset()
request()
remote_events["gridthumb-service-ready"] { token = 0 }
plugin:entry { args = { "start", "0" } }
assert(#requests() == 0 and launched == 0 and state.service_starting)
-- Bounded failure leaves a static preview and allows F5 to retry.
alive = "never"
run_start()
assert(#notifications == 1 and notifications[1].level == "error")
assert(not state.service_starting and state.pending == nil and #requests() == 0)
request()
assert(state.service_starting)
reset { auto_start = false }
request()
assert(#requests() == 1 and #events == 0)
print("gridthumb startup: lazy launch, ready handshake, reuse, restart, pending refresh, stale selection and timeout passed")
