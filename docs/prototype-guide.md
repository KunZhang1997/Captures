# Prototype Source of Truth

`design/all-in-one-prototype.html` is the single canonical HTML prototype for
Captures. It is the living visual and interaction reference for the whole
product, not a one-feature demo.

- Every future capture mode, flow, and UI state must be added inside this one
  HTML as an in-page mode or state.
- Future AI agents must inspect and extend this file before drawing anything.
  They must not create another `*-prototype.html`, `*-flow.html`, or separate
  image-only mock as a competing source of truth.
- Capture rectangles in the prototype must be drawn by the user through the
  interaction; do not hard-code a default-size selection box.
- Selection corners use two concentric antialiased strokes on the same rounded
  path: a crisp 8 pt opposite-color outer keyline beneath the fuller 6 pt main
  stroke. Black corners have a white keyline and white corners have a black
  keyline; both keep rounded caps and joins without a blurred shadow or glow.
  The gray surround uses a matching 10 pt rounded visual cutout, preventing its
  former square corner from showing beneath the arm; exported crop geometry
  remains the user's exact rectangle. Area capture, window capture, quick
  markup, and long capture share this style without changing the App icon.
- The `挂在页面上` page demonstrates the multi-capture result route: each card
  keeps the exact size of the user's selected region, has only a thin movable
  border, and remains on the page while the user creates additional cards. Its
  red close control keeps the native close meaning; edit, OCR, and always-on-top
  are separate right-aligned controls. Cards use normal window ordering until
  the user explicitly enables always-on-top.
- Mouse-up on a valid selection first presents one compact translucent
  quick-markup toolbar anchored to the selection. Its order is Close, Select
  Annotation, Rectangle, Ellipse, Arrow, Pencil, Text, Pixelate,
  compact color/width, Undo, Redo, then Long Capture, full Edit, OCR, Keep on
  Page (SF Symbols pin), Download, and Copy. Position it outside above the selection
  when there is room, then below it; use inside top-left only when neither
  side fits, including fullscreen. Keep result actions together at the right
  when the toolbar wraps; do not cover a small top-edge crop unnecessarily.
  No action executes before the user chooses, and the one-shot choice does not mutate the saved
  after-capture mode. Persistent Copy Only, Open Editor, and Keep on Page modes
  remain explicit chooser-bypass shortcuts.
- Long Capture uses the system `scroll` long-sheet icon consistently across
  native entry points and the prototype. Download keeps its separate
  `square.and.arrow.down` icon; the two actions must not share download imagery.
- Quick marks stay attached to the original frozen screen, not to the crop
  rectangle. Select Annotation (V) is selected by default. With no marks, it
  drags the whole crop from anywhere inside it, while its edges and corners
  resize it directly. The person chooses Rectangle or another drawing tool to
  start editing; the first mark locks the crop, and undoing or deleting back to
  zero marks unlocks it. After that lock, Select Annotation moves only
  existing marks. Download, Copy, floating cards, OCR, and full Edit all receive the
  same composited crop including those marks. Drawing tools remain active;
  text supports normal IME composition, Command-Enter to commit, and Escape
  to cancel text. Undo/redo reverses mark edits; interrupted drags restore the
  original state. Long Capture is disabled while marks exist and explains
  that all marks must be undone first. Undoing them re-enables Long Capture.
  The toolbar wraps at screen edges and retains keyboard/accessible labels;
  V selects a mark, R/E/A/P/T/X choose drawing tools, and
  Command-Z/Command-Shift-Z undo/redo. Command-C or Return copies only outside text
  editing; Command-S downloads only outside text editing. The HTML exports a
  real PNG browser download from the composited selected region. If preparing
  or dispatching the download fails, it shows an inline error and keeps the
  selection and marks for retry; a successful dispatch clears the pending
  choice without changing the current page or saved defaults. Bare C/P/E do
  not trigger result routes. Escape outside text
  discards the pending shot. The smaller result-only and long-capture
  capsules retain their existing above-then-inside positioning rules.
- Preserve the existing Apple-native language, spacing, materials, typography,
  and interaction patterns. New work should reuse the existing tokens and
  controls instead of inventing a new design system.
- The image editor keeps its labels visible in a compact native layout: one
  thin system title bar containing `Captures`, the tool tabs, and command
  actions, plus one matching compact contextual tool strip directly below it.
  Do not repeat the selected page name in that internal title bar. The strip is
  the selected tool's real parameter surface, so color, stroke, fill, font,
  opacity, strength, and crop/resize controls must remain visible instead of
  being clipped. Its typography is an auxiliary tier below the larger title-row
  category labels. Do not add a sidebar, a parallel custom rail, or a floating
  palette.
- Page switching follows one reusable in-document contract:
  `data-page-nav` controls a matching `data-page-pane`. Keep editor pages
  mounted while hidden so returning to them does not break their live canvas.
  The switcher sits in its own compact navigation row above the simulated app,
  rather than inside its title bar; page changes use a short fade and vertical
  settle, with reduced-motion support and arrow-key navigation.
- The editor's title row names concrete capability groups—crop/rotate,
  retouch, the filter library, annotation, watermark, and output size—while
  the contextual strip directly below it exposes the selected group's real
  tools and values. The filter library uses a single horizontal row of real,
  small-but-wide preview cards with compact labels and horizontal scrolling.
- Reference screenshots and other prototype-only assets live beside this file
  in `design/`; the HTML remains the authoritative composition and behavior.
- The primary area shortcut is also the fast window selector: pointer movement
  highlights the frontmost eligible window, a click captures that window, and
  a drag captures an arbitrary region. The separate Window shortcut remains
  available for people who prefer an explicit mode. Every selection state uses
  only four appearance-aware corner arms over the normal-color interior and
  dimmed outside area: restrained near-black in Light Mode and soft white in Dark
  Mode. Each arm keeps its crisp opposite-color outer keyline but never uses a
  blurred shadow or glow; the selector never adds a continuous border or
  rounded outline.
- Long capture closes the full-screen selector after the initial drag, keeps a
  click-through four-corner selection marker, brings the selected application forward,
  and records the person's normal wheel or trackpad scrolling. Captures appends
  only visually confirmed downward movement, so unsupported synthetic browser
  scrolling cannot leave the UI claiming progress that never happened. There is
  no separate Stop step: a compact five-control capsule stays beside the
  non-interactive live thumbnail in the order Close, Edit, OCR, Download, Copy.
  Edit ends the session and opens the de-duplicated continuous result in the
  existing image editor. Download ends the session and saves that same frozen image
  directly with the configured format, file name, and output directory; it does not
  copy or open the editor. The live
  thumbnail aligns to the selected frame's top edge rather than the action capsule;
  each surface moves only when its own screen edge would otherwise clip it. Long
  capture does not install an input filter or require Accessibility permission. One
  nonactivating, non-capturable visual panel draws the entire gray surround as one
  continuous surface, while four transparent nonactivating panels cover only the
  gray space around the selection and consume pointer input. The center selection
  marker and thumbnail stay click-through, so the selected app receives the
  person's original wheel or trackpad input while Captures observes only
  screen-recording frames inside the selected rect. The five-button capsule is
  interactive above those shields; each click freezes and routes that same image.
  Close cancels without copying, while the visually standard rightmost Copy action
  is the normal commit.
  At the maximum image height the same controls remain until a choice is made. The
  thumbnail grows with the stitched result without blocking the selected page or
  becoming part of the capture, and the one-shot action never changes the saved
  after-capture default.
- A normal area selection in Ask Every Time mode exposes quick markup before
  its Long Capture, Edit, OCR, Keep on Page, Download, and Copy result actions. OCR
  opens the captured image directly in text-recognition mode. Long Capture
  reuses the existing selection immediately—there is no second drag—and then
  enters the same manual-scroll/direct-result flow above. Long captures never
  offer another Long Capture action.

### Start the All in One prototype locally

Serve from the `Captures` project root, not from `design/`. The editor bundle
is referenced through the project-root-relative path `Captures/Resources/`.

```bash
cd Captures
python3 -m http.server 8123
```

Then open:

```text
http://127.0.0.1:8123/design/all-in-one-prototype.html
```

No npm install is required for this prototype. If the page loads but the image
editor is blank, first verify that these URLs return HTTP 200 from the same
server:

```text
http://127.0.0.1:8123/design/all-in-one-prototype.html
http://127.0.0.1:8123/design/scroll-capture-reference.png
http://127.0.0.1:8123/Captures/Resources/ImageEditor/FilerobotImageEditor.min.js
```

### Start the native Captures app

The native target requires Xcode 16+ (XcodeGen is only needed when the project
file must be regenerated) and a valid Apple Developer signing identity. Never
use an ad-hoc signature for the deliverable.

```bash
cd Captures
xcodegen generate                 # only when Captures.xcodeproj is missing or stale
xcodebuild -project Captures.xcodeproj \
  -scheme Captures \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

After launching the signed app, grant Screen Recording in System Settings.
Accessibility is optional and only needed to guarantee suppression of a shortcut already used by another app. The HTML prototype and the native app are separate runtimes;
opening the HTML does not start the native menu-bar app.
