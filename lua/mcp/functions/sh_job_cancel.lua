-- job_cancel: abort a background job (from an async arm), tearing down its hooks
-- and side effects at once instead of waiting out its cap. Ungated -- it only
-- affects a job the caller already armed.

MCP:AddFunction({
    id = "job_cancel",
    description = "Abort a background job started with async=true, tearing down its hooks and side effects immediately (e.g. a screenshot's freecam view override). Pass the `job_id`, or `all=true` to cancel every armed job in this realm. A cancelled job can still be collected once (it reports status \"cancelled\").",
    schema = {
        type = "object",
        properties = {
            job_id = { type = "string", description = "The job to cancel." },
            all = { type = "boolean", description = "Cancel every armed job in this realm instead of one." },
        },
    },
    handler = function(args)
        args = args or {}
        if args.all then
            local cancelled = {}
            for id, job in pairs(MCP._jobs) do
                if job.status == "armed" then
                    MCP:CancelJob(id)
                    cancelled[#cancelled + 1] = id
                end
            end
            return { ok = true, cancelled = cancelled, count = #cancelled }
        end
        local jobId = args.job_id
        if type(jobId) ~= "string" or jobId == "" then
            return { ok = false, error = "pass `job_id` (or `all=true`)" }
        end
        local ok, status = MCP:CancelJob(jobId)
        if not ok then
            return { ok = false, error = "unknown or expired job: " .. jobId }
        end
        return { ok = true, job_id = jobId, status = status }
    end,
})
