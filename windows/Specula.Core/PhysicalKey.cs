namespace Specula;

/// <summary>
/// US ANSI HID usages mapped to X11 keysyms, matching the Swift and Android clients.
/// Apple Screen Sharing treats Alt keysyms as Command, so Option is Meta_L (0xffe7)
/// and Command is Super_L (0xffeb). Option+[ and Option+] send the characters macOS
/// produces; a literal bracket keysym makes Apple drop Option.
/// </summary>
public static class PhysicalKey
{
    public const int Command = 0xffeb;
    public const int Option = 0xffe7;
    public const int ControlLeft = 0xffe3;
    public const int Tab = 0xff09;
    public const int Space = 32;

    public static int? Symbol(int hid, bool shift = false, bool option = false)
    {
        if (option && hid == 47) return shift ? 0x0100201d : 0x0100201c;
        if (option && hid == 48) return shift ? 0x01002019 : 0x01002018;
        if (hid is >= 4 and <= 29) return (shift ? 65 : 97) + hid - 4;
        if (shift && hid is >= 30 and <= 39) return "!@#$%^&*()"[hid - 30];
        if (hid is >= 30 and <= 38) return 49 + hid - 30;
        if (shift && Shifted.TryGetValue(hid, out var shifted)) return shifted;
        return Plain.TryGetValue(hid, out var plain) ? plain : null;
    }

    static readonly Dictionary<int, int> Shifted = new()
    {
        [45] = 95, [46] = 43, [47] = 123, [48] = 125, [49] = 124,
        [51] = 58, [52] = 34, [53] = 126, [54] = 60, [55] = 62, [56] = 63
    };

    static readonly Dictionary<int, int> Plain = new()
    {
        [39] = 48, [40] = 0xff0d, [41] = 0xff1b, [42] = 0xff08, [43] = 0xff09, [44] = 32,
        [45] = 45, [46] = 61, [47] = 91, [48] = 93, [49] = 92, [51] = 59, [52] = 39,
        [53] = 96, [54] = 44, [55] = 46, [56] = 47, [57] = 0xffe5,
        [74] = 0xff50, [75] = 0xff55, [76] = 0xffff, [77] = 0xff57, [78] = 0xff56,
        [79] = 0xff53, [80] = 0xff51, [81] = 0xff54, [82] = 0xff52,
        [224] = 0xffe3, [225] = 0xffe1, [226] = 0xffeb, [227] = 0xffeb,
        [228] = 0xffe4, [229] = 0xffe2, [230] = 0xffe7, [231] = 0xffec
    };
}

public enum CommandMode
{
    /// <summary>The Windows key is Command, Ctrl stays Control, and Alt is Option.</summary>
    WindowsKey,
    /// <summary>Ctrl is Command. The Windows key and Alt are Option, so Command-C matches a Windows habit.</summary>
    ControlKey
}

/// <summary>
/// Windows set-1 scan codes to the same HID usages <see cref="PhysicalKey"/> already maps.
/// Scan codes are physical positions, so a Korean IME layout on Windows does not change them.
/// </summary>
public static class WindowsKeyMap
{
    public static int? Hid(int scanCode, bool extended)
    {
        var table = extended ? Extended : Standard;
        return table.TryGetValue(scanCode, out var hid) ? hid : null;
    }

    public static int? Keysym(int hid, bool shift, bool option, CommandMode mode)
    {
        if (Modifier(hid, mode) is int modifier) return modifier;
        if (hid is >= 0x3A and <= 0x45) return 0xffbe + (hid - 0x3A);
        if (Extra.TryGetValue(hid, out var extra)) return extra;
        return PhysicalKey.Symbol(hid, shift, option);
    }

    public static bool IsShift(int hid) => hid is 0xE1 or 0xE5;

    static int? Modifier(int hid, CommandMode mode)
    {
        var ctrlIsCommand = mode == CommandMode.ControlKey;
        return hid switch
        {
            0xE1 => 0xffe1,
            0xE5 => 0xffe2,
            0xE0 => ctrlIsCommand ? PhysicalKey.Command : 0xffe3,
            0xE4 => ctrlIsCommand ? PhysicalKey.Command : 0xffe4,
            0xE2 or 0xE6 => PhysicalKey.Option,
            0xE3 or 0xE7 => ctrlIsCommand ? PhysicalKey.Option : PhysicalKey.Command,
            _ => null
        };
    }

    static readonly Dictionary<int, int> Extra = new()
    {
        [0x46] = 0xff61, // Print Screen
        [0x47] = 0xff14, // Scroll Lock
        [0x49] = 0xff63, // Insert
        [0x53] = 0xff7f, // Num Lock
        [0x54] = 0xffaf, // Keypad /
        [0x55] = 0xffaa, // Keypad *
        [0x56] = 0xffad, // Keypad -
        [0x57] = 0xffab, // Keypad +
        [0x58] = 0xff0d, // Keypad Enter
        [0x59] = 0xffb1, [0x5A] = 0xffb2, [0x5B] = 0xffb3, [0x5C] = 0xffb4, [0x5D] = 0xffb5,
        [0x5E] = 0xffb6, [0x5F] = 0xffb7, [0x60] = 0xffb8, [0x61] = 0xffb9,
        [0x62] = 0xffb0, // Keypad 0
        [0x63] = 0xffae, // Keypad .
        [0x65] = 0xff67  // Menu
    };

    static readonly Dictionary<int, int> Standard = new()
    {
        [0x01] = 0x29, [0x02] = 0x1E, [0x03] = 0x1F, [0x04] = 0x20, [0x05] = 0x21,
        [0x06] = 0x22, [0x07] = 0x23, [0x08] = 0x24, [0x09] = 0x25, [0x0A] = 0x26,
        [0x0B] = 0x27, [0x0C] = 0x2D, [0x0D] = 0x2E, [0x0E] = 0x2A, [0x0F] = 0x2B,
        [0x10] = 0x14, [0x11] = 0x1A, [0x12] = 0x08, [0x13] = 0x15, [0x14] = 0x17,
        [0x15] = 0x1C, [0x16] = 0x18, [0x17] = 0x0C, [0x18] = 0x12, [0x19] = 0x13,
        [0x1A] = 0x2F, [0x1B] = 0x30, [0x1C] = 0x28, [0x1D] = 0xE0, [0x1E] = 0x04,
        [0x1F] = 0x16, [0x20] = 0x07, [0x21] = 0x09, [0x22] = 0x0A, [0x23] = 0x0B,
        [0x24] = 0x0D, [0x25] = 0x0E, [0x26] = 0x0F, [0x27] = 0x33, [0x28] = 0x34,
        [0x29] = 0x35, [0x2A] = 0xE1, [0x2B] = 0x31, [0x2C] = 0x1D, [0x2D] = 0x1B,
        [0x2E] = 0x06, [0x2F] = 0x19, [0x30] = 0x05, [0x31] = 0x11, [0x32] = 0x10,
        [0x33] = 0x36, [0x34] = 0x37, [0x35] = 0x38, [0x36] = 0xE5, [0x37] = 0x55,
        [0x38] = 0xE2, [0x39] = 0x2C, [0x3A] = 0x39,
        [0x3B] = 0x3A, [0x3C] = 0x3B, [0x3D] = 0x3C, [0x3E] = 0x3D, [0x3F] = 0x3E,
        [0x40] = 0x3F, [0x41] = 0x40, [0x42] = 0x41, [0x43] = 0x42, [0x44] = 0x43,
        [0x57] = 0x44, [0x58] = 0x45,
        [0x45] = 0x53, [0x46] = 0x47,
        [0x47] = 0x5F, [0x48] = 0x60, [0x49] = 0x61, [0x4A] = 0x56, [0x4B] = 0x5C,
        [0x4C] = 0x5D, [0x4D] = 0x5E, [0x4E] = 0x57, [0x4F] = 0x59, [0x50] = 0x5A,
        [0x51] = 0x5B, [0x52] = 0x62, [0x53] = 0x63
    };

    static readonly Dictionary<int, int> Extended = new()
    {
        [0x1C] = 0x58, [0x1D] = 0xE4, [0x35] = 0x54, [0x37] = 0x46, [0x38] = 0xE6,
        [0x47] = 0x4A, [0x48] = 0x52, [0x49] = 0x4B, [0x4B] = 0x50, [0x4D] = 0x4F,
        [0x4F] = 0x4D, [0x50] = 0x51, [0x51] = 0x4E, [0x52] = 0x49, [0x53] = 0x4C,
        [0x5B] = 0xE3, [0x5C] = 0xE7, [0x5D] = 0x65
    };
}

/// <summary>Several physical keys can share one wire keysym. Only the first down and last up are sent.</summary>
public sealed class ModifierLatch
{
    readonly HashSet<string> _holders = new();
    public bool IsDown { get; private set; }

    public bool? Set(string holder, bool down)
    {
        if (down) _holders.Add(holder);
        else _holders.Remove(holder);
        var want = _holders.Count > 0;
        if (want == IsDown) return null;
        IsDown = want;
        return want;
    }

    public void Clear()
    {
        _holders.Clear();
        IsDown = false;
    }
}

public static class SessionMenuText
{
    public static string Option(bool held) => held ? "⌥ Option 끄기" : "⌥ Option 켜기";
    public const string Input = "입력기 전환";
    public const string CommandTab = "⌘Tab";
    public const string Resolution = "맥 해상도";
    public static string Orientation(bool macIsPortrait) => macIsPortrait ? "가로 모드" : "세로 모드";
    public static string Fill(bool filling) => filling ? "전체 화면 보기" : "화면 채우기";
    public static string CommandKey(CommandMode mode) =>
        mode == CommandMode.WindowsKey ? "⌘ 키: Windows" : "⌘ 키: Ctrl";
    public const string Disconnect = "연결 종료";
}
