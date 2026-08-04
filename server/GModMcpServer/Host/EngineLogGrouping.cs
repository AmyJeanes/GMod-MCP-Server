namespace GModMcpServer.Host;

/// <summary>A logical console message: a header line plus any indented continuation.</summary>
public sealed record EngineLogMessage(string Header, string Text);

/// <summary>
/// Groups raw console.log lines into logical messages using indentation as the
/// boundary proxy. console.log loses true message boundaries (an emit-time property),
/// but Source indents continuation lines — the Crazy-origin block's
/// Origin/Angles/Velocity, stack frames — so a non-indented line starts a message and
/// indented lines extend it; a blank line ends it. Best-effort: <c>engine_log</c> stays
/// raw, so a mis-group only affects the passive summary, never the ground truth.
/// </summary>
public static class EngineLogGrouping
{
    public static List<EngineLogMessage> Group(IReadOnlyList<string> lines)
    {
        var messages = new List<EngineLogMessage>();
        string? header = null;
        var continuation = new List<string>();

        void Flush()
        {
            if (header is null) return;
            var text = continuation.Count == 0
                ? header
                : header + "\n" + string.Join("\n", continuation);
            messages.Add(new EngineLogMessage(header, text));
            header = null;
            continuation.Clear();
        }

        foreach (var line in lines)
        {
            if (line.Length == 0) { Flush(); continue; } // blank line ends a message
            var indented = line[0] == ' ' || line[0] == '\t';
            if (indented && header is not null)
            {
                continuation.Add(line);
            }
            else
            {
                Flush();
                header = line;
            }
        }
        Flush();
        return messages;
    }
}
