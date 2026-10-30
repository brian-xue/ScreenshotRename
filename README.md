# ScreenshotRename

Press **Cmd+Shift+7**, drag to select a region, check the preview, click **Done**,
type a filename in the Save dialog, done.

- Space while selecting switches to window capture; Esc cancels.
- Preview: **Markup** (pencil button) opens Apple's built-in Markup editor for drawing,
  shapes, text and annotations, in its own movable, resizable window beside the preview.
  Its edits replace the preview image.
- Preview: **Done** (Return) opens the Save dialog; **Cancel** (Esc) or closing the window discards it.
- Cancelling the Save dialog returns you to the preview. Nothing is written until you click Save.
- The image is saved as the original lossless PNG at full resolution.
- The dialog defaults to the last folder you saved into (Desktop the first time).

## Install / uninstall

```bash
./install.sh     # builds, copies to ~/Applications, adds a per-user LaunchAgent
./uninstall.sh   # removes the app, LaunchAgent, preferences and permission entry
```

No sudo, no system files. Everything lives in `~/Applications`, `~/Library/LaunchAgents`
and `~/Library/Preferences`.

On first use macOS asks for Screen Recording permission. Grant it, then re-run `./install.sh`.

## Change the shortcut

Edit `hotKeyCode` / `hotKeyModifiers` at the top of `Sources/main.swift`, then re-run `./install.sh`.
