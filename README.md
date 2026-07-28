# Mac-TaskManager

A Windows Task Manager-inspired system monitor that runs natively on macOS.

> **This is not Windows.**
> The screenshot below is from a real macOS desktop. Mac-TaskManager is a native Mac app with a Windows Task Manager-style interface, not a Windows VM, not Parallels, and not a remote desktop session.
>
> **这不是 Windows 里的截图。** 这是运行在 macOS 上的原生应用，只是界面故意做成了 Windows 任务管理器的风格。

![Mac-TaskManager running natively on macOS](assets/macos-task-manager-on-mac.png)

## Features

- Process list with CPU, memory, disk, and network activity.
- App and background process grouping.
- Expandable process rows for child processes.
- Search by process name, publisher/user, or PID.
- Run task, end task, and efficiency mode actions.
- Live AppleSMC fan status and temperature sensor list, with safe-range manual RPM control and one-click restore to macOS automatic control.
- macOS-native SwiftUI/AppKit implementation with a Windows Task Manager-inspired look.

## Build

Requirements:

- macOS
- Xcode Command Line Tools or a Swift toolchain
- A valid `Developer ID Application` signing identity for the privileged fan helper

Build and package the app:

```sh
./build.sh
```

To select a specific signing identity:

```sh
CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" ./build.sh
```

Release builds must use a monotonically increasing `APP_BUILD_NUMBER`. The app
uses it to re-register the signed helper after an update, as required by
`SMAppService` when the helper executable or launchd plist changes:

```sh
APP_VERSION="1.0.0" APP_BUILD_NUMBER="100" ./build.sh dmg
```

For a distributable release, first store App Store Connect notarization
credentials in a Keychain profile, then pass that profile to the build. The
script signs the DMG, submits it to Apple, staples the ticket, and validates the
result:

```sh
APP_VERSION="1.0.0" \
APP_BUILD_NUMBER="100" \
NOTARY_PROFILE="MacTaskManager-Notary" \
./build.sh dmg
```

If `NOTARY_PROFILE` is omitted, the script prints a warning and the resulting
DMG is for local testing only.

Run it:

```sh
open Mac-TaskManager.app
```

Or run the built executable directly:

```sh
./Mac-TaskManager
```

## Notes

Mac-TaskManager intentionally borrows the visual language of Windows Task Manager, but all process data comes from macOS system APIs and command line tools.

Fan status is read locally from AppleSMC. On first launch, the app explains and
registers its signed macOS LaunchDaemon. macOS requires the user to personally
approve this system-level service; the app cannot grant that permission
silently. After the one-time approval, later RPM changes use a
signature-validated XPC connection and don't prompt for the password again.
When a release updates the helper, increasing `APP_BUILD_NUMBER` makes the app
refresh the registration before using the new helper. Changes remain limited to
the minimum/maximum RPM reported by the hardware. Fanless Macs show the page as
unsupported.
