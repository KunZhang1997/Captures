## Code Signing

Always use Apple identity signing. Never use ad-hoc signing. All builds must be signed with a valid Apple Developer certificate.

## Releases

- Version is defined in `project.yml`
- Release artifacts go in `dist/{version}/` — DMG and ZIP
- GitHub releases at https://github.com/KunZhang1997/Captures/releases
- Tag format: `v{major}.{minor}.{patch}` (e.g. `v1.5.0`)
- DMG naming: `Captures-{version}.dmg` (e.g. `Captures-1.1.0.dmg`)
- Public binary releases are built locally with Developer ID signing, notarized, verified, and manually uploaded to GitHub Releases. Publish `Captures-latest.dmg` alongside the versioned DMG and ZIP. README and website download links use the stable DMG alias.

## Website

- Astro static site in `website/`
- No production domain is configured for this fork; `website/` is an optional local site.
- Docker build: `cd website && docker build -t capture-site .`

## Prototype Source of Truth (Non-negotiable)

- `design/all-in-one-prototype.html` is the single source of truth for all
  Captures visual and interaction prototypes. It is intentionally named
  **All in One** because every prototype belongs in this document.
- Before designing or reviewing a UI, inspect and reuse this HTML. Add new
  capture modes and flows as in-page modes, states, or panels inside it.
- Do not create sibling prototype files such as `scroll-capture-flow.html`,
  `fullscreen-prototype.html`, separate HTML mockups, or image-only designs.
  Other AI agents must extend this document instead of creating a competing
  visual source.
- The primary area capture is a smart selector: moving the pointer highlights
  the frontmost eligible window, a click captures that whole window, and a
  drag captures an arbitrary region. Selection rectangles remain user input;
  the prototype must not show a hard-coded default-size frame as an already
  committed selection. Window hover, region drag, held result choice, and the
  explicit Window mode all use only four appearance-aware corner arms: restrained
  near-black in Light Mode and soft white in Dark Mode. The selected area stays at
  normal color and the outside stays dimmed. Each corner uses two concentric
  antialiased strokes on the same rounded path: a crisp 8 pt opposite-color
  outer keyline beneath the fuller 6 pt main stroke. Black corners have a white
  keyline and white corners have a black keyline. Keep rounded caps/joins and a
  6 pt turn radius, retain the 18 pt arm length, and never add blur, glow, or a
  contrast shadow. No continuous or rounded outline separates the selected
  area. The gray surround's visual cutout uses a 10 pt radius that
  follows the stroke's outer silhouette, so a square mask corner never appears
  beneath the rounded arm; this is visual-only and the crop remains the exact
  rectangular user selection. Apply this shared style to area/window selection,
  quick-markup selection, and the long-capture marker; never alter the crop
  coordinates or App icon to tune the selection chrome.
- The `挂在页面上` page models the multi-capture result route. Its floating
  cards retain the exact dimensions of the user's selection, use a thin border
  as their movable affordance, and stay mounted while another capture is made.
  Keep the red close action semantically separate from right-aligned edit, OCR,
  and always-on-top controls. A card uses normal window ordering until the user
  explicitly pins it; closing either its full-size card or lower-corner preview
  dismisses that capture's other presentation as well.
- Finishing a valid selection on `挂在页面上` must not immediately copy, edit,
  or create a floating card. Preserve the selection and show one tiny
  translucent quick-markup toolbar. The order is Close, Select Annotation,
  Rectangle, Ellipse, Arrow, Pencil, Text, Pixelate, compact color
  and stroke-width controls, Undo, Redo, Long Capture, Edit, OCR, Keep on Page
  (the SF Symbols pin icon), Download, and Copy. Keep Close leftmost and result routes
  rightmost. Reuse the existing restrained material and corner markers; do not
  copy the reference app's green frame or introduce a second palette.
  Long Capture uses the system `scroll` symbol (a long sheet with rolled ends)
  across native entry points and the matching prototype icon. Reserve the
  downward arrow into a container for Download; never reuse it for Long Capture.
  The frozen selection is editable in place before any result action. Select
  Annotation (V) is the default tool, so while there are no marks the person
  can first drag the whole crop from anywhere inside it; the selection's edges
  or corners resize it directly. They choose Rectangle or another drawing tool
  only when ready to edit; do not add a separate crop toolbar control. The
  first committed mark locks the crop, and undoing or deleting back to zero
  marks unlocks it. Marks use original frozen-screen
  coordinates. Once locked, Select Annotation owns moving existing marks; drawing tools stay selected
  across overlapping strokes. Download, Copy, Keep on Page, OCR, and full Edit receive
  the composited selected image including the quick marks, without toolbar or
  corner chrome. Text is plain editable text with IME-safe composition and
  explicit commit/cancel. Undo/redo includes drawing, text, and moving marks;
  a cancelled pointer gesture restores its previous state and never commits
  a capture or annotation. Disable Long Capture while marks exist, with an
  explanation to undo all marks first; undoing all marks re-enables it.
  Keep the toolbar on-screen, wrapping compactly when necessary, with labels,
  keyboard focus, selected states, and reduced-effects alternatives.
  For this larger quick-markup toolbar, prefer outside above the crop, then
  outside below it, and use inside top-left only when neither side fits
  (including fullscreen). Keep result actions together and right-aligned
  when wrapping. V/R/E/A/P/T/X select annotation, rectangle, ellipse, arrow,
  pencil, text, and pixelate respectively. Command-Z
  and Command-Shift-Z undo/redo. Command-C or Return copies only outside text
  editing; Command-S downloads only outside text editing. Download directly
  exports the composited selected image without opening Edit or OCR or changing
  the saved result mode. The HTML starts a real browser PNG download; a failure
  to prepare or dispatch it shows an inline message and preserves the selection
  and marks for retry. Bare C/P/E must not trigger competing result routes.
  OCR opens the already-captured image directly in the native OCR editor; it never asks
  for a second selection. Long Capture reuses the exact area selection and
  starts recording manual scrolling without asking for another drag. The
  ordinary result-only capsule uses Close followed by Edit, OCR, Keep on Page,
  Download, Copy (`[.editor, .ocr, .preview, .save, .clipboard]` plus Close).
  The separate long-capture capsule retains exactly five controls: Close, Edit,
  OCR, Download, Copy. Edit opens the completed de-duplicated image in the existing
  native editor; Download saves that image directly without entering Edit or OCR.
  Close cancels without copying; Copy uses
  the same visual treatment as the other result actions but remains the rightmost
  commit action; and a long capture cannot recursively
  start another one. All result capsules include Close as the leftmost action,
  which discards the pending screenshot without copying or saving. Pressing `Esc`
  invokes that same discard action from any result capsule. No result capsule uses
  a copied checkmark. Anchor the result-only capsule to the screenshot's top-left. Prefer
  placing it just outside the image above the top edge; when that would leave
  the screen, fall back inside the image's top-left (including fullscreen). A
  one-shot choice never rewrites the saved result mode; persistent modes remain
  explicit shortcuts that bypass this ask-every-time path.
- Keep the Apple-native design language already established in the HTML:
  system typography, restrained materials, simple grouping, and real state
  transitions. Do not introduce a separate design system for a new flow.
- During long capture, close the full-screen area selector immediately after a
  valid drag, retain a four-corner marker for the selected rect plus a dark surround
  that blocks pointer input only outside the selected rect,
  and let the user scroll the selected content with their normal wheel or trackpad
  while Captures appends only visually confirmed downward movement. Do not show a
  separate Stop control. Keep the compact five-control capsule beside the tiny
  click-through live thumbnail throughout capture: Close, Edit, OCR, Download,
  Copy. Edit ends recording and routes the frozen de-duplicated image into the
  existing native editor.
  Download ends recording and writes the frozen image with the configured format,
  filename, and save directory; it does not copy or enter the editor. Choosing a
  result action ends recording and routes that frozen image; Close ends recording
  without copying. Copy remains the visually standard rightmost action. The thumbnail
  aligns to the selected frame's top edge, independently of the capsule; each surface
  only shifts when its own screen edge would otherwise clip it. At the maximum image height, stop appending but
  retain the same controls until the person chooses. The thumbnail grows with
  stitched height, never intercepts input, and is excluded from capture output.
  Long capture never installs an Accessibility-backed input guard or asks for that
  permission. One nonactivating, non-capturable visual dimming panel draws one
  continuous gray surround with the same rounded visual selected cutout. Four separate
  nonactivating, non-capturable transparent shields cover only the gray space
  above, below, left, and right of the selection and consume pointer input there.
  The center marker and thumbnail stay click-through, so the selected app owns
  the person's original wheel or trackpad input while Captures observes only
  screen-recording frames inside the selected rect. The capsule remains an
  interactive surface above the shields: each of its five buttons must receive
  the click, freeze the result once, and route that same image. A one-shot result
  never changes the saved mode.
- The image editor uses one compact system-title bar that embeds the top tool
  tabs and command actions, plus one compact contextual tool strip immediately
  below it. That strip is the current tool's real parameter surface: keep
  color, stroke, fill, font, opacity, strength, and crop/resize controls
  visible when that tool needs them. Its text is an auxiliary tier below the
  title-row category labels, which remain the editor's largest control text;
  do not add a sidebar, second custom rail, or floating tool palette. The
  internal title bar keeps `Captures` but does not repeat the selected page
  name.
- On opening a normal capture, the editor must preserve its actual 100% size
  and size the canvas window around it. Only reduce a capture proportionally
  if it cannot fit the currently visible screen. Long captures retain a useful
  vertically pannable viewport rather than becoming a thin full-page preview.
  After opening, resizing the editor window must scale the image and its
  annotations proportionally with the available canvas and update the zoom
  percentage. Preserve explicit zoom adjustments relative to the resized
  viewport and retain the reading position for long captures. Changing a tool
  or its parameter strip alone must not reset the zoom. Drawing tools stay
  active across repeated and overlapping strokes; moving/resizing an existing
  annotation belongs to the explicitly selected Mouse tool.
- Treat the page switcher as an in-document page framework: page controls use
  `data-page-nav` and panes use `data-page-pane`. Keep every page mounted and
  switch visibility rather than `display: none`, so the live image editor
  retains its canvas and page state when the user returns to it. Present the
  switcher in its own compact navigation row above the prototype, never inside
  the simulated app title bar; transitions stay short, state-preserving,
  keyboard-operable, and respectful of reduced-motion settings.
- Keep the editor's feature groups concrete and discoverable: crop/rotate,
  retouch, the filter library, annotation, watermark, and output size. The
  title row selects the group; the single contextual strip below it remains the
  real tool and parameter surface for that group. The filter library is a
  single horizontally scrollable row of real, wide thumbnail previews with
  compact labels; do not collapse it into a clipped sliver or replace it with
  text-only presets.
- The native All-in-One HUD has one explicit drag handle. Dragging it presents
  a dimmed, non-capturable screen overlay with top, bottom, left, and right
  docking targets. Dropping on a target must snap the HUD to that edge and
  persist the matching Toolbar Position setting; cancelling away from every
  target returns it to its prior dock. While collapsed, the edge handle follows
  the display containing the pointer without moving an expanded or actively
  dragged HUD.
- If the prototype source-of-truth file or its interaction model changes,
  update the README and this section in the same change.

## Startup Contract

- The All in One prototype is served from the `Captures/` project root:
  `python3 -m http.server 8123`, then open
  `http://127.0.0.1:8123/design/all-in-one-prototype.html`.
- Do not start the server from `design/`; the image editor bundle is loaded
  from `Captures/Resources/ImageEditor/` through a project-root-relative URL.
- If the editor is blank, verify HTTP 200 for the HTML, reference PNG, and
  `Captures/Resources/ImageEditor/FilerobotImageEditor.min.js` before changing
  the prototype.
- The native app is a separate Xcode target. Build with the `Captures` scheme
  and a valid Apple Developer identity, then grant Screen Recording permission.
  Accessibility is optional: without it, use exclusive Carbon registration plus
  retry and report whether ownership was actually obtained. An active session
  event tap is the fallback for suppressing shortcuts that were already owned
  when Captures launched. Never replace this with an ad-hoc build.

## Public Repository

- This fork is maintained at https://github.com/KunZhang1997/Captures. Preserve
  upstream attribution to Nick Shatilo and the original Snapper contributors.
- Keep `LICENSE`, `NOTICE`, and bundled third-party notices with redistributed code.
- The prototype reference PNG is generated from fictional content with
  `swift design/generate-demo-reference.swift`. Do not replace it with personal
  screen captures. Private source material belongs in ignored `design-private/`.
- Public introduction and build instructions live in `README.md`; the detailed
  visual and interaction contract is retained in `docs/prototype-guide.md`.
- Push/PR CI validates source configuration. Signed build/test is an explicit
  workflow-dispatch option requiring Apple signing secrets. Never imply a
  passing source-validation job proves a signed build or real-user acceptance.

- Binary release automation is not installed. The prior release configuration
  is retained as the non-executing `docs/release-workflow.example.yml`. Keep it
  outside `.github/workflows/` unless the user requests binary release automation.
