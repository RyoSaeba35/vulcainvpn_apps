# Vulcain VPN

Open source (GPL-3.0) cross-platform VPN client for [Vulcain VPN](https://vulcainvpn.com), built with Flutter.
One codebase for **Android, iOS, macOS and Windows**, powered by [sing-box](https://github.com/SagerNet/sing-box) with **WireGuard** and **Hysteria2** protocols.

The app talks to the Vulcain VPN backend (`https://api.vulcainvpn.com/api`) for accounts, subscriptions and VPN credentials.

---

## Features

- One-tap connect / disconnect with live status
- WireGuard and Hysteria2 tunnels via sing-box
- Automatic reconnect and recovery if the tunnel dies
- Account system: sign up, login, forgot password, delete account
- Continue with Google (Android)
- Subscriptions via Google Play Billing (Android) with paywall and renewal
- Public IP display
- System tray app with background mode (Windows, macOS)
- Native notifications (Windows toasts, macOS, Android)
- English and French, auto-detected from the device language
- Deep links

---

## Tech stack

| Layer | Technology |
|---|---|
| UI | Flutter (Dart SDK ^3.10.4) |
| VPN core | sing-box (WireGuard, Hysteria2) |
| Android | `libbox.aar` (sing-box) in `android/app/libs` |
| iOS | Packet Tunnel extension + `Libbox.xcframework` |
| macOS | System Extension (`NEPacketTunnelProvider`) + `Libbox.xcframework` |
| Windows | Bundled `sing-box.exe` (amd64 + arm64), Inno Setup installer |
| Storage | `flutter_secure_storage`, `shared_preferences` |
| Billing | `in_app_purchase` (Google Play) |
| CI/CD | GitHub Actions (Windows, macOS), Codemagic (signed iOS + macOS) |

---

## Project structure

```
lib/
├── main.dart                     # App entry, locale, routing
├── colors.dart                   # Theme colors
├── l10n/                         # Translations (en, fr)
├── screens/
│   ├── auth_gate.dart            # Login / app switch
│   ├── login_screen.dart
│   ├── signup_screen.dart
│   ├── forgot_password_screen.dart
│   ├── delete_account_screen.dart
│   ├── paywall_screen.dart
│   ├── vpn_home_page.dart        # Main screen with tabs
│   └── tabs/                     # home, subscription, settings
├── services/
│   ├── api_service.dart          # Backend HTTP client
│   ├── auth_service.dart         # Session and tokens
│   ├── billing_service.dart      # Google Play subscriptions
│   ├── vpn_config_service.dart   # Builds sing-box config
│   ├── vpn_service.dart          # Platform switch
│   ├── vpn_service_android.dart
│   ├── vpn_service_ios.dart
│   ├── vpn_service_macos.dart
│   ├── vpn_service_windows.dart
│   └── ...                       # tray, notifications, IP, language, deep links
└── widgets/

ios/PacketTunnel/                 # iOS tunnel extension (Swift)
macos/PacketTunnelMac/            # macOS tunnel extension (Swift)
tools/xcode/                      # Ruby scripts to patch Xcode projects
installer.iss                     # Windows installer (Inno Setup)
setup_task.bat / show_app.*       # Windows launch helpers (admin scheduled task)
codemagic.yaml                    # Signed iOS and macOS builds
.github/workflows/                # GitHub Actions builds
```

---

## Getting started

### Requirements

- Flutter stable (Dart ^3.10.4)
- Android: Android Studio + SDK
- iOS / macOS: a Mac with Xcode and CocoaPods
- Windows: Visual Studio 2022 with "Desktop development with C++"

### Install

```bash
git clone https://github.com/RyoSaeba35/cross_platform_vpn.git
cd cross_platform_vpn
flutter pub get
```

### Run in development

```bash
flutter run -d android
flutter run -d windows
flutter run -d macos
```

**Windows:** the VPN needs the sing-box binaries next to the app. Download them from the [sing-box releases](https://github.com/SagerNet/sing-box/releases) and copy them into the build folder as:

```
build\windows\x64\runner\Debug\sing-box-amd64.exe
build\windows\x64\runner\Debug\sing-box-arm64.exe
```

The app must run as administrator to create the tunnel.

**iOS / macOS:** `Libbox.xcframework` is not committed. Build it with gomobile from sing-box (see the `Build sing-box ... framework` steps in `codemagic.yaml`) and place it in `ios/Frameworks/` or `macos/Frameworks/`.

**Android:** signing for release uses `android/key.properties` and `android/keystore.jks` (both git-ignored).

---

## Building releases with GitHub Actions

Windows and macOS builds run on GitHub Actions. They **do not run on a normal push**. You start them by pushing a tag or by clicking a button.

> Why: GitHub bills macOS runners at 10x and Windows at 2x the Linux rate. Building on every push quickly uses up the free monthly quota.

### Which tag builds what

| Tag | Builds |
|---|---|
| `v1.0.1` | macOS + Windows |
| `mac-v1.0.1` | macOS only |
| `win-v1.0.1` | Windows only |

### Step by step

**1. Commit and push your changes** (this does not trigger any build)

```bash
git add .
git commit -m "Your change"
git push
```

**2. Create a tag and push it** (this starts the build)

Both platforms:
```bash
git tag v1.0.1
git push origin v1.0.1
```

macOS only:
```bash
git tag mac-v1.0.1
git push origin mac-v1.0.1
```

Windows only:
```bash
git tag win-v1.0.1
git push origin win-v1.0.1
```

**3. Follow the build** in the **Actions** tab on GitHub.

### Where to find the result

| Platform | Output |
|---|---|
| Windows | `VulcainVPN-Setup-x.x.x.exe`, attached to a **GitHub Release** named after the tag, and also in the run's **Artifacts** |
| macOS | `vulcain_vpn_macos.zip` in the run's **Artifacts** (kept 7 days) |

### Build without a tag

1. Go to **Actions** on GitHub
2. Pick **Build macOS** or **Build Windows**
3. Click **Run workflow** and choose the branch

The result is in the run's **Artifacts**. No GitHub Release is created.

### Tag rules and tips

- **Each tag is used once.** Pick a new version every time (`v1.0.2`, `v1.0.3`...).
- A tag builds the code **already on GitHub**, so always push your commits first.
- Shortcut with an annotated tag:
  ```bash
  git tag -a v1.0.1 -m "v1.0.1"
  git push --follow-tags
  ```
- If you push a new tag while a build for the same ref is running, the old one is cancelled.
- Made a mistake? Delete the tag and recreate it:
  ```bash
  git tag -d v1.0.1
  git push origin --delete v1.0.1
  ```
- Keep the version in sync in `pubspec.yaml` (`version:`) and `installer.iss` (`MyAppVersion`), since the installer name comes from `installer.iss`.

---

## Signed builds with Codemagic

`codemagic.yaml` produces the store and distribution builds:

| Workflow | Output |
|---|---|
| `ios-vulcainvpn` | Signed `.ipa` uploaded to App Store Connect |
| `macos-vulcainvpn` | Developer ID signed `.dmg`, submitted for notarization |

Both build `Libbox.xcframework` from sing-box with gomobile. Start them from the Codemagic dashboard.

After the macOS notarization is accepted, staple the DMG from a Mac:

```bash
xcrun notarytool wait <SUBMISSION_ID> --key AuthKey_XXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
xcrun stapler staple VulcainVPN.dmg
```

---

## Languages

Supported: **English** and **French**. The app uses French if the device is in French, English otherwise, and the user can change it in Settings. Strings live in `lib/l10n/`.

---

## License

The Vulcain VPN client is free software, licensed under the **GNU General Public License v3.0 or later**. See [LICENSE](LICENSE).

Copyright (C) 2026 Pierre Libran.

- You may use, study, modify and share this code under the GPL terms. Modified versions you distribute must also be GPL with their source available.
- The **Vulcain VPN name and logo are not licensed**. Forks must use a different name and must not imply association with Vulcain VPN.
- The **Vulcain VPN servers, backend and API are not part of this repository** and are not covered by this license.

### Third-party

- [sing-box](https://github.com/SagerNet/sing-box), GPL-3.0-or-later, Copyright (C) 2022 nekohasekai
- Flutter packages under their own licenses (BSD, MIT, Apache 2.0), listed in the app under Settings > Open Source Licences
