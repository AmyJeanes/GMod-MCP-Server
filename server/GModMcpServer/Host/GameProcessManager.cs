using System.Diagnostics;
using Microsoft.Extensions.Logging;

namespace GModMcpServer.Host;

/// <summary>
/// Tracks the GMod process by name (<c>gmod.exe</c>) rather than by holding the
/// handle returned from <see cref="Process.Start"/>. The launcher chain re-execs
/// itself on Windows, so the original handle goes stale within seconds — but only
/// one gmod.exe ever exists at a time (Steam blocks duplicates), so a name lookup
/// is both reliable and survives .NET host restarts.
/// </summary>
public sealed class GameProcessManager
{
    private const string ProcessName = "gmod";

    private readonly string _gameRoot;
    private readonly ILogger _log;
    private readonly object _gate = new();
    private string _lastArgs = "";

    public GameProcessManager(string gameRoot, ILogger log)
    {
        _gameRoot = gameRoot;
        _log = log;
    }

    public string GameRoot => _gameRoot;

    public bool IsRunning => FindRunning() is not null;

    public ProcessSnapshot Snapshot()
    {
        var p = FindRunning();
        if (p is null)
        {
            return new ProcessSnapshot(false, null, null, _lastArgs);
        }
        try
        {
            var uptime = DateTimeOffset.UtcNow - p.StartTime.ToUniversalTime();
            return new ProcessSnapshot(true, p.Id, uptime, _lastArgs);
        }
        catch
        {
            return new ProcessSnapshot(true, p.Id, null, _lastArgs);
        }
        finally
        {
            p.Dispose();
        }
    }

    public Process Launch(IEnumerable<string> argList)
    {
        var args = string.Join(" ", argList);

        lock (_gate)
        {
            var existing = FindRunning();
            if (existing is not null)
            {
                var pid = existing.Id;
                existing.Dispose();
                throw new InvalidOperationException(
                    "GMod is already running (pid=" + pid + "). Call host_close first.");
            }

            var launcher = Path.Combine(_gameRoot, "gmod.exe");
            if (!File.Exists(launcher))
            {
                // Older installs / Linux layouts use hl2.exe / hl2_linux directly.
                var hl2 = Path.Combine(_gameRoot, "hl2.exe");
                if (File.Exists(hl2)) launcher = hl2;
                else throw new FileNotFoundException("Cannot find gmod.exe or hl2.exe", launcher);
            }

            var psi = new ProcessStartInfo
            {
                FileName = launcher,
                Arguments = args,
                WorkingDirectory = _gameRoot,
                UseShellExecute = false,
            };

            var started = Process.Start(psi)
                ?? throw new InvalidOperationException("Process.Start returned null");

            _lastArgs = args;
            _log.LogInformation("Launched GMod pid={Pid} args={Args}", started.Id, args);
            return started;
        }
    }

    public bool Close(TimeSpan? gracefulWait)
    {
        lock (_gate)
        {
            var processes = Process.GetProcessesByName(ProcessName);
            if (processes.Length == 0) return false;

            var closedAny = false;
            foreach (var p in processes)
            {
                try
                {
                    if (gracefulWait is { } wait && wait > TimeSpan.Zero)
                    {
                        try { p.CloseMainWindow(); } catch { /* maybe no main window yet */ }
                        if (p.WaitForExit((int)wait.TotalMilliseconds))
                        {
                            _log.LogInformation("GMod exited gracefully (pid={Pid})", p.Id);
                            closedAny = true;
                            continue;
                        }
                        _log.LogInformation("Graceful close timed out, killing pid={Pid}", p.Id);
                    }
                    p.Kill(entireProcessTree: true);
                    p.WaitForExit(5000);
                    closedAny = true;
                }
                catch (Exception ex)
                {
                    _log.LogWarning(ex, "Failed to close GMod pid={Pid}", p.Id);
                }
                finally
                {
                    p.Dispose();
                }
            }
            return closedAny;
        }
    }

    private static Process? FindRunning()
    {
        // Take the first hit; Steam prevents multiple GMod instances by design,
        // so in practice this is at most one process.
        var processes = Process.GetProcessesByName(ProcessName);
        if (processes.Length == 0) return null;

        for (var i = 1; i < processes.Length; i++)
        {
            processes[i].Dispose();
        }
        return processes[0];
    }
}

public sealed record ProcessSnapshot(bool Running, int? Pid, TimeSpan? Uptime, string LastArgs);
