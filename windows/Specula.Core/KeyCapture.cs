namespace Specula;

public enum CaptureDecision
{
    /// <summary>The key belongs to Windows. Do not send it to the Mac.</summary>
    Pass,
    /// <summary>Send the key to the Mac and also let Windows see it.</summary>
    ForwardAndPass,
    /// <summary>Send the key to the Mac and keep it from the IME and other apps.</summary>
    ForwardAndSwallow
}

/// <summary>
/// When the low-level hook may take a key. It is global, so this has to say no
/// whenever Specula is not the foreground window or the remote view is not the one taking keys.
/// Alt is forwarded and also passed through: Windows only treats Tab as Alt+Tab if it saw Alt go down.
/// </summary>
public static class KeyCapturePolicy
{
    public const int VkTab = 0x09;
    public const int VkMenu = 0x12;
    public const int VkF4 = 0x73;
    public const int VkLMenu = 0xA4;
    public const int VkRMenu = 0xA5;

    public static bool IsAlt(int vk) => vk is VkMenu or VkLMenu or VkRMenu;

    public static CaptureDecision Decide(bool foreground, bool remoteView, int vk, bool altDown)
    {
        if (!foreground || !remoteView) return CaptureDecision.Pass;
        // Alt+Tab leaves Specula. Alt+F4 closes it. Both stay with Windows.
        if (altDown && vk is VkTab or VkF4) return CaptureDecision.Pass;
        if (IsAlt(vk)) return CaptureDecision.ForwardAndPass;
        return CaptureDecision.ForwardAndSwallow;
    }
}
