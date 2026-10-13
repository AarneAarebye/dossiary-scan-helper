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
- [ ] Start at login: after logging out and in, the icon is back.
- [ ] Open log: the log shows the scans and no codes, tokens or page data.
