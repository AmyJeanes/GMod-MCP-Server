using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
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

    public CloseMethod Close(TimeSpan? gracefulWait)
    {
        lock (_gate)
        {
            if (NoneRunning()) return CloseMethod.NotRunning;

            // Prefer a clean shutdown when a graceful window is allowed. GMod only
            // writes its archived server convars (cfg/server.vdf — capability grants
            // and mcp_enable) when the window is closed like a user would; killing
            // skips that write and silently drops the grants. Lua can't quit (engine
            // blocklist) and a raw WM_CLOSE is ignored, but the X-button signal
            // (WM_SYSCOMMAND/SC_CLOSE) triggers the clean path. Windows-only; other
            // platforms fall through to the kill.
            if (gracefulWait is { } wait && wait > TimeSpan.Zero && OperatingSystem.IsWindows())
            {
                if (TryRequestWindowClose() && WaitForAllExit(wait))
                {
                    _log.LogInformation("GMod exited cleanly via window close");
                    return CloseMethod.CleanWindowClose;
                }
                if (NoneRunning()) return CloseMethod.CleanWindowClose;
                _log.LogInformation("Clean close didn't finish within {Seconds:F0}s; killing", wait.TotalSeconds);
                KillAll();
                return CloseMethod.KilledAfterTimeout;
            }

            KillAll();
            return CloseMethod.Killed;
        }
    }

    private static bool NoneRunning()
    {
        var ps = Process.GetProcessesByName(ProcessName);
        foreach (var p in ps) p.Dispose();
        return ps.Length == 0;
    }

    private static bool WaitForAllExit(TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed < timeout)
        {
            if (NoneRunning()) return true;
            Thread.Sleep(250);
        }
        return NoneRunning();
    }

    private void KillAll()
    {
        foreach (var p in Process.GetProcessesByName(ProcessName))
        {
            try
            {
                p.Kill(entireProcessTree: true);
                p.WaitForExit(5000);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Failed to kill GMod pid={Pid}", p.Id);
            }
            finally
            {
                p.Dispose();
            }
        }
    }

    // Posts the X-button close signal (WM_SYSCOMMAND/SC_CLOSE) to GMod's main game
    // window. The launcher chain spawns several gmod.exe processes (CEF/Steam
    // helpers); only the one owning the visible "Garry's Mod" window responds, so
    // we enumerate top-level windows across all of them. Returns true if the window
    // was found and the message posted.
    [SupportedOSPlatform("windows")]
    private static bool TryRequestWindowClose()
    {
        var pids = new HashSet<int>();
        foreach (var p in Process.GetProcessesByName(ProcessName))
        {
            pids.Add(p.Id);
            p.Dispose();
        }
        if (pids.Count == 0) return false;

        var target = IntPtr.Zero;
        Native.EnumWindows((hWnd, _) =>
        {
            Native.GetWindowThreadProcessId(hWnd, out var pid);
            if (!pids.Contains((int)pid) || !Native.IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(256);
            Native.GetWindowText(hWnd, sb, sb.Capacity);
            if (sb.ToString().Contains("Garry", StringComparison.OrdinalIgnoreCase))
            {
                target = hWnd;
                return false; // stop enumerating
            }
            return true;
        }, IntPtr.Zero);

        if (target == IntPtr.Zero) return false;
        return Native.PostMessage(target, Native.WM_SYSCOMMAND, Native.SC_CLOSE, IntPtr.Zero);
    }

    [SupportedOSPlatform("windows")]
    private static class Native
    {
        public const uint WM_SYSCOMMAND = 0x0112;
        public static readonly IntPtr SC_CLOSE = (IntPtr)0xF060;

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
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

public enum CloseMethod
{
    NotRunning,
    CleanWindowClose,
    KilledAfterTimeout,
    Killed,
}
