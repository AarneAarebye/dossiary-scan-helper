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
