-- Sampling core shared by the debug_record family. Extracted from sh_debug_record so the
-- interactive on-screen recorder (cl_debug_record_interactive) drives the exact same per-fire
-- recording, downsampling, and stats/histogram logic behind its HUD phase machine.
--
-- A sampler owns: a shared `state` table (passed to every caller snippet so a probe can carry
-- data frame-to-frame), a raw buffer, and full-resolution stats/histogram accumulators (kept as
-- recorded, so the true min/max and tallies survive the on-return downsample). It does NOT own
-- the hook or the timing window -- the consumer installs the hook and calls :Fire(...) each fire,
-- and ends the window however it likes (debug_record via MCP:RunFor's duration backstop; the
-- interactive tool via its HUDPaint phase machine). Never return a value from the hooked function
-- for movement hooks (SetupMove/CreateMove/StartCommand) -- :Fire never does.

MCP.sampler = MCP.sampler or {}

local DEFAULT_RAW_CEILING = 5000  -- hard memory cap on raw samples, independent of max_samples
local DEFAULT_SAMPLE_DEPTH = 4    -- per-sample serialization caps so one fat sample can't blow up
local DEFAULT_SAMPLE_NODES = 80   -- (the whole-response node cap is the ultimate backstop)
local DEFAULT_HIST_CAP = 100      -- max distinct values returned in the histogram tally

-- Compile a caller snippet as a function body receiving the shared `state` table, then the
-- hook's args as `...`. Returns the function, or nil + the compile error string.
function MCP.sampler.Compile(src, name)
    local chunk = CompileString("return function(state, ...)\n" .. src .. "\nend", name, false)
    if type(chunk) == "string" then return nil, chunk end
    return chunk()
end

-- Evenly downsample to `target` points, always keeping the first and last. Returns the
-- (possibly unchanged) array and whether it was downsampled.
function MCP.sampler.Downsample(arr, target)
    local n = #arr
    if n <= target then return arr, false end
    local out = {}
    for i = 0, target - 1 do
        out[#out + 1] = arr[math.floor(1 + i * (n - 1) / (target - 1) + 0.5)]
    end
    return out, true
end

-- Compact an array to every 2nd element in place (1,3,5,...), halving its length. Used by the
-- decimate-on-full path to keep a full time window under the raw ceiling at uniform resolution.
local function compactHalf(arr)
    local n = #arr
    local w = 0
    for i = 1, n, 2 do
        w = w + 1
        arr[w] = arr[i]
    end
    for i = w + 1, n do arr[i] = nil end
end

local Sampler = {}
Sampler.__index = Sampler

-- opts: { sample (fn, required), stop (fn?), interval?, max_samples?, want_stats?, want_histogram?,
--         tag_curtime?, decimate_on_full?, raw_ceiling?, sample_depth?, sample_nodes?, hist_cap? }
-- decimate_on_full: when the raw buffer fills, halve it + double the sampling stride and keep going
-- (a time-bounded recorder covers its WHOLE window at reduced resolution) instead of ending with
-- reason "overflow". Off by default, so debug_record's overflow behaviour is unchanged.
-- tag_curtime adds `ct = CurTime()` to each row -- the shared tick clock, so two samplers on
-- different realms recording the same window line up on `ct` (the cross-realm alignment key).
---@param opts table
function MCP.sampler.New(opts)
    opts = opts or {}
    local s = setmetatable({
        sampleFn = opts.sample,
        stopFn = opts.stop,
        interval = math.max(tonumber(opts.interval) or 0, 0),
        maxSamples = math.Clamp(math.floor(tonumber(opts.max_samples) or 100), 2, 500),
        wantStats = opts.want_stats and true or false,
        wantHistogram = opts.want_histogram and true or false,
        tagCurtime = opts.tag_curtime and true or false,
        decimateOnFull = opts.decimate_on_full and true or false,
        rawCeiling = tonumber(opts.raw_ceiling) or DEFAULT_RAW_CEILING,
        sampleDepth = tonumber(opts.sample_depth) or DEFAULT_SAMPLE_DEPTH,
        sampleNodes = tonumber(opts.sample_nodes) or DEFAULT_SAMPLE_NODES,
        histCap = tonumber(opts.hist_cap) or DEFAULT_HIST_CAP,
        state = {}, -- shared across init/sample/stop so a probe can carry state between fires
    }, Sampler)
    s:Reset()
    return s
end

-- Clear the buffer and accumulators and (re)start the clock. Call before a fresh window (the
-- interactive tool calls this on every attempt, including retries). Leaves `state` alone -- the
-- consumer decides whether to re-seed it via init.
function Sampler:Reset()
    self.buffer = {}
    self.start = RealTime()
    self.lastSampleT = nil
    self.doneReason = nil
    self.doneErr = nil
    self.lastValue = nil
    self.agg = { numeric = 0, sum = 0, min = nil, max = nil }
    self.tally = {}
    self.tallyDistinct = 0
    self.decimStride = 1 -- append 1-in-N to the buffer; grows as decimate-on-full compacts
    self.decimPhase = 0
end

-- Process one hook fire. Stop is checked every fire so an event is caught promptly; only
-- sampling is throttled by `interval`, and the stop moment still records a final sample. A nil
-- sample return skips the fire (the throttle only advances on a real record). Sets
-- self.doneReason on stop/error/overflow. Returns doneReason (or nil). Idempotent once done.
function Sampler:Fire(...)
    if self.doneReason then return self.doneReason end
    local now = RealTime()

    local stopHit = false
    if self.stopFn then
        local sok, sres = pcall(self.stopFn, self.state, ...)
        if not sok then self.doneReason, self.doneErr = "error", tostring(sres) return self.doneReason end
        stopHit = sres and true or false
    end

    local due = self.interval <= 0 or not self.lastSampleT or (now - self.lastSampleT) >= self.interval
    if stopHit or due then
        local ok, val = pcall(self.sampleFn, self.state, ...)
        if not ok then self.doneReason, self.doneErr = "error", tostring(val) return self.doneReason end
        if val ~= nil then
            self.lastSampleT = now
            self.lastValue = val
            -- Stats/histogram accumulate on EVERY sampled value (full resolution), independent of
            -- the buffer decimation below -- so the true min/max and tallies survive.
            if isnumber(val) then
                local a = self.agg
                a.numeric = a.numeric + 1
                a.sum = a.sum + val
                if not a.min or val < a.min then a.min = val end
                if not a.max or val > a.max then a.max = val end
            end
            if self.wantHistogram then
                local key = isstring(val) and val or tostring(val)
                if self.tally[key] == nil then self.tallyDistinct = self.tallyDistinct + 1 end
                self.tally[key] = (self.tally[key] or 0) + 1
            end
            -- Append 1-in-`decimStride` to the raw buffer. When it fills, `overflow` ends recording
            -- (default) OR decimate-on-full halves it + doubles the stride and keeps going, so a
            -- time-bounded recorder covers its whole window instead of ending short.
            self.decimPhase = self.decimPhase + 1
            if self.decimPhase >= self.decimStride then
                self.decimPhase = 0
                local row = {
                    t = math.Round(now - self.start, 3),
                    v = MCP.util.Serialize(val, { max_depth = self.sampleDepth, max_nodes = self.sampleNodes }),
                }
                if self.tagCurtime then row.ct = math.Round(CurTime(), 3) end
                self.buffer[#self.buffer + 1] = row
                if #self.buffer >= self.rawCeiling then
                    if self.decimateOnFull then
                        compactHalf(self.buffer)
                        self.decimStride = self.decimStride * 2
                    else
                        self.doneReason = "overflow" return self.doneReason
                    end
                end
            end
        end
    end

    if stopHit then self.doneReason = "stop" end
    return self.doneReason
end

-- Build the series + stats payload: reason/sample_count/returned/downsampled/samples, plus
-- aggregate (numeric stats) / histogram (categorical tally) when requested, and error on a
-- snippet throw. The consumer merges realm/hook/seconds_elapsed/ok around it.
function Sampler:Result()
    local samples, down = MCP.sampler.Downsample(self.buffer, self.maxSamples)
    local out = {
        reason = self.doneReason or "duration",
        sample_count = #self.buffer,
        returned = #samples,
        downsampled = down,
        samples = samples,
    }
    if self.wantStats then
        local a = self.agg
        out.aggregate = {
            numeric_count = a.numeric,
            min = a.min,
            max = a.max,
            sum = a.numeric > 0 and math.Round(a.sum, 4) or nil,
            avg = a.numeric > 0 and math.Round(a.sum / a.numeric, 4) or nil,
        }
    end
    if self.wantHistogram then
        local rows = {}
        for k, c in pairs(self.tally) do rows[#rows + 1] = { value = k, count = c } end
        table.sort(rows, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.value < b.value
        end)
        if #rows > self.histCap then
            local trimmed = {}
            for i = 1, self.histCap do trimmed[i] = rows[i] end
            rows = trimmed
            out.histogram_truncated = true
        end
        out.histogram = rows
        out.distinct_count = self.tallyDistinct
    end
    if self.doneErr then out.error = self.doneErr end
    return out
end
