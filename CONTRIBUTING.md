# Contributing to Brim

Thanks for helping. A few things make it easy:

- **Start with an issue** for anything bigger than a small fix, so we can agree on the approach before you spend time on it.
- **Build with the Command Line Tools:** `./build.sh run`. Brim builds without Xcode; please keep it that way (no `@State` or other macros that need Xcode's plugins: see how `SettingsState` and `NotchUIState` hold state instead).
- **Keep it light.** Brim runs all day. New timers or checks should pause while the Mac is locked or the displays are asleep (`QuietState`), and show up in the Diagnostics report (`Diag.count`).
- **Ask for as little as possible.** A feature that needs a new permission asks for it only when it's first used, and the rest of Brim works without it.
- **Match the look.** Apple's springs and SF Symbols, the island's own transitions (`AnyTransition.notchContent`), and plain, short text in Settings.
- **Describe what you tested:** which Mac, notch or floating island, and macOS version.

By contributing you agree that your work is released under the MIT licence.
