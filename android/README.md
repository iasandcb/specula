# Specula Android

Native Kotlin / Jetpack Compose client for the Mac's built-in Screen Sharing and
Specula Display helper. Android 8.0 (API 26) or newer. The existing Swift sources
remain unchanged.

## Build

Install JDK **17**, Android SDK platform **35**, and build tools **35.0.0**.
The checked-in Gradle 8.11.1 wrapper downloads and verifies its distribution;
AGP is pinned to 8.9.2. JDK 25 is not supported by this Gradle/AGP combination.
On this Mac, the compatible JDK already exists at the Homebrew path below.
Select JDK 17 as Android Studio's Gradle JDK as well.

```sh
cd android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME="$HOME/Library/Android/sdk"
./gradlew assembleDebug testDebugUnitTest
```

On other machines, set `JAVA_HOME` to that machine's JDK 17 installation. No
machine-specific paths or credentials are checked into the project. In a
restricted workspace where the default Gradle/Android caches are read-only:

```sh
export GRADLE_USER_HOME=/private/tmp/specula-gradle
export ANDROID_USER_HOME=/private/tmp/specula-android
./gradlew assembleDebug testDebugUnitTest lintDebug
```

APK: `app/build/outputs/apk/debug/app-debug.apk`.
JVM report: `app/build/reports/tests/testDebugUnitTest/index.html`.
Lint report: `app/build/reports/lint-results-debug.html`.

## Run

```sh
"$ANDROID_HOME/platform-tools/adb" install -r app/build/outputs/apk/debug/app-debug.apk
"$ANDROID_HOME/platform-tools/adb" shell am start -n com.ias.specula/.MainActivity
```

1. Enable **Screen Sharing** on the Mac and allow the Mac account to connect.
2. Use a reachable Mac hostname or IP address, without a scheme or port.
   Screen Sharing uses TCP **5900**; Specula Display uses TCP **5901**.
3. Enter the Mac account's short username and login password. For classic VNC
   authentication, leave the username empty and use the Mac's configured VNC
   password (ASCII, 1–8 bytes).
4. Tap **연결**. **불러오기** loads credentials saved for the entered host.
   Passwords and helper bearer tokens use EncryptedSharedPreferences with an
   Android Keystore AES-256 master key. Cloud backup and device transfer are
   disabled for these preferences.
5. On **해상도** or **세로** / **가로**, enter the six-digit code displayed by
   Specula Display if prompted. Every HTTP 401 deletes the saved token and
   opens code entry, including a rejected pairing request. A rotation interrupted
   by pairing resumes after successful pairing.

The helper currently accepts loopback and Tailscale peers (as defined by
`DisplayPeer` in the Swift sources). Use the Mac's Tailscale IP/hostname for
helper features; a regular LAN address alone may connect RFB but be rejected by
the helper. The helper is optional for remote viewing and input.

## Controls

- One-finger tap: left click. Move one finger beyond the touch slop: Mac drag;
  release or cancellation releases the button.
- Two-finger tap: right click. Two-finger pinch: zoom, up to 8×. Move both fingers
  to pan the viewport. Screen rotation/resizing resets the viewport to fit.
- The remote screen fills the available space in portrait and landscape, with no
  bottom toolbar. The top-right **⋯** button has a 56 × 56dp touch target and opens
  a menu with 20sp text and items at least 56dp tall: **키보드**, **⌃Space 입력기**,
  **⌘Tab**, **해상도**, **세로** / **가로**, and **연결 끊기**. The orientation label
  names the next orientation. The menu scrolls on short screens. Outside taps
  only dismiss it; menu touches never click the Mac.
- Framebuffer state is read only in the remote AndroidView update scope. The
  sibling overlay owns menu state, so incoming frames do not restart the menu.
  The menu stays in the Activity window to preserve physical-key dispatch.
- **⌘Tab** holds Command and sends Tab after a 40 ms modifier gap to show the
  Mac app switcher. Choosing it again sends only another Tab. While Command is
  held, large **Tab** and **⌘ 해제** controls appear at the top-left for repeat and
  release. Opening or dismissing **⋯** keeps Command held. Touching the remote
  screen, choosing another menu action, pressing hardware Enter/Escape,
  backgrounding the app, or disconnecting releases Command.
- **키보드** toggles the Android IME. Soft-keyboard composition stays local until
  `commitText`; committed text and virtual Enter/backspace go to the Mac.
  Physical keyboard events are consumed in `onKeyPreIme` before Android's IME,
  with `dispatchKeyEvent` as a fallback, so they cannot also produce IME commits.
  US QWERTY positions and immediate key-down/up events let the Mac IME compose
  live, independent of the Android keyboard layout. Both Alt keys send Command
  (`Super_L`, `0xffeb`); both Windows/Meta keys send Option (`Meta_L`, `0xffe7`),
  matching the Swift client's Mac keysyms. Ctrl remains Control. Android intercepts
  Alt+Tab and Meta+Tab; use **⌘Tab** for remote app switching. The **⌃Space 입력기**
  menu item sends Control-down, Space-down/up, Control-up.
- Back dismisses an open menu; otherwise it hides the keyboard first, then
  disconnects. Connection survives Activity recreation through a ViewModel. The display helper receives a heartbeat every
  15 seconds and a best-effort restore on disconnect; its existing 60-second
  lease restores resolution if the process or network disappears.

## Protocol and verification

The implementation is ported from `Sources/RemoteCore`, `Sources/DisplaySupport`,
`App/DisplaySettings.swift`, and the helper's actual route handling. It negotiates
RFB 3.3/3.7/3.8, explicitly chooses ARD type 30 for account login or VNC type 2
for an empty username, and never falls back to unauthenticated access. ARD uses
fixed-width DH values, prime validation, MD5(shared secret), AES-128-ECB, and the
same credential padding and terminators as Swift. Its crypto modes are required
by the existing protocol, and protect credentials rather than the whole session.
Use a trusted network or Tailscale: framebuffer/input traffic and helper HTTP
are not independently encrypted.

The client requests 32bpp, depth 24, little-endian true color with R/G/B shifts
0/8/16. It advertises ZRLE, CopyRect, Raw, DesktopSize, LastRect in Swift's order.
Cursor pseudo-encoding is not advertised, matching Swift's default. A connection
owns one persistent zlib inflater and palette; macOS reuse encodings 127 and 129
work across tiles and rectangles. Compressed and inflated byte caps scale with
rectangle size using the Swift formulas. Framebuffer bounds are 8192 per edge
and 6016 × 3384 pixels. Clipboard messages are consumed without applying them.

JVM tests port the applicable client protocol checks: independent DES and full
ARD vectors, credential and DH rejection, exact wire packets, physical key
mapping, ZRLE tile variants and palette reuse, streaming inflate, 4K/6K limits,
malformed data, overlapping CopyRect, DesktopSize, fragmented socket handshakes,
Raw/ZRLE updates, and helper requests/auth/timeout behavior. Mac-only display
lease/IOKit implementation tests and UIKit lifecycle tests are not Android
protocol tests and remain in the Swift suite.

The real `Tests/RemoteCoreTests/Fixtures/screen-sharing-zrle.bin` capture is copied
unchanged into test resources. Replay deliberately fragments reads to at most
1500 bytes, decodes all 24 updates at 1600 × 1200, and checks Swift's final RGBA
FNV-1a hash **3000278177406984333**. Socket tests separately exercise complete
handshakes, including decrypting the client's ARD response as a mock Mac server.

No Android device/emulator or live Mac session was available during development.
Real touch/IME behavior, device Keystore operation, memory/performance at large
resolutions, and physical Mac mode/rotation changes require device testing.
There is no automatic reconnection or background foreground-service guarantee;
a closed connection returns to the connection screen. This initial Android
client does not port iOS-specific session-resume or mouse cursor UI behavior.

## Recorded validation

Using the JDK 17 and SDK/cache environment variables above:

```text
./gradlew assembleDebug testDebugUnitTest --console=plain
BUILD SUCCESSFUL
29 JVM tests, 0 failures, 0 errors, 0 skipped
```

An additional `lintDebug` run reports 3 existing `RestrictedApi` errors in the
Activity's unchanged `dispatchKeyEvent` override/super call, plus 7 warnings.
The warnings concern three pinned dependency versions, protocol-required DES/AES
ECB, the legacy backup attribute recommendation (backup is disabled), and a
Canvas KTX style suggestion. No device/emulator was connected for interactive
overflow-menu, touch, or IME validation. The Swift and Android capture copies
have identical SHA-256
`2a22270d73ee18fb9488f416f415d4f3c7a3b6c67e4341b07c1e883296063001`.
