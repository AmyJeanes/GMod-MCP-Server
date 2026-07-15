-- job_list: enumerate background jobs (from async=true arms) in this realm.
-- Read-only -- for seeing what's still running or recovering a lost job_id.

MCP:AddFunction({
    id = "job_list",
    description = "List background jobs (from async=true arms) in this realm: job_id, the tool, status (armed / finished / cancelled), seconds elapsed since arming, and whether it's collectable now. Pass `job_id` to report just one. Read-only.",
    schema = {
        type = "object",
        properties = {
            job_id = { type = "string", description = "Report only this job instead of all." },
        },
    },
    handler = function(args)
        args = args or {}
        MCP:SweepJobs()
        local now = RealTime()
        ---@param job MCP.Job
        local function view(job)
            return {
                job_id = job.id,
                tool = job.tool,
                status = job.status,
                elapsed = math.Round(now - job.armedAt, 2),
                finished_ago = job.finishedAt and math.Round(now - job.finishedAt, 2) or nil,
                collectable = job.status ~= "armed",
            }
        end
        local jobId = args.job_id
        if type(jobId) == "string" and jobId ~= "" then
            local job = MCP._jobs[jobId]
            if not job then
                return { ok = false, error = "unknown or expired job: " .. jobId }
            end
            return { ok = true, job = view(job) }
        end
        local jobs = {}
        for _, job in pairs(MCP._jobs) do
            jobs[#jobs + 1] = view(job)
        end
        return { ok = true, realm = MCP.util.RealmName(), count = #jobs, jobs = jobs }
    end,
})
