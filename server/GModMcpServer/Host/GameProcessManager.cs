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

    // Finds the visible "Garry's Mod" top-level window. The launcher chain spawns
    // several gmod.exe processes (CEF/Steam helpers); only the one owning the visible
    // game window matches, so we enumerate top-level windows across all of them.
    // Returns IntPtr.Zero if not found.
    [SupportedOSPlatform("windows")]
    private static IntPtr FindGameWindow()
    {
        var pids = new HashSet<int>();
        foreach (var p in Process.GetProcessesByName(ProcessName))
        {
            pids.Add(p.Id);
            p.Dispose();
        }
        if (pids.Count == 0) return IntPtr.Zero;

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
        return target;
    }

    // Posts the X-button close signal (WM_SYSCOMMAND/SC_CLOSE) to GMod's main game
    // window — the clean-shutdown trigger. Returns true if the window was found and
    // the message posted.
    [SupportedOSPlatform("windows")]
    private static bool TryRequestWindowClose()
    {
        var target = FindGameWindow();
        if (target == IntPtr.Zero) return false;
        return Native.PostMessage(target, Native.WM_SYSCOMMAND, Native.SC_CLOSE, IntPtr.Zero);
    }

    /// <summary>
    /// Whether GMod's game window is the current OS foreground window. Paired with the
    /// client realm's <c>system.HasFocus()</c> to detect the background-launch
    /// stuck-focus bug (engine thinks it's focused while the OS gave focus elsewhere).
    /// False off-Windows or when no game window is found.
    /// </summary>
    public bool IsForeground()
        => OperatingSystem.IsWindows() && IsForegroundCore();

    [SupportedOSPlatform("windows")]
    private static bool IsForegroundCore()
    {
        var target = FindGameWindow();
        return target != IntPtr.Zero && Native.GetForegroundWindow() == target;
    }

    /// <summary>
    /// Heals GMod's stuck-focus state after a background launch by giving its window a
    /// brief, real focus cycle: focus it, wait until the OS confirms it's foreground,
    /// optionally settle for <paramref name="settleMs"/> (so the engine processes the
    /// focus-in on its frame loop), then restore the previous foreground window. Real
    /// OS focus events heal SDL cleanly, where synthetic deactivate messages corrupt
    /// the next refocus. Both transitions go through <see cref="SetForegroundForced"/> so the
    /// heal still works when the user is actively clicking another window (the foreground lock
    /// otherwise blocks the plain call and the stuck mouse never releases). Returns false
    /// off-Windows or when no game window is found.
    /// </summary>
    public bool FlickerFocus(int settleMs)
        => OperatingSystem.IsWindows() && FlickerFocusCore(settleMs);

    [SupportedOSPlatform("windows")]
    private static bool FlickerFocusCore(int settleMs)
    {
        var target = FindGameWindow();
        if (target == IntPtr.Zero) return false;

        var prev = Native.GetForegroundWindow();
        SetForegroundForced(target);

        // Hand focus back only once the OS confirms gmod is foreground, rather than a
        // blind wait. Bounded so a blocked SetForegroundWindow can't hang us.
        var sw = Stopwatch.StartNew();
        while (Native.GetForegroundWindow() != target && sw.ElapsedMilliseconds < 1000)
        {
            Thread.Sleep(10);
        }

        if (settleMs > 0) Thread.Sleep(settleMs);

        if (prev != IntPtr.Zero) SetForegroundForced(prev);
        return true;
    }

    /// <summary>
    /// The current OS foreground window handle, captured before a background launch so the
    /// launcher can restore it whenever GMod tries to steal focus. <see cref="IntPtr.Zero"/>
    /// off-Windows or when there is no foreground window.
    /// </summary>
    public IntPtr CaptureForegroundWindow()
        => OperatingSystem.IsWindows() ? Native.GetForegroundWindow() : IntPtr.Zero;

    /// <summary>
    /// If GMod's window is currently the OS foreground, restore <paramref name="userWindow"/>
    /// to the foreground instead — the "keep my window" action of a background launch. A real
    /// <c>SetForegroundWindow</c> hands GMod a clean focus-loss, so it doesn't grab the mouse,
    /// and (per testing) GMod doesn't re-grab afterwards. No-op returning false when GMod isn't
    /// the foreground, <paramref name="userWindow"/> is invalid, off-Windows, or no game window
    /// exists yet.
    /// </summary>
    public bool DemoteFromForeground(IntPtr userWindow)
        => OperatingSystem.IsWindows() && DemoteFromForegroundCore(userWindow);

    /// <summary>
    /// Bring GMod's window legitimately to the OS foreground and leave it there — the heal for
    /// a foreground (non-background) launch whose startup-focus glitch left GMod stuck in the
    /// background with the mouse grabbed. Uses the forced set, so it wins against the foreground
    /// lock. Returns false off-Windows or when no game window is found.
    /// </summary>
    public bool FocusGame()
        => OperatingSystem.IsWindows() && FocusGameCore();

    [SupportedOSPlatform("windows")]
    private static bool FocusGameCore()
    {
        var target = FindGameWindow();
        if (target == IntPtr.Zero) return false;
        SetForegroundForced(target);
        return true;
    }

    [SupportedOSPlatform("windows")]
    private static bool DemoteFromForegroundCore(IntPtr userWindow)
    {
        if (userWindow == IntPtr.Zero) return false;
        var target = FindGameWindow();
        if (target == IntPtr.Zero) return false;
        if (Native.GetForegroundWindow() != target) return false;
        // Only act when GMod actually holds the foreground; restore the user's window. The
        // forced set is essential here — a plain call is blocked by the foreground lock during
        // GMod's startup grab (one forced restore sticks where dozens of plain calls didn't).
        SetForegroundForced(userWindow);
        return true;
    }

    // Force `target` to the foreground, beating Windows' foreground lock by briefly attaching
    // our input queue to the *current* foreground window's thread for the call. A plain
    // SetForegroundWindow from this background host is silently dropped whenever another process
    // holds/asserts the foreground — GMod grabbing it at startup, OR a window the user is
    // actively clicking — which is exactly when both the background watcher and the stuck-focus
    // flicker need it. With the attach the call takes effect (it may even still report false).
    [SupportedOSPlatform("windows")]
    private static void SetForegroundForced(IntPtr target)
    {
        var fg = Native.GetForegroundWindow();
        var fgThread = fg == IntPtr.Zero ? 0u : Native.GetWindowThreadProcessId(fg, out _);
        var myThread = Native.GetCurrentThreadId();
        var attached = fgThread != 0 && myThread != fgThread
            && Native.AttachThreadInput(myThread, fgThread, true);
        Native.SetForegroundWindow(target);
        Native.BringWindowToTop(target);
        if (attached) Native.AttachThreadInput(myThread, fgThread, false);
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

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();
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
