-- Generic async "job" registry. Lets any tool that declares `asyncable = true`
-- run its deferred wait in the background instead of blocking the call: when such
-- a tool is called with `async = true`, MCP:Dispatch mints a job here, routes the
-- handler's eventual ctx.respond into the job's slot instead of the bridge, and
-- returns a job_id at once. The result is fetched later with the job_collect tool
-- (block-or-poll) and can be aborted with job_cancel. A completion also rides the
-- next tool response passively (the events rail, see RecordJobEvent), so the model
-- learns a job finished without polling.
--
-- Why this exists: a blocking wait can't be interleaved with the tool calls that
-- CAUSE its condition, and no single blocking call can exceed the host's ~60s
-- ceiling (RunFor also clamps there). Async removes both limits. The dispatch
-- layer is already async-capable (ctx.deferred/ctx.respond), so this is a thin
-- layer over it. Modelled on the interactive recorder's arm -> slot -> fill ->
-- collect/forget -> TTL-sweep lifecycle, generalized to any deferred tool.
--
-- Per-realm: server and client are separate Lua states, each with its own _jobs.
-- A job is collected on the realm it was armed in.

MCP._jobs = MCP._jobs or {}      -- job_id -> job record
MCP._jobSeq = MCP._jobSeq or 0   -- monotonic; survives mcp_reload

local JOB_TTL = 300      -- reap a finished/cancelled job left uncollected this long
local ORPHAN_GRACE = 15  -- reap an armed job this long past its deadline (teardown-bug backstop)

---@class MCP.Job
---@field id string
---@field tool string
---@field realm string
---@field session string?
---@field status string        -- "armed" | "finished" | "cancelled"
---@field result table?        -- the tool's own response, once finished
---@field armedAt number
---@field finishedAt number?
---@field deadline number?     -- RealTime by which the handler should have resolved
---@field cancel fun()?        -- teardown from ctx.onCancel; removes the tool's hooks

-- Allocate the next job id. Dispatch mints one only when a call actually arms
-- (the handler deferred), so the sequence has no cosmetic gaps in practice.
---@return string
function MCP:NextJobId()
    self._jobSeq = (self._jobSeq or 0) + 1
    return "mcp_job_" .. self._jobSeq
end

-- Register a freshly-armed job (handler returned ctx.deferred). `info` carries
-- { tool, session, cancel, deadline }.
---@param jobId string
---@param info table
function MCP:RegisterJob(jobId, info)
    self:SweepJobs()
    self._jobs[jobId] = {
        id = jobId,
        tool = info.tool,
        realm = MCP.util.RealmName(),
        session = info.session,
        status = "armed",
        result = nil,
        armedAt = RealTime(),
        finishedAt = nil,
        deadline = info.deadline,
        cancel = info.cancel,
    }
end

-- The handler resolved (its ctx.respond fired). Store the result and emit the
-- passive completion notice. Guarded on "armed" so a late resolve after a cancel
-- (a racing hook, an internal cap firing post-teardown) is a harmless no-op.
---@param jobId string
---@param result table
function MCP:CompleteJob(jobId, result)
    local job = self._jobs[jobId]
    if not job or job.status ~= "armed" then return end
    job.status = "finished"
    job.result = result
    job.finishedAt = RealTime()
    self:RecordJobEvent(job)
end

-- Abort an armed job: run its teardown (remove hooks / release side effects),
-- mark it cancelled. Kept for one job_collect, then TTL-reaped.
---@param jobId string
---@return boolean ok, string status
function MCP:CancelJob(jobId)
    local job = self._jobs[jobId]
    if not job then return false, "unknown" end
    if job.status == "armed" then
        if job.cancel then pcall(job.cancel) end
        job.status = "cancelled"
        job.finishedAt = RealTime()
    end
    return true, job.status
end

---@param jobId string
function MCP:ForgetJob(jobId)
    self._jobs[jobId] = nil
end

-- Reap finished/cancelled jobs left uncollected past JOB_TTL, and armed jobs that
-- overran their deadline (a teardown-bug backstop -- the handler's own cap should
-- resolve it first). Runs on each arm and can be called from a read tool.
function MCP:SweepJobs()
    local now = RealTime()
    for id, job in pairs(self._jobs) do
        if job.status == "armed" then
            if job.deadline and now > (job.deadline + ORPHAN_GRACE) then
                if job.cancel then pcall(job.cancel) end
                self._jobs[id] = nil
            end
        elseif job.finishedAt and (now - job.finishedAt) > JOB_TTL then
            self._jobs[id] = nil
        end
    end
end

-- Passive completion notice on the events rail: recorded outside a handler so
-- attachEvents (sh_filebridge.lua) drains it onto the next tool response's
-- `events`, per-session and non-duplicative. Lightweight -- the full structured
-- result stays available via job_collect. A failure carries its error, and a
-- result with a `path` (screenshots) carries that, so a completion is often
-- actionable without a follow-up collect.
---@param job MCP.Job
function MCP:RecordJobEvent(job)
    local result = job.result
    local ok, extra = true, ""
    if type(result) == "table" then
        if result.ok == false then
            ok = false
            extra = ": " .. string.sub(tostring(result.error or "?"), 1, 200)
        elseif type(result.path) == "string" then
            extra = ": " .. result.path
        end
    end
    local text = string.format(
        "job %s (%s) finished %s%s. Full result via job_collect job_id=%s.",
        job.id, job.tool, ok and "ok" or "error", extra, job.id)
    self:RecordEvent("job", text, { job_id = job.id, tool = job.tool })
end
