# Installing Dossiary Scan Helper on a Mac

Dossiary runs in your browser, which can't reach a scanner. Dossiary Scan Helper is a small menu
bar app that does the scanning for it, with any scanner your Mac already supports.

Needs macOS 14 (Sonoma) or later.

1. Download `DossiaryScanHelper-<version>-macos.zip` from the
   [releases page](https://github.com/AarneAarebye/dossiary-scan-helper/releases).
2. Open the zip and drag **Dossiary Scan Helper** into your Applications folder.
3. Open it. A scanner icon appears in the menu bar (it has no window and no Dock icon).
4. In the icon's menu, choose **Start at login** so it's there whenever you scan.

## Connect Dossiary

1. In Dossiary, click **📷 Scan**. The dialog shows the helper as "not paired yet".
2. In the helper's menu, choose **Pair a browser…**. A 6-digit code appears; it works for two
   minutes.
3. Type the code in Dossiary and click **Pair**. Your scanners appear in the dialog.

Each browser pairs once. **Forget paired browsers (N)** in the menu disconnects them all. N is the number of paired browsers; the item is greyed out when none are paired.

## If a scanner is missing

- Check that it's switched on and appears in Apple's Image Capture app.
- Close Image Capture and Preview: a scanner works with one app at a time.
- For a network scanner, check System Settings › Privacy & Security › Local Network, and allow
  Dossiary Scan Helper.
- **Open log** in the menu shows what the helper saw.
