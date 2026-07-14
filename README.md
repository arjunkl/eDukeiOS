# eDukeiOS

A modern, personal-use iOS port of [EDuke32](https://voidpoint.io/terminx/eduke32) for arm64 iPhone and iPad devices.

The Duke Nukem 3D port is playable, with fullscreen widescreen rendering, customizable touch controls, touch and gyroscope aiming, sound, music, persistent settings, and support for importing legally owned game data through the Files app.

> **No proprietary game data is included.** You must supply your own legally obtained game files.

## Current status

### Duke Nukem 3D

The primary Duke port is working:

- Fullscreen device-aspect rendering
- iPhone and iPad support
- Invisible left-side movement zone
- Right-side swipe aiming
- Tap-to-fire and hold-to-fire
- CoreMotion gyroscope aiming
- Movable and resizable action buttons
- Separate touch and gyro sensitivity controls
- Working sound and built-in OPL3 music
- Files-app access to game files, saves, configuration, and logs
- Unsigned IPA builds through GitHub Actions

### Ion Fury

Experimental support is included in the game launcher.

Place `FURY.GRP` in the app's Files folder. eDukeiOS calculates its size and CRC, generates the runtime metadata required by the shared Duke game layer, and selects the correct root DEF for either the original game (`fury.def`) or Aftershock (`ashock.def`). A loose `FURY.DEF` may also be placed beside the GRP for retail packages that provide it separately.

Ion Fury still requires device testing and may need compatibility fixes for particular retail or expansion versions.

### Shadow Warrior

A separate diagnostic **VoidSW iOS** target now compiles and packages successfully. It can load `SW.GRP` and `SW.RTS`, but its complete touch-control adapter and integration into the combined launcher are still in development.

### Custom games

The launcher recognizes `CUSTOM.GRP` for experimental Duke-compatible custom content. Mods may also require accompanying CON, DEF, ZIP, or loose files.

## Requirements

- An arm64 iPhone or iPad
- iOS or iPadOS 15.0 or later
- A sideloading tool such as [AltStore](https://altstore.io/)
- Legally owned game data

A Mac is not required when using the GitHub Actions build workflow.

## Installing the IPA

1. Open the [latest eDukeiOS release](https://github.com/arjunkl/eDukeiOS/releases/latest).
2. Download the attached eDukeiOS IPA.
3. Install it through AltStore or another personal signing solution.

GitHub Actions artifacts are intended for development and diagnostic builds. Most users should download the current IPA from **Releases**.

Installing a newer IPA with the same app identity should update the existing installation and preserve its Documents directory. Back up saves before testing development builds.

## Adding game files

After installing eDukeiOS, open the Files app and navigate to:

`On My iPhone → eDukeiOS`

For Duke Nukem 3D, copy:

- `DUKE3D.GRP`
- `DUKE.RTS` (recommended)

For Ion Fury, copy:

- `FURY.GRP`
- `FURY.DEF` only if your retail package provides it as a separate file
- Any legally owned accompanying loose files required by your edition

For the separate VoidSW diagnostic app, use:

`On My iPhone → VoidSW iOS`

and copy:

- `SW.GRP`
- `SW.RTS` (recommended)

File matching is case-insensitive, but keeping the conventional uppercase names is recommended.

## Touch controls

### Movement and aiming

- Drag anywhere on the **left side** to move and strafe.
- Swipe on the **right side** to aim.
- Quickly tap the right-side aiming zone to fire once.
- Hold briefly in the right-side aiming zone for sustained fire.
- The transparent buttons provide Use, Jump, Crouch, Next Weapon, and Pause actions.

### Gyroscope

Gyroscope aiming is available during gameplay and is enabled or disabled from the control editor. Touch and gyro sensitivity are adjustable independently.

### Control editor

- Tap Pause to open the regular in-game menu.
- Hold Pause for approximately two seconds to open the eDukeiOS control editor.
- Drag a button to reposition it.
- Drag its resize handle to change its size.
- Adjust touch and gyro sensitivity with the sliders.
- Use the gyro button to enable or disable motion aiming.
- Tap **Done** to leave the editor.

Control positions and sensitivity settings are saved between launches.

## Building with GitHub Actions

The workflow is located at:

`.github/workflows/ios-build.yml`

It uses a hosted macOS runner to:

1. Generate the iOS app icon assets.
2. Fetch SDL2.
3. Build the shared Build engine, MACT, and AudioLib targets.
4. Build the eDukeiOS application.
5. Build the diagnostic VoidSW iOS application.
6. Package unsigned IPA artifacts and debugging symbols.

To start a build manually:

1. Open **Actions**.
2. Select **iOS build probe**.
3. Choose **Run workflow**.
4. Download the artifacts after the workflow completes.

Code signing is deliberately disabled in CI. AltStore or another signing tool signs the app for your own device during installation.

## Data, saves, and logs

The app uses its Documents directory for:

- Game data
- Save files
- Configuration
- Runtime logs
- Optional music and mod files

This makes diagnostic logs and user data accessible from the Files app without requiring Xcode or a Mac.

## Roadmap

- Validate and refine Ion Fury compatibility
- Add the complete VoidSW touch and gyro adapter
- Integrate VoidSW into the combined launcher
- Separate per-game configuration and save directories
- Investigate Polymost/OpenGL ES hardware rendering
- Improve physical controller support
- Continue reducing legacy iOS and diagnostic code

## Project history

This project modernizes the dormant Apple/iOS target present in the EDuke32 source tree. The initial milestone was developed and tested using GitHub-hosted macOS runners and an iPhone 16 Pro Max, without requiring a locally owned Mac.

The upstream EDuke32 and VoidSW projects remain the foundation of this work. Please direct general engine contributions upstream when appropriate.

## License and attribution

eDukeiOS is based on EDuke32 and retains its open-source licensing and attribution requirements. See the license files and source headers in this repository for the complete terms.

Duke Nukem 3D, Ion Fury, Shadow Warrior, their game data, names, artwork, music, and other proprietary assets belong to their respective owners. This repository distributes source-port code only and does not grant rights to commercial game data.
