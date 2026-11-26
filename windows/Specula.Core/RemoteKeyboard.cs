namespace Specula;

public readonly record struct KeyStroke(int Symbol, bool Down);

/// <summary>
/// Physical scan codes to RFB key down/up events. Shift, Ctrl, Alt, Win, and Caps Lock are
/// modifiers with their own keysyms; they are not folded into the letter and then dropped.
/// Left and right Shift use different keysyms. Alt and Win share Option or Command, so only
/// the first down and the last up go on the wire.
/// </summary>
public sealed class RemoteKeyboard
{
    readonly Dictionary<int, int> _held = new();
    readonly ModifierLatch _command = new();
    readonly ModifierLatch _option = new();

    public CommandMode Mode { get; set; }
    public bool SoftwareOption { get; private set; }
    public bool CommandTabHeld { get; private set; }
    public bool AltHeld => _held.ContainsKey(0xE2) || _held.ContainsKey(0xE6);
    public bool ShiftHeld => _held.Keys.Any(WindowsKeyMap.IsShift);

    public List<KeyStroke> Press(int scan, bool extended, bool down)
    {
        var events = new List<KeyStroke>();
        scan &= 0xFF;
        if (WindowsKeyMap.Hid(scan, extended) is not int hid) return events;
        if (!down)
        {
            if (_held.Remove(hid, out var released)) ReleaseHeld(hid, released, events);
            return events;
        }
        if (_held.TryGetValue(hid, out var repeat))
        {
            if (!IsModifier(repeat)) events.Add(new KeyStroke(repeat, true));
            return events;
        }
        if (WindowsKeyMap.Keysym(hid, ShiftHeld, _option.IsDown, Mode) is not int symbol) return events;
        _held[hid] = symbol;
        if (symbol is PhysicalKey.Command or PhysicalKey.Option)
            AddEdge(Latch(symbol), "hid:" + hid, true, symbol, events);
        else events.Add(new KeyStroke(symbol, true));
        return events;
    }

    public List<KeyStroke> ReleasePhysical()
    {
        var events = new List<KeyStroke>();
        foreach (var pair in _held.ToArray())
        {
            _held.Remove(pair.Key);
            ReleaseHeld(pair.Key, pair.Value, events);
        }
        return events;
    }

    public List<KeyStroke> ToggleSoftwareOption()
    {
        SoftwareOption = !SoftwareOption;
        return Edge(_option, "software", SoftwareOption, PhysicalKey.Option);
    }

    /// <summary>Command-down when this is the first press. The caller waits, then sends Tab.</summary>
    public List<KeyStroke> BeginCommandTab(out bool pauseBeforeTab)
    {
        var events = new List<KeyStroke>();
        pauseBeforeTab = !CommandTabHeld;
        if (!pauseBeforeTab) return events;
        CommandTabHeld = true;
        AddEdge(_command, "tab", true, PhysicalKey.Command, events);
        return events;
    }

    public List<KeyStroke> TabStroke() => new()
    {
        new KeyStroke(PhysicalKey.Tab, true),
        new KeyStroke(PhysicalKey.Tab, false)
    };

    public List<KeyStroke> ReleaseCommandTab()
    {
        if (!CommandTabHeld) return new List<KeyStroke>();
        CommandTabHeld = false;
        return Edge(_command, "tab", false, PhysicalKey.Command);
    }

    public List<KeyStroke> ReleaseAll()
    {
        var events = ReleasePhysical();
        if (SoftwareOption)
        {
            SoftwareOption = false;
            events.AddRange(Edge(_option, "software", false, PhysicalKey.Option));
        }
        events.AddRange(ReleaseCommandTab());
        return events;
    }

    public void Reset()
    {
        _held.Clear();
        _command.Clear();
        _option.Clear();
        SoftwareOption = false;
        CommandTabHeld = false;
    }

    void ReleaseHeld(int hid, int symbol, List<KeyStroke> events)
    {
        if (symbol is PhysicalKey.Command or PhysicalKey.Option)
            AddEdge(Latch(symbol), "hid:" + hid, false, symbol, events);
        else events.Add(new KeyStroke(symbol, false));
    }

    static List<KeyStroke> Edge(ModifierLatch latch, string holder, bool down, int symbol)
    {
        var events = new List<KeyStroke>();
        AddEdge(latch, holder, down, symbol, events);
        return events;
    }

    static void AddEdge(ModifierLatch latch, string holder, bool down, int symbol, List<KeyStroke> events)
    {
        var edge = latch.Set(holder, down);
        if (edge is bool wire) events.Add(new KeyStroke(symbol, wire));
    }

    ModifierLatch Latch(int symbol) => symbol == PhysicalKey.Command ? _command : _option;

    static bool IsModifier(int symbol) => symbol is
        PhysicalKey.Command or PhysicalKey.Option or 0xffe1 or 0xffe2 or 0xffe3 or 0xffe4 or 0xffe5;
}
