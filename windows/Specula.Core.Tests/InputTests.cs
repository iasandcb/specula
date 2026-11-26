namespace Specula.Tests;

public class InputTests
{
    [Fact]
    public void PhysicalKeysPreserveMacCommandOptionAndLatinPositions()
    {
        Assert.Equal(0xffeb, PhysicalKey.Symbol(226));
        Assert.Equal(0xffe7, PhysicalKey.Symbol(230));
        Assert.Equal(0xffeb, PhysicalKey.Symbol(227));
        Assert.Equal(0x0100201c, PhysicalKey.Symbol(47, option: true));
        Assert.Equal(0x01002018, PhysicalKey.Symbol(48, option: true));
        Assert.Equal(0x0100201d, PhysicalKey.Symbol(47, shift: true, option: true));
        Assert.Equal(0x01002019, PhysicalKey.Symbol(48, shift: true, option: true));
        Assert.Equal(91, PhysicalKey.Symbol(47));
        Assert.Equal(93, PhysicalKey.Symbol(48));
        Assert.Equal(0xff51, PhysicalKey.Symbol(80, option: true));
        Assert.Equal(0x72, PhysicalKey.Symbol(21));
        Assert.Equal(0x52, PhysicalKey.Symbol(21, shift: true));
        Assert.Equal(0x21, PhysicalKey.Symbol(30, shift: true));
        Assert.Null(PhysicalKey.Symbol(999));
    }

    [Fact]
    public void WindowsScanCodesUseUsPositionsAndCommandChoice()
    {
        Assert.Equal('q', WindowsKeyMap.Keysym(WindowsKeyMap.Hid(0x10, false)!.Value, false, false, CommandMode.WindowsKey));
        Assert.Equal('Q', WindowsKeyMap.Keysym(WindowsKeyMap.Hid(0x10, false)!.Value, true, false, CommandMode.WindowsKey));
        Assert.Equal('a', WindowsKeyMap.Keysym(WindowsKeyMap.Hid(0x1E, false)!.Value, false, false, CommandMode.WindowsKey));
        Assert.Equal(0xffbe, WindowsKeyMap.Keysym(WindowsKeyMap.Hid(0x3B, false)!.Value, false, false, CommandMode.WindowsKey));
        Assert.Equal(0xff52, WindowsKeyMap.Keysym(WindowsKeyMap.Hid(0x48, true)!.Value, false, false, CommandMode.WindowsKey));
        Assert.Equal(0xff08, WindowsKeyMap.Keysym(WindowsKeyMap.Hid(0x0E, false)!.Value, true, false, CommandMode.WindowsKey));

        var win = WindowsKeyMap.Hid(0x5B, true)!.Value;
        var ctrl = WindowsKeyMap.Hid(0x1D, false)!.Value;
        var alt = WindowsKeyMap.Hid(0x38, false)!.Value;
        Assert.Equal(PhysicalKey.Command, WindowsKeyMap.Keysym(win, false, false, CommandMode.WindowsKey));
        Assert.Equal(0xffe3, WindowsKeyMap.Keysym(ctrl, false, false, CommandMode.WindowsKey));
        Assert.Equal(PhysicalKey.Option, WindowsKeyMap.Keysym(alt, false, false, CommandMode.WindowsKey));
        Assert.Equal(PhysicalKey.Option, WindowsKeyMap.Keysym(win, false, false, CommandMode.ControlKey));
        Assert.Equal(PhysicalKey.Command, WindowsKeyMap.Keysym(ctrl, false, false, CommandMode.ControlKey));
        Assert.Equal(0x0100201c, WindowsKeyMap.Keysym(WindowsKeyMap.Hid(0x1A, false)!.Value, false, true, CommandMode.WindowsKey));
        Assert.Null(WindowsKeyMap.Hid(0x5B, false));
    }

    [Fact]
    public void SharedModifiersSendOneEdge()
    {
        var latch = new ModifierLatch();
        Assert.True(latch.Set("left", true));
        Assert.Null(latch.Set("right", true));
        Assert.True(latch.IsDown);
        Assert.Null(latch.Set("left", false));
        Assert.False(latch.Set("right", false));
        Assert.False(latch.IsDown);
    }

    [Fact]
    public void MenuLabelsMatchTheOtherClients()
    {
        Assert.Equal("⌥ Option 켜기", SessionMenuText.Option(false));
        Assert.Equal("⌥ Option 끄기", SessionMenuText.Option(true));
        Assert.Equal("입력기 전환", SessionMenuText.Input);
        Assert.Equal("맥 해상도", SessionMenuText.Resolution);
        Assert.Equal("화면 채우기", SessionMenuText.Fill(false));
        Assert.Equal("전체 화면 보기", SessionMenuText.Fill(true));
        Assert.Equal("세로 모드", SessionMenuText.Orientation(false));
        Assert.Equal("가로 모드", SessionMenuText.Orientation(true));
        Assert.Equal("연결 종료", SessionMenuText.Disconnect);
        Assert.Equal("⌘ 키: Windows", SessionMenuText.CommandKey(CommandMode.WindowsKey));
        Assert.Equal("⌘ 키: Ctrl", SessionMenuText.CommandKey(CommandMode.ControlKey));
    }

    [Fact]
    public void FramebufferMappingLetterboxesFillsAndClamps()
    {
        var origin = PointerMapping.FramebufferPoint(0, 50, 200, 200, 100, 50, false, false);
        Assert.Equal(new PointerMapping.Point(0, 0), origin);
        Assert.Null(PointerMapping.FramebufferPoint(0, 0, 200, 200, 100, 50, false, false));
        Assert.Equal(new PointerMapping.Point(0, 0), PointerMapping.FramebufferPoint(0, 0, 200, 200, 100, 50, false, true));
        Assert.Equal(new PointerMapping.Point(50, 25), PointerMapping.FramebufferPoint(100, 100, 200, 200, 100, 50, false, false));
        Assert.Equal(new PointerMapping.Point(99, 49), PointerMapping.FramebufferPoint(200, 150, 200, 200, 100, 50, false, true));
        Assert.Equal(new PointerMapping.Point(10, 10), PointerMapping.FramebufferPoint(21.8, 70.9, 200, 200, 100, 50, false, false));
        Assert.Equal(new PointerMapping.Point(25, 0), PointerMapping.FramebufferPoint(0, 0, 200, 200, 100, 50, true, false));
        Assert.Null(PointerMapping.FramebufferPoint(1, 1, 0, 10, 10, 10, false, true));
        Assert.Null(PointerMapping.DisplayedFrame(10, 10, 0, 10, false));
    }

    [Fact]
    public void PointerMotionCollapsesAndButtonsStayImmediate()
    {
        var coalescer = new PointerCoalescer();
        var first = coalescer.Submit(new PointerCoalescer.Sample(0, 0, 0), 0);
        Assert.Equal(new[] { new PointerCoalescer.Sample(0, 0, 0) }, first.Send);
        var moved = coalescer.Submit(new PointerCoalescer.Sample(4, 1, 0), 5);
        Assert.Empty(moved.Send);
        Assert.Equal(11, moved.FlushAfterMs);
        Assert.Empty(coalescer.Submit(new PointerCoalescer.Sample(9, 2, 0), 8).Send);
        Assert.Empty(coalescer.Flush(10).Send);
        var flushed = coalescer.Flush(16);
        Assert.Equal(new[] { new PointerCoalescer.Sample(9, 2, 0) }, flushed.Send);
        Assert.Equal(new[] { new PointerCoalescer.Sample(9, 2, PointerButtons.Left) }, coalescer.Submit(new PointerCoalescer.Sample(9, 2, PointerButtons.Left), 17).Send);
        Assert.Equal(new[] { new PointerCoalescer.Sample(9, 2, 0) }, coalescer.Submit(new PointerCoalescer.Sample(9, 2, 0), 17).Send);
    }

    [Fact]
    public void WheelDetentsBecomeClicksAndKeepRemainder()
    {
        var remainder = 0;
        Assert.Equal(0, Wheel.Consume(ref remainder, 60));
        Assert.Equal(60, remainder);
        Assert.Equal(1, Wheel.Consume(ref remainder, 60));
        Assert.Equal(0, remainder);
        Assert.Equal(new byte[] { PointerButtons.WheelUp, 0, PointerButtons.WheelRight, 0 }, Wheel.Masks(1, 1, 0));
        Assert.Equal(new byte[] { (byte)(PointerButtons.Left | PointerButtons.WheelDown), PointerButtons.Left }, Wheel.Masks(0, -1, PointerButtons.Left));
        remainder = 0;
        Assert.Equal(Wheel.MaxClicks, Wheel.Consume(ref remainder, 120 * (Wheel.MaxClicks + 40)));
        Assert.Equal(0, remainder);
    }
}
