using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;

namespace Specula;

public partial class MainWindow : Window
{
    readonly SessionController _session;
    readonly WinKeyHook _hook = new();
    IntPtr _hwnd;
    IntPtr _ime;
    bool _fill;
    bool _wasReady;
    bool _wasPairing;
    bool _menuOpen;
    DisplaySnapshot? _shownModes;

    public MainWindow()
    {
        InitializeComponent();
        _session = new SessionController(new SecretFile(), new System.Windows.Threading.DispatcherSynchronizationContext(Dispatcher));
        _session.StateChanged += UpdateChrome;
        // Frames never flow through StateChanged. The menu buttons above are the XAML instances.
        _session.Frame += frame => Screen.Present(frame.Width, frame.Height, frame.Rgba);
        Screen.Pointer += (x, y, buttons) => _session.Pointer(x, y, buttons);
        _hook.Capture = CaptureSystemKey;
        HostBox.Text = _session.SavedHost;
        PortBox.Text = _session.SavedPort;
        UserBox.Text = _session.SavedUsername;
        PasswordBox.Password = _session.SavedPassword;
        UpdateChrome();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var source = (HwndSource)PresentationSource.FromVisual(this)!;
        _hwnd = source.Handle;
        source.AddHook(WndProc);
        ApplyIme();
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        _hook.Dispose();
        _session.Shutdown(TimeSpan.FromSeconds(4));
        base.OnClosing(e);
    }

    void ConnectClick(object sender, RoutedEventArgs e)
    {
        if (_session.Connecting)
        {
            _session.Disconnect();
            return;
        }
        if (!int.TryParse(PortBox.Text.Trim(), out var port))
        {
            ErrorText.Text = "포트(1~65535)를 확인해 주세요.";
            ErrorText.Visibility = Visibility.Visible;
            return;
        }
        _session.Connect(HostBox.Text, port, UserBox.Text.Trim(), PasswordBox.Password);
    }

    void LoadClick(object sender, RoutedEventArgs e)
    {
        var saved = _session.CredentialsFor(HostBox.Text);
        UserBox.Text = saved.Username;
        PasswordBox.Password = saved.Password;
    }

    void MenuClick(object sender, RoutedEventArgs e)
    {
        if (_menuOpen) CloseMenu();
        else
        {
            _menuOpen = true;
            MenuPanel.Visibility = Visibility.Visible;
            MenuShield.Visibility = Visibility.Visible;
            _session.ReleasePhysicalKeys();
            OptionItem.Focus();
        }
        e.Handled = true;
    }

    void ShieldDown(object sender, MouseButtonEventArgs e)
    {
        CloseMenu();
        e.Handled = true;
    }

    void OptionClick(object sender, RoutedEventArgs e) => RunMenu(() => _session.ToggleSoftwareOption());
    void InputClick(object sender, RoutedEventArgs e) => RunMenu(() => _session.InputSource());
    void TabClick(object sender, RoutedEventArgs e) => RunMenu(() => _session.PressCommandTab(), keepCommand: true);
    void ResolutionClick(object sender, RoutedEventArgs e) => RunMenu(() => _session.OpenResolution());
    void OrientationClick(object sender, RoutedEventArgs e) => RunMenu(() => _session.OpenRotation());
    void CommandKeyClick(object sender, RoutedEventArgs e) => RunMenu(() => _session.ToggleCommandMode());
    void DisconnectClick(object sender, RoutedEventArgs e) => RunMenu(() => _session.Disconnect());

    void FillClick(object sender, RoutedEventArgs e) => RunMenu(() =>
    {
        _fill = !_fill;
        Screen.Fill = _fill;
        Screen.InvalidateVisual();
    });

    void SwitcherTabClick(object sender, RoutedEventArgs e) => _session.PressCommandTab();
    void SwitcherReleaseClick(object sender, RoutedEventArgs e) => _session.ReleaseCommandTab();

    async void PairClick(object sender, RoutedEventArgs e)
    {
        try { await _session.SubmitCode(CodeBox.Text); }
        catch (Exception ex) { DialogError.Text = ex.Message; }
    }

    void CloseSettingsClick(object sender, RoutedEventArgs e) => CloseSettings();

    async void RestoreClick(object sender, RoutedEventArgs e)
    {
        try { await _session.RestoreResolution(); }
        catch (Exception ex) { DialogError.Text = ex.Message; }
    }

    void CodeChanged(object sender, TextChangedEventArgs e)
    {
        var digits = new string(CodeBox.Text.Where(char.IsDigit).Take(6).ToArray());
        if (CodeBox.Text != digits)
        {
            CodeBox.Text = digits;
            CodeBox.CaretIndex = digits.Length;
        }
        PairButton.IsEnabled = digits.Length == 6 && !_session.Busy;
    }

    void RunMenu(Action action, bool keepCommand = false)
    {
        CloseMenu();
        if (!keepCommand) _session.ReleaseCommandTab();
        action();
        if (_session.Ready) Screen.Focus();
    }

    void CloseMenu()
    {
        _menuOpen = false;
        MenuPanel.Visibility = Visibility.Collapsed;
        MenuShield.Visibility = Visibility.Collapsed;
    }

    void CloseSettings()
    {
        _session.CloseSettings();
        if (_session.Ready) Screen.Focus();
    }

    /// <summary>Connection state only. Incoming frames update <see cref="RemoteScreen"/> and do not run this.</summary>
    void UpdateChrome()
    {
        var ready = _session.Ready;
        ConnectView.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
        SessionView.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        ConnectButton.Content = _session.Connecting ? "취소" : "연결";
        HostBox.IsEnabled = UserBox.IsEnabled = PortBox.IsEnabled = PasswordBox.IsEnabled = !_session.Connecting;
        StatusText.Text = _session.Status;
        ErrorText.Text = _session.Error;
        ErrorText.Visibility = string.IsNullOrEmpty(_session.Error) || ready ? Visibility.Collapsed : Visibility.Visible;
        SessionError.Text = _session.Error;
        SessionBanner.Visibility = ready && !_session.SettingsVisible && !string.IsNullOrEmpty(_session.Error)
            ? Visibility.Visible : Visibility.Collapsed;
        SwitcherBar.Visibility = _session.CommandTabHeld ? Visibility.Visible : Visibility.Collapsed;
        OptionItem.Content = SessionMenuText.Option(_session.SoftwareOption);
        OrientationItem.Content = SessionMenuText.Orientation(_session.Portrait);
        FillItem.Content = SessionMenuText.Fill(_fill);
        CommandKeyItem.Content = SessionMenuText.CommandKey(_session.CommandMode);
        ResolutionItem.IsEnabled = OrientationItem.IsEnabled = !_session.Busy;
        SettingsOverlay.Visibility = _session.SettingsVisible ? Visibility.Visible : Visibility.Collapsed;
        SettingsTitle.Text = _session.Pairing ? "맥 연결 코드" : "해상도";
        PairPanel.Visibility = _session.Pairing ? Visibility.Visible : Visibility.Collapsed;
        ModePanel.Visibility = _session.Pairing ? Visibility.Collapsed : Visibility.Visible;
        PairButton.Visibility = _session.Pairing ? Visibility.Visible : Visibility.Collapsed;
        PairButton.IsEnabled = CodeBox.Text.Length == 6 && !_session.Busy;
        BusyText.Visibility = _session.Busy ? Visibility.Visible : Visibility.Collapsed;
        DialogError.Text = _session.Error;
        if (!ReferenceEquals(_shownModes, _session.Snapshot))
        {
            _shownModes = _session.Snapshot;
            RebuildModes();
        }
        if (_session.Pairing && !_wasPairing)
        {
            CodeBox.Text = "";
            CodeBox.Focus();
        }
        _wasPairing = _session.Pairing;
        if (ready && !_wasReady)
        {
            CloseMenu();
            Screen.Focus();
        }
        _wasReady = ready;
        if (_hwnd != IntPtr.Zero) ApplyIme();
        if (ready) _hook.Install();
        else _hook.Uninstall();
    }

    void RebuildModes()
    {
        ModeList.Children.Clear();
        var snapshot = _session.Snapshot;
        if (snapshot == null)
        {
            CurrentModeText.Text = "";
            return;
        }
        CurrentModeText.Text = "현재 " + snapshot.Current.Title;
        foreach (var mode in snapshot.Modes)
        {
            var current = mode.Width == snapshot.Current.Width && mode.Height == snapshot.Current.Height &&
                          mode.PixelWidth == snapshot.Current.PixelWidth && mode.PixelHeight == snapshot.Current.PixelHeight;
            var button = new Button
            {
                Style = (Style)FindResource("MenuItem"),
                Content = mode.Title + (current ? " · 현재" : ""),
                FontWeight = current ? FontWeights.Bold : FontWeights.Normal,
                Tag = mode.Id
            };
            button.Click += async (_, _) =>
            {
                try { await _session.ChangeMode(mode.Id); }
                catch (Exception ex) { DialogError.Text = ex.Message; }
            };
            ModeList.Children.Add(button);
        }
    }

    void ApplyIme()
    {
        var typingOnThisPc = ConnectView.Visibility == Visibility.Visible;
        InputMethod.SetIsInputMethodEnabled(this, typingOnThisPc);
        InputMethod.SetIsInputMethodSuspended(this, !typingOnThisPc);
        if (_hwnd == IntPtr.Zero) return;
        if (typingOnThisPc)
        {
            if (_ime != IntPtr.Zero) ImmAssociateContext(_hwnd, _ime);
        }
        else
        {
            var previous = ImmAssociateContext(_hwnd, IntPtr.Zero);
            if (previous != IntPtr.Zero) _ime = previous;
        }
    }

    bool CaptureSystemKey(int vk, int scan, bool extended, bool down)
    {
        if (!_session.Ready || SettingsOverlay.Visibility == Visibility.Visible) return false;
        var win = vk is 0x5B or 0x5C;
        var altTab = vk == 0x09 && (GetAsyncKeyState(0x12) & 0x8000) != 0;
        var ctrlEsc = vk == 0x1B && (GetAsyncKeyState(0x11) & 0x8000) != 0;
        if (!win && !altTab && !ctrlEsc) return false;
        if (!_menuOpen) _session.PhysicalScan(scan, extended || win, down);
        return true;
    }

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == 0x020E && _session.Ready && !_menuOpen && SettingsOverlay.Visibility != Visibility.Visible)
        {
            var bits = unchecked((int)(long)wParam);
            Screen.HorizontalWheel((short)((bits >> 16) & 0xFFFF));
            handled = true;
            return IntPtr.Zero;
        }
        if (msg is 0x0100 or 0x0101 or 0x0104 or 0x0105 && RouteKey(msg, (int)wParam, lParam))
        {
            handled = true;
            return IntPtr.Zero;
        }
        var forwarding = _session.Ready && !_menuOpen && SettingsOverlay.Visibility != Visibility.Visible;
        if (forwarding && msg is 0x0102 or 0x0103 or 0x0106 or 0x010D or 0x010E or 0x010F or 0x0281 or 0x0282 or 0x0286)
        {
            handled = true;
            return IntPtr.Zero;
        }
        return IntPtr.Zero;
    }

    bool RouteKey(int msg, int vk, IntPtr lParam)
    {
        var down = msg is 0x0100 or 0x0104;
        if (vk == 0x73 && down && (GetAsyncKeyState(0x12) & 0x8000) != 0) return false;
        if (!_session.Ready) return false;
        if (down && _session.CommandTabHeld && vk is 0x1B or 0x0D)
        {
            _session.ReleaseCommandTab();
            return true;
        }
        if (SettingsOverlay.Visibility == Visibility.Visible)
        {
            if (down && vk == 0x1B) CloseSettings();
            return vk == 0x1B;
        }
        if (_menuOpen)
        {
            if (down && vk == 0x1B)
            {
                CloseMenu();
                if (_session.Ready) Screen.Focus();
                return true;
            }
            return false;
        }
        var bits = unchecked((int)(long)lParam);
        _session.PhysicalScan((bits >> 16) & 0xFF, (bits & 0x01000000) != 0, down);
        return true;
    }

    [DllImport("imm32.dll")]
    static extern IntPtr ImmAssociateContext(IntPtr hWnd, IntPtr hImc);

    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);
}
