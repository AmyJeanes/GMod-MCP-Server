-- Run a raw console command in this realm.
-- Gated behind `unsafe`: a console command can `lua_run` arbitrary Lua (and
-- Lua can RunConsoleCommand), so console and Lua execution share one capability.
--
-- Server uses game.ConsoleCommand, which runs on the server console and bypasses
-- the Lua command blocklist RunConsoleCommand is subject to (so changelevel/bot/
-- kick etc. go through). Client uses Player:ConCommand — the local command buffer,
-- closest to the user typing into their own console.
--
-- Command output is asynchronous (the command runs next frame), so it isn't in
-- this response; it surfaces via the passive `events` array / console_read.

MCP:AddFunction({
    id = "console_cmd",
    description = "Run a raw console command in this realm (server: game.ConsoleCommand; client: the local console). Output is async — poll it back with console_read. Gated by the unsafe capability (console commands are as powerful as arbitrary Lua).",
    schema = {
        type = "object",
        properties = {
            command = {
                type = "string",
                description = "The full console command line to run, e.g. \"sv_cheats 1\" or \"say hello\".",
            },
        },
        required = { "command" },
    },
    requires = { "unsafe" },
    handler = function(args)
        local command = args.command
        if type(command) ~= "string" or command == "" then
            return { ok = false, error = "missing or empty `command` argument" }
        end

        if SERVER then
            game.ConsoleCommand(command .. "\n")
        else
            local ply = LocalPlayer()
            if not IsValid(ply) then
                return { ok = false, error = "no valid LocalPlayer to run the command on" }
            end
            ply:ConCommand(command)
        end

        return { ok = true, command = command }
    end,
})
