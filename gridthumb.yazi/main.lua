local M = {}
local media_descriptors = {}
local grid_format = ya.sync(function(state)
	return state.grid_format or "avif"
end)
local function dds_event(format, kind)
	return "vimg-gridthumb-" .. (format == "webp" and "webp-" or "") .. kind
end
local function active_tab()
	return cx.active or cx.tab
end
local function file_stat(url)
	return (fs.stat or fs.cha)(url)
end
local vimg_preview_available = ya.sync(function(state, available)
	if available ~= nil then
		state.vimg_preview_available = available
	end
	return state.vimg_preview_available ~= false, state.preview_helper, state.vimg or "vimg"
end)
local set_preview_helper = ya.sync(function(state, helper)
	state.preview_helper = helper
end)
local helper_extensions = { mkv = true, webm = true, mp4 = true, mov = true,
	m4v = true, m4a = true, ["3gp"] = true, ["3g2"] = true, mj2 = true }
local vimg_probe_available = ya.sync(function(state, available)
	if available ~= nil then
		state.vimg_probe_available = available
	end
	return state.vimg_probe_available ~= false, state.vimg or "vimg"
end)
local function cancel_stale_preview(state)
	local hovered = active_tab().current.hovered
	if state.preview and (not hovered or state.preview.file ~= tostring(hovered.url)) then
		ps.pub_to(0, dds_event(state.grid_format, "cancel"), { cache = state.preview.cache })
		state.preview = nil
		state.pending = nil
	end
end

local function publish_current_request(state, request)
	cancel_stale_preview(state)
	local hovered = active_tab().current.hovered
	-- An async preload may finish after the user has moved to another file.
	if not hovered or request.file ~= tostring(hovered.url) then
		return
	end
	state.preview = { file = request.file, cache = request.cache }
	request.latest = true
	ps.pub_to(0, dds_event(state.grid_format, "request"), request)
end

local publish_avif_request = ya.sync(function(state, request)
	if not state.auto_start then
		return publish_current_request(state, request)
	end
	cancel_stale_preview(state)
	local hovered = active_tab().current.hovered
	if not hovered or request.file ~= tostring(hovered.url) then
		return
	end
	if state.pending and state.pending.cache == request.cache then
		request.refresh = request.refresh or state.pending.refresh
	end
	state.preview = { file = request.file, cache = request.cache }
	state.pending = request
	if not state.service_starting then
		state.service_starting = true
		state.service_token = (state.service_token or 0) + 1
		ya.emit("plugin", { "gridthumb", "start " .. state.service_token })
	end
end)

local service_probe = ya.sync(function(state, token, finish)
	local ready = not state.service_starting or token ~= state.service_token
	if ready then
		return true
	elseif finish then
		state.service_starting = false
		state.pending = nil
	elseif state.service_starting then
		ps.pub_to(0, dds_event(state.grid_format, "ping"), { token = state.service_token })
	end
	return not state.service_starting, state.vimg or "vimg", state.service_args or {}, state.ya
end)

local refresh_target = ya.sync(function()
	local hovered = active_tab().current.hovered
	local mime = hovered and hovered:mime()
	if mime and mime:match("^video/") then
		local skip = active_tab().preview.skip or 0
		return {
			file = { url = hovered.url },
			skip = skip,
			cache = ya.file_cache { file = hovered.bare or hovered, skip = skip },
		}
	end
end)

local function source_descriptor(url)
	local cha = file_stat(url)
	if not cha or not cha.len or not cha.mtime then
		return nil
	end
	local modified = type(cha.mtime) == "number" and cha.mtime or cha.mtime.unix
	if not modified then
		return nil
	end
	return { size = cha.len, modified_s = math.floor(modified) }
end

local function grid_is_current(file_url, grid)
	local source = source_descriptor(file_url)
	if not source then
		return false
	end
	local cha_grid = file_stat(grid)
	local manifest = Url(string.format("%s.%d-%d.json", tostring(grid), source.size, source.modified_s))
	local cha_manifest = file_stat(manifest)
	return cha_grid and cha_grid.len > 0 and cha_manifest and cha_manifest.len > 0
end

local function media_descriptor(url, meta)
	local source = source_descriptor(url)
	if not source then
		return nil
	end
	local descriptor = {
		size = source.size,
		modified_s = source.modified_s,
		duration_s = tonumber(meta.format.duration),
	}
	local video_stream, video_stream_count
	for _, stream in ipairs(meta.streams or {}) do
		if stream.codec_type == "video" and stream.width and stream.height
			and not (stream.disposition and stream.disposition.attached_pic == 1) then
			video_stream = video_stream or stream
			video_stream_count = (video_stream_count or 0) + 1
		end
	end
	if video_stream then
		descriptor.width = video_stream.width
		descriptor.height = video_stream.height
		-- FFmpeg chooses its default video stream. A time base is only safe to
		-- reuse without probing when there is exactly one non-cover video stream.
		if video_stream_count == 1 then
			descriptor.codec = video_stream.codec_name
			local numerator, denominator = (video_stream.time_base or ""):match("^(%d+)/(%d+)$")
			numerator, denominator = tonumber(numerator), tonumber(denominator)
			if numerator and denominator and numerator > 0 and denominator > 0
				and numerator <= 2147483647 and denominator <= 2147483647 then
				descriptor.source_time_base_numerator = numerator
				descriptor.source_time_base_denominator = denominator
			end
		end
	end
	return descriptor
end

function M:setup(options)
	options = options or {}
	self.vimg = options.vimg or "vimg"
	self.ya = options.ya
	self.grid_format = options.grid_format == "webp" and "webp" or "avif"
	self.auto_start = options.auto_start ~= false
	self.service_args = options.service_args or {}
	self.preview_helper = options and options.preview_helper or nil
	ps.sub("hover", function() cancel_stale_preview(self) end)
	ps.sub("tab", function() cancel_stale_preview(self) end)
	ps.sub_remote("gridthumb-service-ready", function(body)
		if not self.service_starting or not body or body.token ~= self.service_token then
			return
		end
		self.service_starting = false
		local request = self.pending
		self.pending = nil
		if request then
			publish_current_request(self, request)
		end
	end)
	ps.sub_remote("gridthumb-" .. self.grid_format .. "-ready", function(body)
		local hovered = active_tab().current.hovered
		if hovered and body and body.file == tostring(hovered.url) then
			ya.dbg("[gridthumb] grid ready:", tostring(body.cache))
			-- The source file is unchanged, but its animated cache is now ready.
			-- Force a new peek without resetting the current preview position.
			ya.emit("peek", { only_if = hovered.url, force = true })
		end
	end)
end

function M:start_service(token)
	-- Probe before launching so other Yazi instances reuse the running service.
	for _ = 1, 3 do
		if service_probe(token) then
			return
		end
		ya.sleep(0.1)
	end
	local ready, executable, args, ya_executable = service_probe(token)
	if ready then
		return
	end
	local command = ya.quote(executable) .. " serve"
	if ya_executable then
		command = command .. " --ya " .. ya.quote(ya_executable)
	end
	for _, arg in ipairs(args) do
		command = command .. " " .. ya.quote(tostring(arg))
	end
	-- Yazi owns detachment and quoting; a dropped Command child would be killed.
	ya.emit("shell", { command, orphan = true })
	for _ = 1, 50 do
		ya.sleep(0.1)
		if service_probe(token) then
			return
		end
	end
	service_probe(token, true)
	ya.notify { title = "gridthumb", content = "Preview service did not respond: " .. executable .. "; check vimg and ya versions/PATH", level = "error", timeout = 8 }
end

--- Bind `plugin gridthumb refresh` to a key in keymap.toml.
function M:entry(job)
	if job.args[1] == "start" then
		return self:start_service(tonumber(job.args[2]))
	elseif job.args[1] ~= "refresh" then
		return
	end
	local target = refresh_target()
	if not target then
		return
	end
	local cache = target.cache
	if not cache then
		return
	end
	local grid = Url(tostring(cache) .. "." .. grid_format())
	local paths = { cache, grid }
	local source = source_descriptor(target.file.url)
	if source then
		paths[#paths + 1] = Url(string.format("%s.%d-%d.json", tostring(grid), source.size, source.modified_s))
	end
	for _, path in ipairs(paths) do
		local ok, err = fs.remove("file", path)
		if not ok and err and err.kind ~= "NotFound" then
			return ya.notify { title = "gridthumb", content = "Cannot clear preview cache: " .. tostring(err), level = "error", timeout = 5 }
		end
	end
	media_descriptors[tostring(target.file.url)] = nil
	-- Force regeneration even if a previous capture republishes its cache while
	-- these files are being removed. The service coalesces in-flight refreshes.
	self:generate_avif(target, cache, true)
	ya.emit("peek", { only_if = target.file.url, force = true })
end

function M:peek(job)
	local start, cache = os.clock(), ya.file_cache(job)
	if not cache then
		return
	end

	local grid = Url(tostring(cache) .. "." .. grid_format())
	if grid_is_current(job.file.url, grid) then
		ya.sleep(math.max(0, rt.preview.image_delay / 1000 + start - os.clock()))
		local _, err = ya.image_show(grid, job.area)
		return ya.preview_widget(job, err)
	end

	-- Fallback: run preload (ffmpeg + vimg)
	local ok, err = self:preload(job)
	if not ok or err then
		return ya.preview_widget(job, err)
	end

	-- Show static image
	ya.sleep(math.max(0, rt.preview.image_delay / 1000 + start - os.clock()))
	local _, err = ya.image_show(cache, job.area)
	ya.preview_widget(job, err)

	-- Queue the grid; the service notifies this instance when it is ready.
	self:generate_avif(job, cache)
end

function M:seek(job)
	local h = active_tab().current.hovered
	if h and h.url == job.file.url then
		ya.emit("peek", {
			math.max(0, active_tab().preview.skip + job.units),
			only_if = job.file.url,
		})
	end
end

function M:preload(job)
	ya.dbg("[gridthumb] preload:", tostring(job.file.url))
	local cache = ya.file_cache(job)
	if not cache then
		return true
	end

	local format = grid_format()
	local grid = Url(tostring(cache) .. "." .. format)
	if grid_is_current(job.file.url, grid) then
		return true
	end

	local cha = file_stat(cache)
	local meta, err
	if not (cha and cha.len > 0) then
		meta = self.prepare_preview(job, cache)
	end
	if not meta then
		meta, err = self.list_preview_meta(job.file.url)
	end
	if not meta then
		return true, err
	elseif not meta.format.duration then
		return true, Err("Failed to get video duration")
	end
	media_descriptors[tostring(job.file.url)] = media_descriptor(job.file.url, meta)

	local pic = M.has_pic(meta)
	local percent = (pic and 0 or 5) + job.skip
	if percent > 95 then
		ya.emit("peek", { pic and 95 or 90, only_if = job.file.url, upper_bound = true })
		return false
	end

	-- method 1: ffmpeg single-frame cache (skip if exists)
	local cha = file_stat(cache)
	if not (cha and cha.len > 0) then
		if format == "webp" then
			return true, Err("%s", meta.preview_fallback or "Dart preview could not decode a frame")
		end
		-- A single keyframe does not amortize hardware-device initialization.
		-- Keep decoding on the CPU; animated grids use the service's backend.
		-- Bound filter and JPEG worker startup for this single-frame command.
		-- stylua: ignore
		local cmd = Command("ffmpeg"):arg({
			"-v", "quiet", "-threads", 1, "-filter_threads", 1,
			"-skip_frame", "nokey",
			"-an", "-sn", "-dn",
		})

		if percent ~= 0 then
			cmd:arg { "-ss", math.floor(meta.format.duration * percent / 100) }
		end
		cmd:arg { "-i", tostring(job.file.url) }
		if percent == 0 then
			cmd:arg { "-map", "disp:attached_pic" }
		end

		-- stylua: ignore
		local status, err = cmd:arg({
			"-vframes", 1, "-threads:v", 1,
			"-q:v", 31 - math.floor(rt.preview.image_quality * 0.3),
			"-vf", string.format("scale='min(%d,iw)':'min(%d,ih)':force_original_aspect_ratio=decrease:flags=fast_bilinear", rt.preview.max_width, rt.preview.max_height),
			"-f", "image2",
			"-y", tostring(cache),
		}):status()

		if not status then
			return true, Err("Failed to start `ffmpeg`, error: %s", err)
		elseif not status.success then
			return false, Err("`ffmpeg` exited with error code: %s", status.code)
		end
	end

	return true
end

--- Queue grid generation via vimg serve without delaying the static preview.
function M:generate_avif(job, cache, refresh)
	local grid = tostring(cache) .. "." .. grid_format()
	if not refresh and grid_is_current(job.file.url, Url(grid)) then
		return
	end

	local file_url = tostring(job.file.url)
	local source = media_descriptors[file_url] or source_descriptor(job.file.url)
	if not source then
		return
	end
	local request = {
		file = file_url,
		cache = grid,
		source_size = source.size,
		source_modified_s = source.modified_s,
		refresh = refresh or nil,
	}
	if source.duration_s then
		request.duration_s = source.duration_s
	end
	if source.width and source.height then
		request.width = source.width
		request.height = source.height
	end
	if source.codec then
		request.codec = source.codec
	end
	if source.source_time_base_numerator and source.source_time_base_denominator then
		request.source_time_base_numerator = source.source_time_base_numerator
		request.source_time_base_denominator = source.source_time_base_denominator
	end
	ya.dbg("[gridthumb] vimg DDS:", file_url, "->", grid)
	publish_avif_request(request)
end

function M:spot(job)
	local rows = self:spot_base(job)
	rows[#rows + 1] = ui.Row {}

	ya.spot_table(
		job,
		ui.Table(ya.list_merge(rows, require("file"):spot_base(job)))
			:area(ui.Pos { "center", w = 60, h = 20 })
			:row(1)
			:col(1)
			:col_style(th.spot.tbl_col)
			:cell_style(th.spot.tbl_cell)
			:widths { ui.Constraint.Length(14), ui.Constraint.Fill(1) }
	)
end

function M:spot_base(job)
	local meta, err
	if grid_format() == "webp" then
		meta, err = self.list_preview_meta(job.file.url)
	else
		meta, err = self.list_meta(job.file.url, "format=duration:stream=codec_name,codec_type,width,height")
	end
	if not meta then
		ya.err(tostring(err))
		return {}
	end

	local dur = meta.format.duration or 0
	local rows = {
		ui.Row({ "Video" }):style(ui.Style():fg("green")),
		ui.Row { "  Duration:", string.format("%d:%02d", math.floor(dur / 60), math.floor(dur % 60)) },
	}

	for i, s in ipairs(meta.streams) do
		if s.codec_type == "video" then
			rows[#rows + 1] = ui.Row { string.format("  Stream %d:", i), "video" }
			rows[#rows + 1] = ui.Row { "    Codec:", s.codec_name }
			rows[#rows + 1] = ui.Row { "    Size:", string.format("%dx%d", s.width, s.height) }
		elseif s.codec_type == "audio" then
			rows[#rows + 1] = ui.Row { string.format("  Stream %d:", i), "audio" }
			rows[#rows + 1] = ui.Row { "    Codec:", s.codec_name }
		end
	end
	return rows
end

function M.list_preview_meta(url)
	-- The native build probes with libav in a much smaller process. Older or
	-- unavailable vimg installations retain the original ffprobe path.
	local output
	local available, executable = vimg_probe_available()
	if available then
		output = Command(executable):arg({ "probe", "--", tostring(url) }):output()
		if not output or output.status.code == 2 then
			vimg_probe_available(false)
		end
	end
	if output and output.status.success then
		local meta = ya.json_decode(output.stdout)
		if type(meta) == "table" and type(meta.format) == "table"
			and tonumber(meta.format.duration) and tonumber(meta.format.duration) > 0
			and type(meta.streams) == "table" and #meta.streams > 0 then
			if meta.native_probe == false then
				vimg_probe_available(false)
			end
			return meta
		end
	end
	if grid_format() == "webp" then
		return nil, Err("Dart probe could not read preview metadata")
	end
	return M.list_meta(url, "format=duration:stream=codec_name,codec_type,width,height,time_base:stream_disposition=attached_pic")
end

function M.prepare_preview(job, cache)
	local available, helper, executable = vimg_preview_available()
	if not available then
		return
	end
	-- The private helper runtime supports the Matroska and MOV families. Keep
	-- other extensions on the full command to avoid an extra failed process.
	local extension = tostring(job.file.url):match("%.([^./\\]+)$")
	if not (extension and helper_extensions[extension:lower()]) then
		helper = nil
	end
	local args = {
		"preview", "--output", tostring(cache), "--skip", tostring(job.skip),
		"--max-width", tostring(rt.preview.max_width), "--max-height", tostring(rt.preview.max_height),
		"--quality", tostring(rt.preview.image_quality), "--", tostring(job.file.url),
	}
	local output = Command(helper or executable):arg(args):output()
	local meta
	if helper then
		if output and output.status.success then
			meta = ya.json_decode(output.stdout)
		end
		if not output or output.status.code == 2
			or (type(meta) == "table" and meta.native_preview == false) then
			-- A missing/old helper must not disable the full vimg capabilities.
			set_preview_helper(nil)
			output, meta = Command(executable):arg(args):output(), nil
		end
	end
	if not output then
		vimg_preview_available(false)
		vimg_probe_available(false)
		return
	elseif output.status.code == 2 then
		-- Old vimg may still support the separate probe command.
		vimg_preview_available(false)
		return
	elseif not output.status.success then
		return
	end
	meta = meta or ya.json_decode(output.stdout)
	if type(meta) ~= "table" then
		return
	elseif meta.native_preview == false then
		vimg_preview_available(false)
		if meta.native_probe == false then
			vimg_probe_available(false)
		end
		return
	end
	-- A native per-file fallback can still reuse its complete metadata. The
	-- usual cache check below decides whether FFmpeg must extract the image.
	if type(meta.format) == "table" and tonumber(meta.format.duration)
		and tonumber(meta.format.duration) > 0
		and type(meta.streams) == "table" and #meta.streams > 0 then
		return meta
	end
end

function M.list_meta(url, entries)
	local cmd = Command("ffprobe"):arg { "-v", "quiet" }
	if not entries:find("attached_pic", 1, true) then
		cmd:arg { "-select_streams", "v" }
	end

	local output, err = cmd:arg({ "-show_entries", entries, "-of", "json=c=1", tostring(url) }):output()
	if not output then
		return nil, Err("Failed to start `ffprobe`, error: %s", err)
	end

	local t = ya.json_decode(output.stdout)
	if not t then
		return nil, Err("Failed to decode `ffprobe` output: %s", output.stdout)
	elseif type(t) ~= "table" then
		return nil, Err("Invalid `ffprobe` output: %s", output.stdout)
	end

	t.format = t.format or {}
	t.streams = t.streams or {}
	return t
end

function M.has_pic(meta)
	for _, s in ipairs(meta.streams) do
		if s.disposition and s.disposition.attached_pic == 1 then
			return true
		end
	end
end

return M
