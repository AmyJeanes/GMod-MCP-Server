-- job_collect: fetch the result of a background job (a tool called with
-- async=true). Blocks up to `wait` for it to finish, else returns status
-- "pending" so the agent polls again -- the block-or-poll shape debug_record_read
-- uses. A completion also arrives passively on any later tool result (sh_jobs.lua),
-- so the outcome may already be known; this retrieves the full payload. Ungated:
-- it only reads a slot the async arm (gated as its underlying tool) created.

local DEFAULT_WAIT = 45
local MAX_WAIT = 55

MCP:AddFunction({
    id = "job_collect",
    timeout = MAX_WAIT + 3,
    description = "Fetch the result of a background job started by calling a tool with async=true, identified by the `job_id` the arm returned. Blocks up to `wait` seconds for the job to finish, then returns the tool's own result verbatim (the same shape as calling it synchronously). If it's still running when `wait` elapses, returns status \"pending\" -- call again to keep waiting, or pass wait=0 to poll once. A cancelled job returns status \"cancelled\". Completions also ride any later tool result's `events`, so you may already know the outcome; this retrieves the full payload. The job is forgotten once collected.",
    schema = {
        type = "object",
        properties = {
            job_id = {
                type = "string",
                description = "The job_id returned when the tool was armed with async=true.",
            },
            wait = {
                type = "number",
                minimum = 0,
                maximum = MAX_WAIT,
                description = "Max seconds to block waiting for the job to finish (default 45, max 55). 0 polls once and returns immediately.",
            },
        },
        required = { "job_id" },
    },
    handler = function(args, ctx)
        args = args or {}
        local jobId = args.job_id
        if type(jobId) ~= "string" or jobId == "" then
            return { ok = false, error = "`job_id` is required" }
        end
        local job = MCP._jobs[jobId]
        if not job then
            return { ok = false, error = "unknown or expired job: " .. jobId .. " (already collected, or reaped after its TTL)" }
        end

        local function terminal()
            MCP:ForgetJob(jobId)
            if job.status == "finished" then
                return job.result or { ok = false, error = "job finished without a result" }
            end
            return { ok = true, status = "cancelled", job_id = jobId, tool = job.tool }
        end
        local function pending()
            return {
                ok = true,
                status = "pending",
                job_id = jobId,
                tool = job.tool,
                elapsed = math.Round(RealTime() - job.armedAt, 2),
                note = "Job still running; call job_collect again to keep waiting.",
            }
        end

        if job.status ~= "armed" then return terminal() end

        local wait = math.Clamp(tonumber(args.wait) or DEFAULT_WAIT, 0, MAX_WAIT)
        if wait <= 0 then return pending() end

        MCP:RunFor({ seconds = wait, stop = function() return job.status ~= "armed" end }, function()
            if job.status ~= "armed" then
                ctx.respond(terminal())
            else
                ctx.respond(pending())
            end
        end)
        return ctx.deferred
    end,
})
