# XPointer external annotation overlay prototype

This prototype validates a plugin-owned annotation layer for reflowable
CREngine documents. It intentionally does not fetch WeRead data yet.

## What it proves

- An underline can be projected from a saved XPointer range without changing
  the EPUB.
- The underline is painted through KOReader's supported
  `ReaderView:registerViewModule()` extension point, in the same paint pass as
  the page.
- Tap hit boxes remain separate from KOReader annotations and open the existing
  native WeRead thought popup.
- Page-mode projections are cached and invalidated by ReaderView layout resets
  or `DocumentRerendered`.

Prototype records are stored under `overlay_prototype` in the WeRead plugin
settings. They are not added to `ui.annotation.annotations` and are not written
to the book's `.sdr` annotation list.

## Manual test

1. Open a local EPUB or another reflowable CREngine document.
2. Open `Tools → WeRead → XPointer overlay prototype`.
3. Select `Add underline on current page`.
4. Close the menu. A short range near the top of the current view should have
   a gray underline.
5. Tap the underline outside the configured left/right page-turn edge. The
   normal WeRead thought popup should open.
6. Change font size, line spacing, margins and orientation. The underline
   should follow the same text after the document is rerendered.
7. Return to the prototype menu and inspect `Overlay metrics`. A repeated paint
   of the same page should use the page cache; changing layout should force a
   new projection.
8. Select `Clear prototype underlines` and verify the book and KOReader note
   list are unchanged.

## Prototype limits

- Only reflowable CREngine documents are supported. Fixed-layout PDF/DjVu
  coordinates are deliberately out of scope.
- The prototype generates a short range from the current view. It does not yet
  search quotations, bind a local book to WeRead, or populate the SQLite
  thought database.
- Records are keyed by the current file path. A production implementation
  needs a document fingerprint and XPointer/text validation after file changes.
- The renderer currently scans the small prototype record list. A production
  implementation needs a sorted position/chapter index before loading large
  annotation sets.

## Performance gate for further work

Do not connect full-book WeRead sync until low-memory device testing confirms:

- no second e-ink refresh is caused by the overlay;
- a normal page with a handful of marks adds no perceptible page-turn latency;
- rapid page turns do not queue projection work;
- scroll mode remains responsive;
- layout changes invalidate stale screen rectangles correctly.
