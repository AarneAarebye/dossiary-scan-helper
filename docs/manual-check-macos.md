# Hardware checklist (macOS), before each release

Use the signed, notarized app from `macos/dist/`, a real scanner, and the current Dossiary.

- [ ] The zip opens and the app starts from Applications without a security warning.
- [ ] The menu bar icon appears; the menu lists the scanner within 30 seconds of switching it on.
- [ ] Switching the scanner off removes it from the menu; switching it on again brings it back.
- [ ] Pair a browser…: the code pairs Dossiary; a wrong code five times closes the window.
- [ ] Quit and reopen the helper: Dossiary is still paired.
- [ ] Forget paired browsers: Dossiary's dialog asks for a code again.
- [ ] Dossiary's dialog shows only the settings the scanner offers (sources, two-sided, color, resolution).
- [ ] Flatbed, color, 300 dpi: one page arrives in the Inbox, the right way up and the right size.
- [ ] Feeder with 3 sheets (if the scanner has one): 3 pages in one PDF.
- [ ] Feeder, both sides (if offered): 6 pages, fronts and backs in order.
- [ ] Gray and black & white: the PDF looks right and isn't huge.
- [ ] With "Make scans searchable automatically" on in Dossiary: the scan arrives at once marked "Making searchable…", and within a minute it's searchable (search for a word on the page); the plain scan is kept as the original.
- [ ] Quit the helper while a scan is still being made searchable, start it again: it finishes.
- [ ] Empty feeder: Dossiary says "No paper in the feeder." and nothing is added.
- [ ] Scanner opened in Image Capture during a scan request: Dossiary shows the "couldn't connect" message.
- [ ] Open at Login: after logging out and in, the icon is back.
- [ ] Open log: the log shows the scans and no codes, tokens or page data.
- [ ] Languages: set Dossiary Scan Helper to German in System Settings › General › Language & Region › Applications, reopen it: the menu, "Pair a browser…" and "Add network scanner…" are German. Do the same with Armenian (add Հայերեն under Preferred Languages first if macOS doesn't offer it for the app). Set it back.

## Photo scans (0.5.0)

Use a test build on a free port (`cd macos && swift build && .build/debug/dossiary-scan-helper --headless --port 8799`), never the installed helper on 8766. Pair a test browser and revoke it afterwards.

- [ ] `GET /scanners` lists the MF650C with `formats ["pdf","jpeg","png"]` and `areas` starting with `full`, the feeder-only behaviour unchanged, and the Pi's 8800F with its formats and areas.
- [ ] Units: a `10x15` scan at 300 dpi on the MF650C is 1181 x 1772 px (if Image Capture's units differ from inches, find out here and fix `configure`/`probe`, with a test for the conversion).
- [ ] Origin: a print placed against the glass's corner mark appears flush at the top-left of the `10x15` image.
- [ ] `full`, `a5` and `a4` (if the glass allows it) give the expected sizes (width mm / 25.4 * dpi); JPEG, PNG and a black & white PNG (1-bit) are right; the dpi is embedded (`sips -g dpiWidth`).
- [ ] File type: if the driver ignores the requested type, the re-encode path delivers the requested type (check `file` on the saved result).
- [ ] PDF scans from the flatbed and from the feeder are unchanged; an image request from the feeder gets the 422 "Images can only be scanned from the flatbed."
- [ ] Through the helper to the Pi: the 8800F lists its formats and areas, and a `10x15` JPEG scan comes back (about 20 s at 300 dpi).
- [ ] Clean up: stop the test helper, revoke the test pairings, delete the test scans; confirm 8766 was never touched.

## Scan profiles (0.7.0)

Use a test folder for the saved scans, and delete the test profiles afterwards.

- [ ] With the Pi's 8800F on and node-000 added: Scan profiles… › New… lists "Canon CanoScan 8800F (node-000)"; the form offers PDF, JPEG, PNG and paper sizes, no "Scan both sides".
- [ ] A profile for one of the Mac's own scanners offers "Make the PDF searchable (OCR)".
- [ ] Save a profile "8800F A4 JPEG" into a test folder and click it: the menu shows "Scanning “8800F A4 JPEG”…" and all profile entries are greyed; a notification "1 page scanned" appears and a `scan_YYYY-MM-DD_HHMMSS.jpg` is in the folder.
- [ ] A PDF profile with "Make the PDF searchable (OCR)": the PDF is saved after the Pi's text recognition (up to 10 minutes) and its text can be selected in Preview.
- [ ] The iX500 on the Pi with "Scan both sides": a feeder scan saves one PDF with all pages.
- [ ] Switch the 8800F off and click a profile: a "Scan failed" notification names the reason and nothing is saved.
- [ ] Start a scan from Dossiary and click a profile at the same time: the profile reports "Another scan is still running" (only for scanners on the same Mac; two Pis' scanners are independent).
- [ ] Edit a profile whose scanner is off: name and folder can change, the rest stays.
- [ ] Quit and reopen the helper: the profiles are still there.

## Scan icon (0.7.1)

- While any scan runs (a profile scan or one from Dossiary), the menu bar icon alternates between the outline and the filled scanner; it returns to the outline when the last scan ends, also after a failed one.
- The "Scan profiles" form fits its window in every language, with Cancel and Save on the right, and OCR languages is a menu of named languages.

## Scan to Dossiary (0.8.0)

Use a test profile and a test library in Dossiary for Mac; delete the test scans afterwards.

- [ ] Scan profiles… › New…: "Also send to Dossiary" is shown (Dossiary for Mac installed) and off for a new profile; switch it on, save, reopen: it is still on.
- [ ] With Dossiary for Mac closed: click the profile; Dossiary starts without taking the focus away and adds the scan to its last used library; the notification names the scan.
- [ ] With Dossiary for Mac open on another library: the scan is added to the library that is open (check which one).
- [ ] With Dossiary for Mac open but no library open: the app says so and the scan stays in the folder.
- [ ] With Dossiary for Mac not installed (rename it temporarily): the switch is hidden for a profile that has it off; a profile that has it on still shows it, and its scan notification says Dossiary isn't installed and the scan is saved in the folder.
- [ ] Which copy launched: with only the installed app in /Applications/Dossiary and no build copies running, the hand-over reaches that app (no second instance appears).
- [ ] Dossiary not installed (only checkable on a Mac with no other registered copy of Dossiary, builds included; macOS follows a renamed app and falls back to other registered copies, which would receive the scan or ignore it): the notification says Dossiary for Mac isn't installed, and the scan is saved in the folder.
- [ ] A partial scan (feeder runs out of paper): the saved pages are handed over and the notification says it was partial.
- [ ] In every case above the scan file exists in the profile's folder.
