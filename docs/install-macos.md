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

## Use an iX500 on a Raspberry Pi

A ScanSnap iX500 attached to a Raspberry Pi running **scanix500-server**
(see [its guide](https://github.com/AarneAarebye/iX500/blob/main/docs/raspberry-pi.md))
can be shared by every Mac in the house:

1. In the helper's menu, choose **Add network scanner…**. Scan servers on
   your network are listed by name; if yours isn't, type its address (for
   example `scanner.local`).
2. Click **Connect**. The helper shows the server's certificate fingerprint;
   it should match what `scanix500-server status` prints on the Pi.
3. Click **Pair with the Scan button** and, within 2 minutes, press the Scan
   button on the iX500. (Or run `sudo scanix500-server pair` on the Pi and
   enter its code.)

The scanner then appears in Dossiary as "ScanSnap iX500 (<name>)". The menu
shows each network scanner's state; **Remove** forgets it. The connection is
encrypted, and the helper refuses the server if its certificate ever changes
(after reinstalling the Pi, remove the scanner and add it again). The first
time, macOS asks to allow Dossiary Scan Helper on the local network.

## If a scanner is missing

- If the helper's scanner icon doesn't appear in the menu bar although the helper runs, check
  System Settings › Menu Bar and allow Dossiary Scan Helper there. macOS may hide a newly
  installed or updated app's icon; on a MacBook, icons that don't fit beside the notch are hidden too.
- Check that it's switched on and appears in Apple's Image Capture app.
- Close Image Capture and Preview: a scanner works with one app at a time.
- For a network scanner, check System Settings › Privacy & Security › Local Network, and allow
  Dossiary Scan Helper.
- **Open log** in the menu shows what the helper saw.

## Language

The helper follows your Mac's preferred languages (System Settings › General › Language & Region). It
speaks English, German, Spanish, French, Chinese (Simplified and Traditional) and Armenian. To use one
of them for the helper alone, add Dossiary Scan Helper under "Applications" on that page and choose the
language; quit and reopen the helper.

## Files it keeps

- `~/Library/Application Support/dossiary-scan-helper/ocr-jobs/` holds scans waiting to be made
  searchable. Each stays at most 7 days and is deleted as soon as Dossiary has fetched the
  searchable PDF.
- `~/Library/Application Support/dossiary-scan-helper/remote-servers.json` lists the paired
  network scanners; their keys are in your Keychain ("com.aarneaarebye.dossiary-scan-helper.remote").
- `~/Library/Logs/dossiary-scan-helper/helper.log` is the log that **Open log** shows.

To remove the helper completely, quit it, delete it from Applications, delete these files and
folders, and remove its network-scanner keys in Keychain Access.
