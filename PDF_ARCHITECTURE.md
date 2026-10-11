# PDF Support — Architecture & Implementation Plan

> **Audience:** AI coding agents (and humans) implementing PDF support in Hoshi Reader.
> **Branch:** `feat/pdf-support`
> **Status:** Plan. Nothing in this document is implemented yet.

Read this whole document before you write code. Each phase in [§14](#14-implementation-phases) is sized to be one PR / one agent session, and each has acceptance criteria. Do the phases in order. Don't skip ahead: later phases depend on types defined in earlier ones.

---

## 0. Ground rules for agents

1. **Match the existing code style.** 4-space indent. Every new file gets the standard header:
   ```swift
   //
   //  FileName.swift
   //  Hoshi Reader
   //
   //  Copyright © 2026 Manhhao.
   //  SPDX-License-Identifier: GPL-3.0-or-later
   //
   ```
   Keep comments sparse, as the codebase does. Use the existing naming (`BookStorage`, `FileNames`, `LookupEngine.shared`, `@Observable @MainActor class …ViewModel`).
2. **Concurrency settings.** The app target uses Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`, so **every type is `@MainActor` unless you say otherwise.** Mark pure data and compute types `nonisolated` (see `BookMetadata`, and `LookupEngine.Bundle`). Put the OCR engine in an `actor`. Never run OCR or page rendering on the main actor.
3. **Xcode project.** The project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77). New `.swift` files placed in existing folders (`Core/`, `Features/…`, `Models/`, `Util/`) are added to the app target automatically. Don't hand-edit `project.pbxproj` to add source files. You only need to edit it for the new Swift package dependency (do that through Xcode, or with a careful, minimal pbxproj edit that mirrors the existing `XCRemoteSwiftPackageReference` entries). Check that new files are **not** pulled into the `ShareExtension` target. Look at the `membershipExceptions` blocks.
4. **Don't regress EPUB.** Phases 1–6 must leave the EPUB reader byte-for-byte unchanged in behaviour. Prefer adding new PDF-specific types over generalising EPUB types. Refactors that share code between the two readers are out of scope unless a phase says otherwise.
5. **Build after every phase:** `xcodebuild -project "Hoshi Reader.xcodeproj" -scheme "Hoshi Reader" -destination 'generic/platform=iOS Simulator' build`.
6. **Localise user-facing strings** the way existing code does (`String(localized:)`, or SwiftUI `Text("…")` literals that land in `Localizable.xcstrings`).

---

## 1. Goals and non-goals

### Goals
- Import `.pdf` files (file picker, "Open in…" / share sheet, `hoshi://open?url=` remote import) into the existing bookshelf, next to EPUBs.
- Read PDFs page by page (paged or continuous), with right-to-left page order for Japanese books.
- **Tap a character to open the dictionary popup**, with the same behaviour as EPUB:
  - scan forward from the tapped character up to `maxSelectionLength` (16) characters, stopping at scan boundaries
  - `LookupEngine.shared.lookup(...)`
  - highlight the matched length
  - show `PopupView` (including nested popups, Anki mining with sentence and cloze offset, and audio)
- **Text source per page:**
  1. If the page has a usable embedded text layer, use it through PDFKit.
  2. Otherwise, run **PaddleOCR (PP-OCRv6 small, or the manga pack for books marked as manga)** on device and build a text layer from the result.
- Cache OCR results on disk so each page is OCR'd once.
- Track progress, show it on the bookshelf, and restore the last page.

### Non-goals (v1)
- ッツ (ttu) sync, Google Drive book upload, and Sasayaki audiobook matching for PDFs. Hide these for PDF books.
- Persistent user highlights, full-text book search, furigana handling, and font/appearance settings for PDFs.
- Editing PDFs or writing annotations into the PDF file. **Never modify the user's PDF.**
- Password-protected PDFs. Reject them with a clear error in v1.
- Dark-mode page inversion. Possible later.

---

## 2. What exists today (relevant parts only)

| Concern | File | Notes |
|---|---|---|
| Book metadata | [Models/Book.swift](Models/Book.swift) | `BookMetadata { id, title, author, epub, cover, folder, lastAccess, renamedTitle }`, `Bookmark`, `BookInfo` |
| Storage | [Core/BookStorage.swift](Core/BookStorage.swift) | `Application Support/Books/<folder>/` holds `metadata.json`, `bookmark.json`, `bookinfo.json`, `statistics.json`, `highlights.json`, and the `.epub`. `FileNames` enum. Generic `save`/`load`. |
| Import | [Features/Bookshelf/BookshelfViewModel.swift](Features/Bookshelf/BookshelfViewModel.swift) | `importBooks` → `importBook(from:)` → `processImport(sourceURL:)`, which **assumes EPUB** (copies to a temp file named `*.epub` and unzips). `importRemoteBook(from:)` downloads to a temp URL with no meaningful extension. |
| Import UI | [Features/Bookshelf/BookshelfView.swift](Features/Bookshelf/BookshelfView.swift) | `.fileImporter(allowedContentTypes: [.epub])`. `pendingImportURL` handling (special-cases `.colpkg`/`.apkg`). |
| Doc types | [HoshiReader-Info.plist](HoshiReader-Info.plist) | `CFBundleDocumentTypes` declares `org.idpf.epub-container` and colpkg |
| Open reader | [Features/Bookshelf/ShelfView.swift](Features/Bookshelf/ShelfView.swift) | `readerWindow.present { ReaderLoader(book:) }` |
| Reader | [Features/Reader/ReaderView/ReaderView.swift](Features/Reader/ReaderView/ReaderView.swift), [ReaderViewModel.swift](Features/Reader/ReaderView/ReaderViewModel.swift) | EPUB-specific: `EPUBDocument`, spine, chapters. `ReaderLoader` builds `ReaderLoaderViewModel`, which loads the EPUB. |
| Tap → lookup | [Features/Reader/ReaderWebView/ReaderWebView.swift](Features/Reader/ReaderWebView/ReaderWebView.swift) (`Coordinator.handleTap`), [selection.js](Features/Reader/ReaderWebView/selection.js) | JS finds the character at the point, scans forward to `maxLength` while `!isScanBoundary`, extracts the sentence and `clozeOffset`, then posts `textSelected {text, sentence, rect, clozeOffset}`. Swift calls `onTextSelected(SelectionData) -> Int?`. A non-nil result is the matched length to highlight. A tap that hits nothing calls `onTapOutside`. |
| Lookup and popups | `ReaderViewModel.handleTextSelection`, `closePopups`, `closeChildPopups`; [Features/Popup/PopupView.swift](Features/Popup/PopupView.swift) | `PopupItem` stack. `PopupView(selectionData:lookupResults:dictionaryStyles:screenSize:isVertical:isFullWidth:coverURL:documentTitle:…)`. The popup is positioned from `SelectionData.rect` in the reader container's coordinate space. |
| Dictionary | [Core/LookupEngine.swift](Core/LookupEngine.swift) | `LookupEngine.shared.lookup(text, maxResults:, scanLength:) -> [LookupResult]`. `getStyles()`. |
| Anki | [Core/AnkiManager.swift](Core/AnkiManager.swift) | `clozeParts` uses `NSRange(location: clozeOffset, length: matched.utf16.count)`, so **`clozeOffset` is in UTF-16 units.** |
| Settings | [Core/UserConfig.swift](Core/UserConfig.swift) | `@Observable` singleton. Each property has `didSet { UserDefaults.standard.set(...) }` and a default in `init`. |
| Progress on shelf | `BookshelfViewModel.loadBookProgress` | `bookmark.characterCount / bookInfo.characterCount` |
| ttu export | [Features/Settings/BackupView.swift](Features/Settings/BackupView.swift) | Already skips books where `metadata.epub == nil`. |

---

## 3. High-level design

```
                ┌──────────────────────────── Bookshelf ─────────────────────────────┐
 .pdf file ───▶ │ BookshelfViewModel.processImport ──▶ PDFImporter.import(...)        │
                │   (sniff %PDF) writes metadata.json(pdf:), pdfinfo.json,           │
                │   bookinfo.json(pageCount), cover.jpg, <name>.pdf                  │
                └─────────────────────────────────────────────────────────────────────┘
                                         │ open book
                                         ▼
 ReaderLoader ──(book.format == .pdf)──▶ PDFReaderView ◀──── PDFReaderViewModel (@MainActor)
                                         │   ├─ PDFKitView (UIViewRepresentable around PDFView)
                                         │   │    ├─ tap gesture ─▶ page + page-space point
                                         │   │    └─ PDFPageOverlayViewProvider ─▶ HighlightOverlayView
                                         │   ├─ popups: [PopupItem] ──▶ PopupView (reused as is)
                                         │   └─ bookmark / progress / stats
                                         ▼
                         PDFTextLayerProvider (actor)       ◀── memory LRU + disk cache
                         │   layer(for pageIndex) async -> PDFTextLayer
                         ├─ EmbeddedTextExtractor (PDFKit page.string + characterBounds)
                         │      └─ EmbeddedTextQuality.isUsable(...)  ── no ──┐
                         └─ OCR path ◀────────────────────────────────────────┘
                              PageRenderer (PDFPage → CGImage, keeps page↔pixel transform)
                              PaddleOCREngine (actor, ONNX Runtime)
                                 ├─ DBTextDetector   (PP-OCRv6 det; pack chosen in settings)
                                 ├─ CTCTextRecognizer (PP-OCRv6 rec, per-char positions)
                                 └─ LayoutAnalyzer   (vertical/horizontal, ruby, reading order)
                                         │
                                         ▼
                         PDFTextLayer (pure data: lines → glyphs with page-space rects)
                                         │
                                         ▼
                         PDFTextScanner (pure functions, port of selection.js)
                           hitTest → scan(maxLength) → sentence + clozeOffset (UTF-16)
```

**Key decision:** both text sources (embedded and OCR) produce the **same `PDFTextLayer` model**. Hit testing, scanning, sentence extraction, highlighting, and popup placement are written once against that model. This also makes the scanner testable without PDFKit or ONNX.

---

## 4. Data model and storage

### 4.1 `BookMetadata` (modify [Models/Book.swift](Models/Book.swift))

Add an optional `pdf` file name. Optional properties decode as `nil` from old JSON, so existing `metadata.json` files keep working.

```swift
nonisolated enum BookFormat: String, Codable, Sendable {
    case epub
    case pdf
}

nonisolated struct BookMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let author: String?
    let epub: String?
    let pdf: String?          // NEW: file name of the PDF inside the book folder
    let cover: String?
    let folder: String
    var lastAccess: Date
    var renamedTitle: String?
    var displayTitle: String { renamedTitle ?? title }
    var format: BookFormat { pdf != nil ? .pdf : .epub }   // NEW

    init(id: UUID = UUID(), title: String, author: String? = nil, epub: String? = nil, pdf: String? = nil, cover: String?, folder: String, lastAccess: Date) { ... }
}
```

`pdf` is a defaulted init parameter, so existing call sites compile unchanged. Check them with `grep -rn "BookMetadata(" .`.

### 4.2 Book folder layout for a PDF

```
Application Support/Books/<sanitized title>/
├── metadata.json        BookMetadata (epub: nil, pdf: "<file>.pdf", cover: "Books/<folder>/cover.jpg")
├── <file>.pdf           untouched copy of the user's file
├── cover.jpg            page 1 rendered, long side 768 px, JPEG q=0.85
├── bookinfo.json        BookInfo(characterCount: pageCount, chapterInfo: [:], images: [])  ← shelf progress only
├── bookmark.json        Bookmark (see 4.4)
├── pdfinfo.json         PDFInfo (see 4.3)
├── statistics.json      same format as EPUB (optional, Phase 6)
└── textlayer/
    ├── page-00000.json  PDFTextLayer for page index 0
    └── ...
```

Add to `FileNames`:
```swift
static let pdfInfo = "pdfinfo.json"
static let textLayerDirectory = "textlayer"
```

### 4.3 `PDFInfo` (new, `Models/PDFBook.swift`)

```swift
nonisolated enum PDFTextSource: String, Codable, Sendable {
    case unknown      // not classified yet
    case embedded     // PDFKit text layer is usable
    case ocr          // OCR result cached in textlayer/
    case empty        // classified, no text found (blank or illustration page)
}

nonisolated struct PDFInfo: Codable, Sendable {
    let pageCount: Int
    var pageSources: [PDFTextSource]   // count == pageCount
    var pageCharacterCounts: [Int?]    // filled lazily, used for stats
    var forceOCR: Bool = false         // per-book override: ignore embedded text
}
```

### 4.4 Progress semantics for PDFs

Reuse the existing `Bookmark` and `BookInfo` so `BookshelfViewModel.loadBookProgress`, the "Reading" shelf, and statistics plumbing keep working without branches:

- `bookinfo.json`: `BookInfo(characterCount: pageCount, chapterInfo: [:], images: [])`
- `bookmark.json`: `Bookmark(chapterIndex: pageIndex, progress: 0, characterCount: pageIndex + 1, lastModified: Date())`

Shelf progress is then `(pageIndex + 1) / pageCount`, which is exactly 1.0 on the last page.

**Required branch:** `BookshelfViewModel.markRead` currently derives `chapterIndex` from `chapterInfo`. For PDFs, write `chapterIndex: pageCount - 1, characterCount: pageCount`.

### 4.5 Text layer model (new, `Models/PDFTextLayer.swift`)

All geometry is in **PDF page space**: points, origin at the bottom-left, in the coordinate system of `page.bounds(for: .cropBox)`. This is the space PDFKit's `characterBounds(at:)` and `PDFView.convert(_:from:)` use, so the embedded path needs no conversion. OCR converts once, at creation time (see §7.6).

```swift
nonisolated struct PDFGlyph: Codable, Sendable, Hashable {
    let character: String      // exactly one grapheme cluster
    let rect: CGRect           // page space
}

nonisolated struct PDFTextLine: Codable, Sendable {
    let isVertical: Bool
    let isRuby: Bool           // furigana / small annotation line. Excluded from scan and sentence.
    let blockIndex: Int        // lines in the same block are joined when scanning and building sentences
    var glyphs: [PDFGlyph]
    var bounds: CGRect         // union of glyph rects
    var text: String { glyphs.map(\.character).joined() }
}

nonisolated struct PDFTextLayer: Codable, Sendable {
    static let currentVersion = 1        // bump to invalidate caches when the format or algorithm changes
    let version: Int
    let pageIndex: Int
    let source: PDFTextSource
    let engine: String                   // "pdfkit", or OCRModelManifest.engineIdentifier, e.g. "ppocrv6-small-1"
    var lines: [PDFTextLine]             // already in reading order
}
```

Keep the disk JSON compact: a custom `Codable` that encodes `CGRect` as `[x, y, w, h]` rounded to 0.1 is enough. A typical dense page has around 600 glyphs, about 30 KB.

---

## 5. Import pipeline

### 5.1 Entry points

1. **File picker** ([BookshelfView.swift](Features/Bookshelf/BookshelfView.swift)): `allowedContentTypes: [.epub, .pdf]`.
2. **"Open in" / AirDrop** ([HoshiReader-Info.plist](HoshiReader-Info.plist)): add to `CFBundleDocumentTypes`:
   ```xml
   <dict>
       <key>CFBundleTypeName</key>
       <string>PDF</string>
       <key>LSHandlerRank</key>
       <string>Alternate</string>   <!-- don't claim to be the default PDF app -->
       <key>LSItemContentTypes</key>
       <array><string>com.adobe.pdf</string></array>
   </dict>
   ```
   `HoshiReaderApp.handleURL` already routes file URLs to `pendingImportURL`. No change is needed there.
3. **Remote import** (`hoshi://open?url=…` → `importRemoteBook`). The temp file has no reliable extension, so detect the format by **content sniffing**.

### 5.2 Format sniffing (new, `Util/BookFileType.swift`)

```swift
nonisolated enum BookFileType {
    case epub, pdf

    static func detect(_ url: URL) -> BookFileType? {
        // 1. Read the first 1024 bytes. If they contain "%PDF-", return .pdf.
        //    (The spec allows leading junk before the header, so don't require offset 0.)
        // 2. If they start with "PK\u{03}\u{04}", return .epub.
        // 3. Otherwise fall back to the extension: "pdf" → .pdf, "epub" → .epub.
    }
}
```

### 5.3 Changes in `BookshelfViewModel.processImport(sourceURL:)`

Insert at the very top:
```swift
if BookFileType.detect(sourceURL) == .pdf {
    try PDFImporter.importPDF(from: sourceURL, originalName: sourceURL.lastPathComponent)
    return
}
```
Leave the EPUB path untouched. The caller already handles security-scoped access, batching, and `loadBooks()`.

For `importRemoteBook`, pass a sensible original name, e.g. `url.lastPathComponent` of the remote URL, falling back to `"document.pdf"`.

### 5.4 `PDFImporter` (new, `Util/PDFImporter.swift`)

```swift
import PDFKit

struct PDFImporter {
    static func importPDF(from sourceURL: URL, originalName: String) throws
}
```

Steps:
1. `guard let doc = PDFDocument(url: sourceURL) else { throw PDFImportError.unreadable }`
2. `if doc.isLocked { throw PDFImportError.passwordProtected }`. Encrypted PDFs with an empty user password open unlocked, which is fine.
3. `guard doc.pageCount > 0 else { throw PDFImportError.empty }`
4. **Title:** `doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String`, trimmed. If it's empty, or looks like junk (e.g. `"Microsoft Word - foo.docx"`, `"untitled"`, or contains only ASCII when the file name contains Japanese), use the file name without its extension. **Author:** `PDFDocumentAttribute.authorAttribute`.
5. `folderName = BookStorage.sanitizeFileName(title)`. If `Books/<folderName>` already exists, return silently. This mirrors the EPUB duplicate behaviour.
6. Create the folder. Copy the file to `Books/<folderName>/<sanitized originalName, forced .pdf extension>` with `BookStorage.copyFile`.
7. **Cover:** render page 0 (see `PageRenderer` §7.5) with a long side of 768 px. Write `cover.jpg` (`UIImage.jpegData(compressionQuality: 0.85)`). `metadata.cover = "Books/<folder>/cover.jpg"`.
8. Write `metadata.json` (`epub: nil, pdf: fileName`), `bookinfo.json` (§4.4), and `pdfinfo.json` (all pages `.unknown`).
9. `StatisticsStorage.restore(folder: folderName)`. This matches the EPUB path.
10. On any error after step 6, delete the folder and rethrow. Mirror `finalizeImport`.

**Don't classify or OCR pages during import.** Import has to stay fast and synchronous like EPUB import. Classification is lazy (§6).

Errors: add `PDFImportError: LocalizedError` with localised messages ("Could not open PDF", "Password-protected PDFs are not supported", "PDF has no pages").

### 5.5 Other bookshelf touch points

- [BookCell.swift](Features/Bookshelf/BookCell.swift): hide **Sync** and **Match** (Sasayaki) when `book.format == .pdf`. Change **Export** so it shares `book.epub ?? book.pdf`.
- `BookshelfViewModel.markRead`: PDF branch (§4.4).
- `BookshelfViewModel.syncBook`: early `return` for PDFs as a safety net.
- `deleteBook` and `renameBook` work unchanged.
- [ShelfView.swift](Features/Bookshelf/ShelfView.swift) keeps presenting `ReaderLoader(book:)`. The branch lives in `ReaderLoader` (§9.1).

---

## 6. Text layer provider (orchestration and caching)

New file: `Features/PDFReader/TextLayer/PDFTextLayerProvider.swift`

```swift
actor PDFTextLayerProvider {
    init(pdfURL: URL, bookRoot: URL, info: PDFInfo, ocrEngine: PaddleOCREngine?)

    /// Returns immediately if cached in memory.
    func cachedLayer(for pageIndex: Int) -> PDFTextLayer?

    /// Loads from disk, or builds via embedded text / OCR. Coalesces concurrent requests for the same page.
    func layer(for pageIndex: Int, priority: TaskPriority = .userInitiated) async throws -> PDFTextLayer

    /// Fire-and-forget warmup for neighbours (current ± N). Low priority, cancellable.
    func prefetch(around pageIndex: Int, radius: Int)

    /// Deletes the cached layer and rebuilds with OCR (the "Re-run OCR on this page" menu action).
    func rebuildWithOCR(pageIndex: Int) async throws -> PDFTextLayer

    /// Sequential whole-book OCR with progress; cancellable (optional menu action).
    func ocrAllPages(progress: @Sendable (Int, Int) -> Void) async throws

    func cancelAll()
}
```

Rules:
- **Use a separate `PDFDocument` instance.** Open your own `PDFDocument(url:)` inside the actor. Don't share the `PDFView`'s document across threads.
- **In-flight coalescing.** Keep `[Int: Task<PDFTextLayer, Error>]`. A second request for the same page awaits the existing task.
- **Memory cache.** An LRU of about 12 pages is plenty.
- **Disk cache.** `textlayer/page-%05d.json`. Discard it if `version != PDFTextLayer.currentVersion`, or if it's an OCR layer whose `engine` doesn't match the **currently selected pack** (`OCRModelManifest.engineIdentifier(for: UserConfig.pdfOCRModel)`). Switching packs therefore re-OCRs pages lazily, one page at a time as they're needed.
- **Decision per page:**
  ```
  if !info.forceOCR, let layer = EmbeddedTextExtractor.extract(page), EmbeddedTextQuality.isUsable(layer)
      → source = .embedded (don't write to disk: PDFKit extraction is cheap and deterministic.
        Do update pdfinfo.json's pageSources.)
  else if UserConfig.pdfOCRMode != .off and the OCR model is available
      → OCR → source = .ocr or .empty → write to disk
  else
      → empty layer (taps fall through to onTapOutside); the UI may show the "Download OCR model" prompt
  ```
- Persist `pdfinfo.json` updates (sources, char counts) debounced. A once-per-few-seconds coalesced write is fine.
- **Prefetch policy:** on every page change, prefetch `current ± UserConfig.pdfPrefetchPages` (default 2), **forward pages first** (in reading direction), at `.utility` priority. Cancel prefetches that fall outside the window.

---

## 7. Text extraction

### 7.1 Embedded text (`Features/PDFReader/TextLayer/EmbeddedTextExtractor.swift`)

```swift
nonisolated enum EmbeddedTextExtractor {
    static func extract(page: PDFPage, pageIndex: Int) -> PDFTextLayer?
}
```

Algorithm:
1. `guard let string = page.string, !string.isEmpty`.
2. Enumerate grapheme clusters: `(string as NSString).enumerateSubstrings(in:options: .byComposedCharacterSequences)`. For each cluster at NSRange `r`, take `page.characterBounds(at: r.location)`. The `characterBounds` index is a UTF-16 index into `page.string`. Verify this on a test file with surrogate-pair kanji (e.g. 𠮟).
3. Skip glyphs with an empty, zero-area, or non-finite rect. Treat whitespace as a **line separator candidate** but don't emit it as a glyph.
4. **Line building:** start a new line on `\n`/`\r`, or when the next glyph isn't geometrically adjacent. Adjacent means the gap along the reading axis is under about 1.5 × the glyph size and the cross-axis overlap is above 50%.
5. **Orientation per line:** with ≥ 2 glyphs, a line is vertical if `|Δcenter.y| > |Δcenter.x|` between consecutive glyphs and y decreases (page space y points up). Single-glyph lines inherit the page's majority orientation.
6. Run the result through `LayoutAnalyzer` (§7.7) for ruby detection, block assignment, and reading-order sort. Embedded text order is usually right already, but malformed PDFs exist. Sort anyway: it's cheap.

### 7.2 Embedded text quality (`EmbeddedTextQuality.isUsable`)

Many Japanese PDFs have **broken text layers**: wrong ToUnicode CMaps that produce mojibake, invisible text that's offset from the image, or only a title stamp on a scanned page. A layer counts as usable when **all** of the following hold:

| Check | Threshold |
|---|---|
| Non-whitespace glyph count | ≥ 8 (otherwise treat as "no text"; OCR decides if the page is really blank) |
| Fraction of glyphs that are Japanese, ASCII printable, or common punctuation (reuse the `JAPANESE_RANGES` port from §8.1) | ≥ 0.85 |
| `U+FFFD` or private-use (`U+E000–U+F8FF`) glyphs | ≤ 2% |
| Glyphs whose rect lies inside the page's crop box | ≥ 90% |
| Text area coverage is plausible | union of glyph rects ≥ 1% of page area |

If the check fails, fall through to OCR. Users can also force OCR per book (`PDFInfo.forceOCR`) from the reader menu, for layers that pass the heuristic but are still wrong.

---

### 7.3 PaddleOCR on iOS: runtime decision

| Option | Verdict |
|---|---|
| **ONNX Runtime** (`onnxruntime-swift-package-manager`) + PP-OCR models in ONNX format | ✅ **Chosen.** Official Microsoft SPM package, CPU EP is reliable, optional CoreML EP. PaddlePaddle publishes official ONNX files for PP-OCRv6. All pre- and post-processing is ours in Swift, so we control per-character positions. |
| Paddle Lite (official PaddleOCR iOS demo) | ❌ Old demo. Objective-C++ static libs and an `.nb` model format. Hard to maintain with Swift 6 and SPM. |
| Convert to Core ML via coremltools | ❌ The ONNX→Core ML path is deprecated in coremltools. Dynamic widths in the rec model are painful. |
| Apple Vision `VNRecognizeTextRequest` | ❌ Not PaddleOCR (the product requirement), and weak on vertical Japanese. Keep the `OCREngine` protocol so it could be added later as a fallback. |

#### Model choice: PP-OCRv6, user-selectable tier

PP-OCRv6 (released 2026-06-11 with PaddleOCR 3.7.0) is the latest PP-OCR generation. It uses a PPLCNetV4 backbone and comes in three tiers. Figures below are from PaddleOCR's own docs and benchmark; they are **not** measured on iOS.

| Model | Det Hmean | Rec acc. | Japanese | Apple M4 s/img (Paddle, CPU) | Role in Hoshi |
|---|---|---|---|---|---|
| PP-OCRv5_mobile | 75.2 | 73.7 | yes | 5.82 | Removed (earlier builds offered it as "Legacy") |
| PP-OCRv6_tiny | 80.6 | 73.5 | **no** | 0.96 | ❌ Not usable: no Japanese |
| **PP-OCRv6_small** | 84.1 | 81.3 | yes | 3.07 | ✅ **Default** on all devices |
| PP-OCRv6_medium | 86.2 | 83.2 | yes | not published (est. ≈ 5–6 s*) | Removed (earlier builds offered it as "High accuracy") |

\* PaddleOCR doesn't publish an M4 time for medium. On their Xeon benchmark, medium takes about 1.8 times as long as small (1.40 s vs 0.79 s), which suggests roughly 5.5 s on M4. Phase 4 must measure the real number.

Decisions:
- **Default: `PP-OCRv6_small`** (det + rec). It's more accurate than v5 mobile, faster, and supports Japanese.
- **No medium or v5 mobile.** Earlier builds offered `PP-OCRv6_medium` ("High accuracy", 8 GB devices only, about 140 MB) and `PP-OCRv5_mobile` ("Legacy") as optional downloads; both were removed. On the tategaki fixtures medium scored 94.1% against small's 93.7% at about 3× the detection and 4× the recognition time. `OCRModelStore` deletes their downloaded files on launch (`OCRModelPack.retired`).
- **Never use tiny.** Its language list doesn't include Japanese.
- **Vertical-text gate.** PaddleOCR's v6 docs don't mention vertical text. Before v6 becomes the shipped default, Phase 4 must run small (and medium) **and** v5 mobile on the tategaki fixtures (§15.1) and compare character accuracy. If v6 does clearly worse on vertical text, ship v5 mobile as the default and keep v6 as an option. The engine abstraction and manifest make this a data change, not a code change.
- **No orientation classifier.** Skip the text-line orientation classifier (`cls`). Book scans are upright, and we handle vertical lines geometrically (§7.6).
- **Pin model versions.** v6 is only a few months old. Pin exact file URLs and SHA-256s, and expect to re-export if PaddlePaddle ships fixed weights.

Abstraction:
```swift
nonisolated protocol OCREngine: Sendable {
    var identifier: String { get }               // stored as PDFTextLayer.engine
    func recognize(_ image: CGImage) async throws -> [OCRLine]   // pixel space, top-left origin
}

nonisolated struct OCRLine: Sendable {
    let quad: [CGPoint]          // 4 points, pixel space (axis-aligned rect in v1)
    let isVertical: Bool
    let text: String
    let confidence: Float
    let glyphs: [(character: String, rect: CGRect)]   // pixel space
}
```

### 7.4 Models: obtaining, converting, shipping

**Getting the files (one-time, done by the maintainer; document it in `Scripts/ocr/fetch_models.sh`):**

1. **Preferred: the official ONNX files.** PaddlePaddle publishes PP-OCRv6 as safetensors, Paddle inference **and ONNX** in the Hugging Face collection `PaddlePaddle/pp-ocrv6` (mirrored on ModelScope). For each tier we use (`small`, `medium`), download the det and rec ONNX files plus each model's config (`inference.yml` / `config.json`). Repo and file names aren't confirmed in this plan: look them up in the collection and write them into the script.
2. **Fallback: export it yourself** from the Paddle inference format (`inference.json` + `inference.pdiparams` + `inference.yml`):
   ```bash
   python -m venv .venv
   source .venv/bin/activate
   pip install "paddlepaddle>=3.0" "paddleocr>=3.7" paddle2onnx
   paddle2onnx --model_dir <tier>_det_infer --model_filename inference.json \
               --params_filename inference.pdiparams --save_file det.onnx --opset_version 14
   paddle2onnx --model_dir <tier>_rec_infer --model_filename inference.json \
               --params_filename inference.pdiparams --save_file rec.onnx --opset_version 14
   ```
   Use the same commands for the `PP-OCRv5_mobile` fallback (`PP-OCRv5_mobile_det_infer`, `PP-OCRv5_mobile_rec_infer`).
3. **Character dictionary.** Take `PostProcess.character_dict` from the **rec** model's `inference.yml` and write it one character per line to `dict.txt`. v6 extended the dictionary (about 200 extra diacritics), so **never reuse the v5 dictionary with v6 models, or the other way round.** A mismatch produces fluent garbage, not an error. Add a startup check: `C` (rec output classes) must equal `dict.count + 1`, or `dict.count + 2` with the space class.
4. **Pre- and post-processing parameters.** Also extract from each `inference.yml` (det: resize limits, `mean`/`std`, channel order, `thresh`, `box_thresh`, `unclip_ratio`; rec: input height, max width, normalisation). Store them in `params.json` next to the model. **The Swift code reads these values instead of hard-coding the numbers in §7.6.** The §7.6 numbers are PaddleOCR v5 defaults and serve only as fallbacks. v6 changed the backbone, the det neck (RepLKFPN) and the det loss (DiceBCE), so its defaults may differ.
5. Record the size and SHA-256 of every file in the manifest.

Also write `Scripts/ocr/reference.py`: a small Python reference pipeline using `onnxruntime` with the same pre- and post-processing and the same `params.json`. Use it to produce golden outputs for the test fixtures (§15). It's the fastest way to catch channel-order and normalisation bugs in the Swift port. The official `paddleocr` package (`engine="onnxruntime"`) is a second cross-check on the reference script itself.

**Shipping:** download on demand; don't bundle (the app is meant to be lightweight). Each **model pack** is one directory holding `det.onnx`, `rec.onnx`, `dict.txt` and `params.json`.

`Core/OCRModelStore.swift`:
```swift
nonisolated enum OCRModelPack: String, CaseIterable, Codable, Sendable {
    case v6Small = "ppocrv6-small"        // every book
    case v6Manga = "ppocrv6-manga"        // v6 small det + Kellenok's manga rec, only for books marked as manga

    static let retired = ["ppocrv6-medium", "ppocrv5-mobile"]   // deleted from OCRModels/ on launch
}

nonisolated struct OCRModelFile: Sendable { let name: String; let url: URL; let sha256: String; let bytes: Int }

nonisolated enum OCRModelManifest {
    static let revision = 1                                   // bump when any file changes
    static func files(for pack: OCRModelPack) -> [OCRModelFile] { /* det.onnx, rec.onnx, dict.txt, params.json */ }
    static func totalBytes(for pack: OCRModelPack) -> Int     // shown in the download UI
    static func engineIdentifier(for pack: OCRModelPack) -> String { "\(pack.rawValue)-\(revision)" }  // → PDFTextLayer.engine
}

@Observable @MainActor
final class OCRModelStore {
    static let shared = OCRModelStore()
    enum State { case notInstalled, downloading(Double), installed, failed(String) }
    private(set) var states: [OCRModelPack: State]
    func directory(for pack: OCRModelPack) -> URL     // Application Support/OCRModels/<pack.rawValue>/
    func download(_ pack: OCRModelPack) async         // URLSession download → verify SHA-256 (CryptoKit) → atomic move
    func delete(_ pack: OCRModelPack)
    nonisolated static func installedPaths(for pack: OCRModelPack) -> (det: URL, rec: URL, dict: URL, params: URL)?
}
```
- **The book's pack** is `.v6Small`, or `.v6Manga` for books marked as manga (`PDFReaderViewModel.ocrPack`). There is no model setting. If the pack isn't installed, the reader shows the download prompt (§12), and the prompt states the pack's size from the manifest.
- **Manga pack.** `.v6Manga` pairs the v6 small detector with [Kellenok/PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga)'s `manga_rec_v0.2` (a manga fine-tune of the v6 small recognizer, Apache-2.0; same dictionary, preprocessing and `params.json` as v6 small). A book uses it instead of `.v6Small` when `PDFInfo.isManga` is set ("Use Manga Model for This Book" in the reader menu). Its own detector (`manga_det_v0.2`) isn't used: on book pages it misses or truncates most ruby and clips sentence-final 。.
- **Switching packs** doesn't delete cached OCR pages. Each cached layer records `engine`, and the provider (§6) treats a layer from a different engine as stale and re-OCRs that page lazily when it's next needed.
- **Hosting.** `det.onnx` and `rec.onnx` download straight from PaddlePaddle's Hugging Face repos (and Kellenok/PP-OCRv6_manga for the manga recognizer), **pinned to a commit** (`/resolve/<commit>/inference.onnx`) and verified against SHA-256, so they can't change underneath the app. `dict.txt` and `params.json` are derived files that Hugging Face doesn't host, so they ship in the app bundle (`Features/PDFReader/OCR/Packs/<pack>-dict.txt`, `<pack>-params.json`, about 75 KB per pack); `fetch_models.sh` regenerates them. The `ocr-models-v1` GitHub release originally planned here was never published (its URLs returned 404). If the packs are ever self-hosted, `fetch_models.sh` still writes the flat `release/` copies.
- **Dev fallback:** `installedPaths(for:)` checks `Bundle.main` for `<pack>/det.onnx` etc. before Application Support. Developers can drop the files into the project locally without committing them; add them to `.gitignore`.
- Mark the model directories `isExcludedFromBackup = true` (`URLResourceValues`).

### 7.5 Page rendering (`Features/PDFReader/OCR/PageRenderer.swift`)

```swift
nonisolated struct RenderedPage {
    let image: CGImage            // RGBA8, sRGB, opaque white background
    let pixelToPage: CGAffineTransform   // maps image pixel (top-left origin) → PDF page space
}

nonisolated enum PageRenderer {
    static func render(_ page: PDFPage, longSide: CGFloat) -> RenderedPage
}
```

Implementation:
```swift
let box: PDFDisplayBox = .cropBox
let t = page.transform(for: box)                       // page space → rotated, origin-normalised space
let rotated = page.bounds(for: box).applying(t)        // size after /Rotate
let scale = longSide / max(rotated.width, rotated.height)
let W = Int(rotated.width * scale), H = Int(rotated.height * scale)
// CGContext(W×H, RGBA). Fill white. Then:
ctx.scaleBy(x: scale, y: scale)                        // CG context origin is bottom-left, same as page space
page.draw(with: box, to: ctx)                          // draw(with:to:) applies the rotation transform itself
// pixel → page:
//   p_rot  = CGPoint(x: px / scale, y: (CGFloat(H) - py) / scale)
//   p_page = p_rot.applying(t.inverted())
```
**Verify on a PDF with `/Rotate 90`** that an OCR box lands on the right glyph (§15 fixtures). If `draw(with:to:)` doesn't apply the rotation on the OS version you test, apply `ctx.concatenate(t)` yourself, and keep `pixelToPage` consistent with whatever you actually drew.

Render size for OCR: **long side 2048 px** (default). Japanese body text in a scanned A5/B6 bunko page is about 25–30 px per character at this size, which suits a rec input height of around 48. Expose it as a constant.

### 7.6 PaddleOCR pipeline in Swift (`Features/PDFReader/OCR/`)

Files: `PaddleOCREngine.swift` (actor, owns ORT sessions), `DBTextDetector.swift`, `CTCTextRecognizer.swift`, `ImageTensor.swift` (pixel access and resizing helpers), `OCRParams.swift` (decodes `params.json`).

`PaddleOCREngine` is created for one `OCRModelPack`, and its `identifier` is `OCRModelManifest.engineIdentifier(for:)`. The same Swift pipeline serves all packs; only the files and `params.json` differ. **The numeric constants below are PaddleOCR v5 defaults.** Use them only when `params.json` lacks a value, and log a warning when that happens.

> **Check first (v6):** v6 changed the det neck and loss. Before writing post-processing, confirm that the v6 det ONNX output is still a single-channel probability map `[1, 1, H, W]` with values in [0, 1]. Run the model once in `reference.py` and save the map as a PNG. If it outputs logits, apply a sigmoid first. If the shape is different, stop and update this section before continuing.

#### ONNX Runtime setup
- SPM: `https://github.com/microsoft/onnxruntime-swift-package-manager`, product **`onnxruntime`**. Pin an exact recent stable version, and add it to `Package.resolved`. Check the package's `Package.swift` for the importable module name; it's `OnnxRuntimeBindings` in current releases.
- One `ORTEnv` per process. One `ORTSession` each for det and rec, created lazily in the actor and released on `UIApplication.didReceiveMemoryWarningNotification`. When the user switches packs, tear down the old engine and its sessions. Never keep two packs loaded: medium alone is about 140 MB of weights.
- `ORTSessionOptions`: `setGraphOptimizationLevel(.all)`, `setIntraOpNumThreads(2)`. Use 4 threads on devices with ≥ 8 GB RAM; measure this in Phase 4. Start with the **CPU EP**.
- **CoreML EP is a Phase 4 benchmark, not an assumption.** `appendCoreMLExecutionProvider` can put medium on the Neural Engine, which may be what makes medium practical. But dynamic input shapes often make the CoreML EP fall back to CPU or recompile per shape. If you try it, use **fixed shape buckets** (det: a few fixed page sizes; rec: widths 320/640/960/1280/1920/3200) so the CoreML EP sees only a handful of shapes. Ship the CoreML EP only if it's faster on device **and** its output matches CPU on the fixtures.
- **Read input and output names at runtime** (`session.inputNames()`, `outputNames()`). Don't hard-code `"x"`.
- Tensors: `ORTValue(tensorData: NSMutableData, elementType: .float, shape: [NSNumber])`. Read output with `tensorData()` and `tensorTypeAndShapeInfo().shape`.

#### Detection (DB), `DBTextDetector`
Pre-processing:
1. Resize the rendered page so its **long side is ≤ 1536** while keeping the aspect ratio, then round **both** sides to multiples of 32 (minimum 32). Keep `ratioW = resizedW / srcW` and `ratioH = resizedH / srcH`.
2. Convert to float NCHW `[1, 3, H, W]` in **BGR** channel order (PaddleOCR reads images with OpenCV): `v = (pixel/255 − mean) / std`, with mean `[0.485, 0.456, 0.406]` and std `[0.229, 0.224, 0.225]` applied in the order PaddleOCR does. **Confirm channel order and normalisation against `reference.py`.**

Post-processing. Pure Swift, no OpenCV; v1 uses axis-aligned boxes:
1. Output `[1, 1, H, W]` probability map `P`. `bitmap = P > 0.3` (`thresh`).
2. Connected components (8-connectivity, iterative BFS or union-find over a `[UInt8]` buffer; **no recursion**).
3. For each component, compute the pixel bbox and `score = mean(P over component pixels)`. Drop it if `score < 0.6` (`box_thresh`) or `min(bboxW, bboxH) < 3`.
4. **Unclip** (DB shrinks text regions during training): `area = w*h`, `perimeter = 2*(w+h)`, `d = area * unclipRatio / perimeter`, with `unclipRatio = 1.6` (tune between 1.5 and 2.0). Expand the bbox by `d` on every side.
5. Scale back to rendered-image pixels (`/ ratioW`, `/ ratioH`) and clamp to the image.
6. Cap at 300 boxes per page. If a book page produces more, something is wrong.

Constants go in one `struct DBConfig` so tuning happens in one place.

> Axis-aligned boxes are fine for book scans with less than 2° skew. If you later need rotated boxes, add min-area-rect via convex hull + rotating calipers. That's not v1.

#### Line orientation and cropping
For each box (pixel space): `isVertical = h >= 1.5 * w`. Boxes that are roughly square (a single character) take the page-majority orientation, which `LayoutAnalyzer` resolves afterwards. Crop the box from the rendered image. If it's vertical, **rotate the crop 90° counter-clockwise** (what PaddleOCR's `np.rot90` does). The top of the column then becomes the left of the strip, so left-to-right in the strip is top-to-bottom on the page. This is how PaddleOCR's own pipeline feeds vertical lines to the rec model. Whether v6 reads these rotated tategaki strips well is exactly what the vertical-text gate in §7.3 tests.

#### Recognition (CTC), `CTCTextRecognizer`
Pre-processing per crop:
1. Target height from `params.json` (v5 default **48**; v6 may differ). `resizedW = min(ceil(recH * w / h), maxW)`, with `maxW` 3200 unless `params.json` says otherwise. Bilinear resize (`CGContext` with `.high` interpolation, or vImage).
2. Normalise to [-1, 1]: `v = (pixel/255 − 0.5) / 0.5`, same BGR order as det.
3. **Batch** crops sorted by aspect ratio, batch size 6. Pad each batch to its max width (multiple of 8, minimum 320) with **zeros after normalisation**. Track each crop's `validW`.

Decoding:
1. Output `[N, T, C]` softmax probabilities. Index 0 is the CTC blank. Index `i ≥ 1` maps to `dict[i − 1]`. If `C == dict.count + 2`, the last class is a space `" "` (`use_space_char`).
2. Greedy decode: per timestep `t`, `k_t = argmax`, `p_t = max`. Collapse consecutive repeats, drop blanks. **For each emitted character record its timestep span `[tStart, tEnd]`.**
3. Line confidence is the mean of `p_t` over emitted frames. Drop the line if confidence < 0.5 or the text is empty.
4. Ignore timesteps beyond `ceil(T * validW / paddedW)` (padding region).

**Per-character positions.** This is what makes tap-to-lookup work on OCR text:
```
stride  = paddedW / T                          // compute it, never hard-code: ≈ 8 for v5 rec; v6 may differ
center_i = (tStart_i + tEnd_i + 1) / 2 * stride   // in resized-strip pixels
```
- Glyph boundaries along the strip are the midpoints between adjacent centers. First and last glyphs extend by half the median spacing, clamped to `[0, validW]`.
- **CJK refinement:** if every character in the line is fullwidth (kana/kanji/fullwidth punctuation), Japanese is close to fixed-pitch, so divide `[firstStart, lastEnd]` into equal cells instead. This is usually more accurate than raw CTC peaks. Keep the CTC positions only for mixed-width lines.
- The cross-axis extent is the full strip height.
- Map back: strip px → crop px (`× cropW / resizedW` along the axis) → un-rotate for vertical lines (strip x → page-image y going down from the crop top; strip y → image x) → rendered-image px → **page space** with `pixelToPage`.

#### Performance budget

PaddleOCR's published timings are full-pipeline runs with Paddle on desktop chips. Treat them as relative numbers only. **The targets below are what Phase 4 must measure on device.** Log timings with `os.Logger` (subsystem `de.manhhao.hoshi`, category `ocr`) in DEBUG.

| Pack | Reference device | Target per page (render + det + rec, dense tategaki page, 15–20 lines) |
|---|---|---|
| v6 small (default) | A15/A16 iPhone, CPU EP | **≤ 2 s** |
| v6 small | M-series iPad | ≤ 1 s |

- If v6 small misses its iPhone target by a lot, lower the det input limit first (1536 → 1280) before changing anything else.
- Watch thermals during "OCR all pages". Add a short sleep between pages if the device reports `ProcessInfo.thermalState >= .serious`.

### 7.7 Layout analysis (`Features/PDFReader/TextLayer/LayoutAnalyzer.swift`)

Shared by both sources. Input: unordered lines with glyphs in page space. Output: lines with `isRuby`, `blockIndex`, in reading order.

1. **Page orientation:** majority vote of `isVertical`, weighted by glyph count. Re-assign single-glyph lines to the majority.
2. **Ruby (furigana) detection:** compute the median line thickness (cross-axis size) over lines with ≥ 3 glyphs. A line is ruby if its thickness is < 0.6 × median **and** it sits within 1 × median of a main line on the side where ruby goes (right of vertical lines, above horizontal lines). Ruby lines are kept for drawing but excluded from hit-testing priority, scanning, and sentences. This mirrors `selection.js` rejecting `rt`/`rp`.
3. **Tiers/columns (段組):**
   - Vertical pages: group main lines into **tiers** by vertical overlap (overlap > 50% of the shorter line's height means same tier). Order tiers top → bottom. Within a tier, order lines **right → left** by `bounds.midX` descending.
   - Horizontal pages: group into **columns** by horizontal overlap. Order columns left → right, and lines top → bottom (page space y descending).
4. `blockIndex` is the tier/column index. Scanning and sentence extraction may cross line boundaries **within** a block (Japanese words wrap across lines), but never across blocks.
5. Drop lines whose glyph count is 0 after filtering.

---

## 8. Tap-to-lookup on PDF

### 8.1 Shared Japanese text helpers (`Util/JapaneseText.swift`)

A faithful **Swift port of the constants and logic in [selection.js](Features/Reader/ReaderWebView/selection.js)**. Keep the same values, and add a comment linking back to the JS so future edits stay in sync:
- `JAPANESE_RANGES` and `isCodePointJapanese(_:)`
- `scanDelimiters = "。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]：；:;，,.─\n\r"`
- `sentenceDelimiters = "。！？.!?\n\r"`
- `trailingSentenceChars = "。、！？」』）)】〉》〕｝}］]"`
- `brackets` map
- `isScanBoundary(_ ch: Character, scanNonJapaneseText: Bool) -> Bool`. Whitespace, `\u{3000}`, scan delimiters, and (when `scanNonJapaneseText == false`) non-Japanese characters are boundaries. `UserConfig.shared.scanNonJapaneseText` already exists.
- `sentence(in text: String, at index: String.Index) -> (sentence: String, clozeOffset: Int)`: port of `getSentence`, **including the unmatched-bracket trimming**, operating on one flat string. **`clozeOffset` must be in UTF-16 code units** (JS string indices are UTF-16, and `AnkiManager.clozeParts` builds an `NSRange` from it).

### 8.2 `PDFTextScanner` (`Features/PDFReader/TextLayer/PDFTextScanner.swift`)

Pure `nonisolated enum`, no UIKit/PDFKit imports. This makes it easy to unit test.

```swift
nonisolated struct PDFGlyphRef: Hashable, Sendable { let line: Int; let glyph: Int }

nonisolated struct PDFScanResult: Sendable {
    let text: String                 // up to maxLength graphemes
    let glyphs: [PDFGlyphRef]        // same count as text graphemes, used for highlighting
    let sentence: String
    let clozeOffset: Int             // UTF-16
    let firstGlyphRect: CGRect       // page space, used for popup placement
    let isVertical: Bool
}

nonisolated enum PDFTextScanner {
    static func hitTest(_ layer: PDFTextLayer, point: CGPoint) -> PDFGlyphRef?
    static func scan(_ layer: PDFTextLayer, from hit: PDFGlyphRef, maxLength: Int, scanNonJapaneseText: Bool) -> PDFScanResult?
}
```

**`hitTest`** (point in page space):
1. If the point is inside a ruby glyph (rect inflated by 10% of line thickness), map it to the **first glyph of its base word**. This comes first because OCR main-line boxes usually include the ruby column. Mapping: take the ruby run around the tapped glyph, then the nearest main line on the base side (left of vertical ruby, below horizontal ruby). Anchor on that line's glyph nearest the run's centre, then extend backwards over kanji that are within half a glyph of the run. OCR ruby boxes drift by up to about a glyph along the line, so plain overlap isn't enough.
2. Otherwise, for non-ruby lines, inflate each glyph rect by 10% of line thickness. If one contains the point, that's the hit.
3. Otherwise take the **nearest** glyph (distance to rect) among non-ruby lines, if it's within `0.5 × line thickness`.
4. Otherwise apply rule 3 to ruby lines and map the result as in rule 1.
5. Otherwise return `nil`.

**`scan`** (mirrors `selectText`):
1. If the hit glyph is a scan boundary, return `nil` (the caller treats this as a tap outside).
2. Walk forward from the hit glyph. When the line ends, continue at the next line **in the same block**. Append characters until `isScanBoundary` or `maxLength`.
3. Sentence: concatenate the texts of all lines in the hit's block (no separators), compute the hit's index in that string, and call `JapaneseText.sentence(in:at:)`. Cap the block text at about 1000 characters around the hit, for safety.
4. Return `nil` if the text is empty.

**Toggle behaviour** (same as JS): if the new hit equals the current selection's first glyph, clear the selection and treat the tap as a tap outside. The view model tracks this, not the scanner.

### 8.3 Gesture handling in `PDFKitView`

`PDFKitView: UIViewRepresentable` wraps `PDFView`. The coordinator does the following.

- Adds a `UITapGestureRecognizer`:
  - `cancelsTouchesInView = false` and `delaysTouchesEnded = false`.
  - Delegate `shouldRecognizeSimultaneouslyWith` returns `true` (except for `UILongPressGestureRecognizer`, as in `ReaderWebView`).
  - **Don't** `require(toFail:)` PDFView's double-tap. That adds a 300 ms delay to every lookup. Accept that a double-tap zoom also triggers a lookup on its first tap.
- `handleTap`:
  1. If `pdfView.currentSelection` is non-nil (native long-press selection is active), clear it and return.
  2. `let p = gesture.location(in: pdfView)`. `guard let page = pdfView.page(for: p, nearest: false)`, otherwise `onTapOutside()`.
  3. `let pagePoint = pdfView.convert(p, to: page)`. `let pageIndex = document.index(for: page)`.
  4. Call `onPageTap(pageIndex, pagePoint)`. The view model does the rest (§9.2).
- Page turns: for paged mode, PDFView's page view controller handles swipes. Observe `Notification.Name.PDFViewPageChanged` and call `onPageChanged(index)`.
- Geometry helper for the view model: `func rectInView(_ rect: CGRect, pageIndex: Int) -> CGRect` returns `pdfView.convert(rect, from: page)`.

### 8.4 Selection highlight overlay

Use **`PDFPageOverlayViewProvider`** (iOS 16+; the deployment target is 18.0). Don't use `PDFAnnotation`s: they mutate the in-memory document and could be saved.

```swift
final class PDFHighlightOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    private var overlays: [Int: PDFHighlightOverlayView] = [:]     // by page index
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView?
    func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage)
    func setHighlight(pageIndex: Int, rects: [CGRect])    // page-space rects
    func clear()
}

final class PDFHighlightOverlayView: UIView {
    var pageRects: [CGRect] = [] { didSet { setNeedsLayout() } }
    // layoutSubviews: convert each page rect → this view's coordinates:
    //   let r = pdfView.convert(pageRect, from: page); convert(r, from: pdfView)
    // and draw with a CAShapeLayer (fill: accent colour at 0.3 alpha, same as the EPUB "hoshi-selection" look).
}
```
- Set `isUserInteractionEnabled = false` on the overlay.
- Set `pdfView.pageOverlayViewProvider` **before** assigning `pdfView.document`.
- DEBUG-only option: `showOCRBoxes` draws every line's bounds (main = blue, ruby = orange). This is invaluable when tuning §7.6 and §7.7.

---

## 9. Reader UI

### 9.1 Routing (`ReaderLoader`)

Modify `ReaderLoader` in [ReaderView.swift](Features/Reader/ReaderView/ReaderView.swift):
```swift
var body: some View {
    if viewModel.book.format == .pdf {
        PDFReaderView(book: viewModel.book)
    } else if let doc = viewModel.document, let root = viewModel.rootURL {
        ReaderView(...)                      // unchanged
    } else {
        BookLoadFailedView { dismissReader?() }
    }
}
```
Make `ReaderLoaderViewModel.loadBook()` return early for PDFs (`guard book.format == .epub`) so it doesn't try to unzip.

### 9.2 `PDFReaderViewModel` (`Features/PDFReader/PDFReaderViewModel.swift`)

`@Observable @MainActor final class PDFReaderViewModel`

State:
- `book`, `rootURL`, `pdfURL`, `document: PDFDocument?`, `info: PDFInfo`
- `pageIndex: Int`, `isLoadingPage: Bool` (shows the "Recognizing text…" indicator)
- `popups: [PopupItem]`, reusing the existing `PopupItem` type as is
- `currentScan: (pageIndex: Int, result: PDFScanResult)?`
- `textLayers: PDFTextLayerProvider`
- `ocrPrompt: Bool` (show the "Download OCR model" sheet)
- `activeSheet: PDFReaderSheet?` (`.contents`, `.settings`)

Methods:
- `init(book:)`: load `pdfinfo.json` (or rebuild it if missing: page count from the document, all `.unknown`), load `bookmark.json` → `pageIndex`, and stamp `lastAccess` like `ReaderLoaderViewModel` does.
- `pageChanged(to:)`: update `pageIndex`, close popups, clear the highlight, persist the bookmark (debounce 0.5 s; §4.4 semantics), `textLayers.prefetch(around:radius:)`, and stats (§9.5).
- `handlePageTap(pageIndex:point:) async`:
  ```
  let layer = await textLayers.cachedLayer(for:) ?? {
      if needs OCR and model not installed → ocrPrompt = true; return
      isLoadingPage = true; defer { isLoadingPage = false }
      let token = UUID(); latestTapToken = token
      let l = try? await textLayers.layer(for: pageIndex)
      guard latestTapToken == token else { return }      // user tapped elsewhere / turned page meanwhile
      return l
  }()
  guard let hit = PDFTextScanner.hitTest(layer, point),
        !(currentScan matches hit at glyph 0),
        let result = PDFTextScanner.scan(layer, from: hit, maxLength: 16, scanNonJapaneseText: UserConfig.shared.scanNonJapaneseText)
  else { clear selection; onTapOutside(); return }
  closePopups()
  let rect = rectInView(result.firstGlyphRect, pageIndex)          // via the PDFKitView coordinator
  let selection = SelectionData(text: result.text, sentence: result.sentence, rect: rect,
                                normalizedOffset: nil, clozeOffset: result.clozeOffset)
  if let matched = handleTextSelection(selection, isVertical: result.isVertical, ...) {
      highlight(result.glyphs.prefix(matched))                         // matched = String(firstResult.matched).count
      currentScan = (pageIndex, result)
  } else { clear highlight }
  ```
- `handleTextSelection(_:maxResults:scanLength:isVertical:isFullWidth:) -> Int?`, `closePopups()`, `closeChildPopups(parent:)`, `clearSelection()`: **copy the logic from `ReaderViewModel`**, minus the Sasayaki parts (`sasayakiCue = nil`, no auto-pause). Duplication is intentional for v1 (ground rule 4). Leave a `// todo: share with ReaderViewModel` comment.
- `rerunOCR(page:)`, `setForceOCR(_:)`, `ocrWholeBook()` with progress and cancel.
- `jump(to pageIndex:)` for the contents sheet and page slider.

### 9.3 `PDFReaderView` (`Features/PDFReader/PDFReaderView.swift`)

Mirror `ReaderView`'s chrome so the two feel the same, while staying much simpler:
- Background `readerBackgroundColor` (reuse the same theme logic; copy the computed properties).
- `GeometryReader { geometry in ZStack { PDFKitView(...).frame(geometry.size); ForEach popups → PopupView(...) } }`. `PDFKitView` fills the container, so **PDFView coordinates == popup coordinate space** and the `rect` from §9.2 can go straight to `PopupView`.
- `PopupView` arguments: `screenSize: geometry.size`, `isVertical: popup.isVertical`, `isFullWidth: popup.isFullWidth`, `coverURL: book.coverURL`, `documentTitle: book.displayTitle`. Wire `onTextSelected`, `onTapOutside`, and `onSwipeDismiss` exactly as `ReaderView` does (nested lookups inside the popup work unchanged, because they go through `handleTextSelection`).
- Focus mode toggle on tap outside (same `handleTapOutside` semantics: close popups if any are open, otherwise toggle chrome).
- Bottom bar: back button (`dismissReader`), page indicator `"\(pageIndex + 1) / \(pageCount)"`, and a menu with **Contents**, **Re-run OCR on this page**, **Always use OCR for this book** (toggle → `forceOCR`), **OCR all pages…**, and **PDF settings**.
- A small non-blocking `ProgressView` with the caption "Recognizing text…" while `isLoadingPage`.
- `.statusBarHidden(focusMode)` and `.persistentSystemOverlays`, like `ReaderView`.

### 9.4 `PDFKitView` configuration

```swift
pdfView.pageOverlayViewProvider = overlayProvider       // before document
pdfView.autoScales = true
pdfView.backgroundColor = .clear
switch UserConfig.shared.pdfDisplayMode {
case .paged:
    pdfView.displayMode = .singlePage
    pdfView.displayDirection = .horizontal
    pdfView.usePageViewController(true, withViewOptions: nil)
case .continuous:
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
}
pdfView.displaysRTL = UserConfig.shared.pdfRightToLeft   // Japanese books: page 2 is to the LEFT of page 1
pdfView.document = document
pdfView.go(to: document.page(at: initialPage)!)
```
- Configure page-view-controller mode **before** setting `document`. Re-create the view (`.id(...)`) when `pdfDisplayMode` or `pdfRightToLeft` changes, the same way `ReaderView` re-creates its web view with `WebViewState`.
- Two-page spreads (`.twoUp`) on iPad are a nice-to-have, not v1.

### 9.5 Statistics (Phase 6, optional for first merge)

Reuse `Statistics` and the per-book `statistics.json`, so the global Statistics tab picks PDFs up automatically.
- Count reading **time** exactly as `ReaderViewModel` does (tracking, pause on sheets/background).
- **Characters read:** when the user moves **forward** from page `i`, add `info.pageCharacterCounts[i]` (non-ruby glyph count) if it's known, otherwise 0. Moving backward subtracts nothing.
- `StatisticsSheet` is typed to `ReaderViewModel`. Either make a minimal `PDFStatisticsSheet`, or skip the in-reader sheet for v1 and only feed the global stats.

### 9.6 Contents sheet

`PDFContentsSheet`:
- **Outline:** walk `document.outlineRoot` recursively (`numberOfChildren`, `child(at:)`, `label`, `destination?.page`). Show indented rows with page numbers, and tap to jump.
- **Go to page:** a slider plus a numeric field.
- Optional: a thumbnail grid using `PDFThumbnailView` or `page.thumbnail(of:for:)` in a `LazyVGrid`.

---

## 10. Settings

Add to [Core/UserConfig.swift](Core/UserConfig.swift), following the existing `didSet` + `UserDefaults` pattern and `init` defaults:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `pdfDisplayMode` | `PDFDisplayMode { paged, continuous }` | `.paged` | |
| `pdfRightToLeft` | `Bool` | `true` | RTL page order (Japanese) |
| `pdfOCRMode` | `PDFOCRMode { auto, always, off }` | `.auto` | `auto`: OCR only pages without a usable text layer. `always`: ignore embedded text. `off`: never OCR. |
| `pdfPrefetchPages` | `Int` | `2` | Pages to pre-OCR ahead and behind |

UI: new `Features/Settings/PDFSettingsView.swift`, linked from [AdvancedView.swift](Features/Settings/AdvancedView.swift) as "PDF". It includes the settings above and an **OCR model** section: for each pack ("Standard (PP-OCRv6 small)" and "Manga (PP-OCRv6 manga)") its status, download size, a Download/Delete button and a progress bar. Under "Manga", a footnote says it's only used for books set to the manga model in the reader menu. The same view is presented as a sheet from the reader menu.

---

## 11. Integration checklist (every existing file that changes)

| File | Change |
|---|---|
| `Models/Book.swift` | `BookFormat`, `BookMetadata.pdf`, `format` |
| `Core/BookStorage.swift` | `FileNames.pdfInfo`, `textLayerDirectory`; `loadPDFInfo(root:)`, `textLayerURL(root:pageIndex:)` helpers |
| `Features/Bookshelf/BookshelfViewModel.swift` | PDF branch in `processImport`; `markRead` PDF branch; `syncBook` guard |
| `Features/Bookshelf/BookshelfView.swift` | `allowedContentTypes: [.epub, .pdf]` |
| `Features/Bookshelf/BookCell.swift` | Hide Sync/Match for PDF; Export uses `epub ?? pdf` |
| `Features/Reader/ReaderView/ReaderView.swift` | `ReaderLoader` routes PDFs to `PDFReaderView` |
| `Features/Reader/ReaderView/ReaderViewModel.swift` | `ReaderLoaderViewModel.loadBook` early return for PDFs |
| `Features/Sasayaki/SasayakiMatcher.swift` | Already guards on `epub`, so it should just work. Verify. |
| `Core/UserConfig.swift` | PDF settings |
| `Features/Settings/AdvancedView.swift` | Link to `PDFSettingsView` |
| `HoshiReader-Info.plist` | `com.adobe.pdf` document type (`Alternate`) |
| `Hoshi Reader.xcodeproj` | SPM: `onnxruntime-swift-package-manager` (app target only) |
| `README.md` | Feature bullet "PDF support with OCR (PaddleOCR)"; Libraries table: ONNX Runtime (MIT); Attribution table: PaddleOCR PP-OCRv6 models and Kellenok/PP-OCRv6_manga (Apache-2.0) |
| `.gitignore` | `*.onnx`, `Scripts/ocr/.venv/`, local model drops |
| `Localizable.xcstrings` | New strings (Xcode adds them on build) |

New files (suggested layout):
```
Models/PDFBook.swift                      PDFInfo, PDFTextSource
Models/PDFTextLayer.swift                 PDFGlyph, PDFTextLine, PDFTextLayer (+ compact Codable)
Util/BookFileType.swift                   format sniffing
Util/PDFImporter.swift                    import pipeline
Util/JapaneseText.swift                   port of selection.js constants, boundaries, sentence
Core/OCRModelStore.swift                  download, verify, locate models
Features/PDFReader/PDFReaderView.swift
Features/PDFReader/PDFReaderViewModel.swift
Features/PDFReader/PDFKitView.swift       UIViewRepresentable + Coordinator (tap, page change)
Features/PDFReader/PDFHighlightOverlay.swift
Features/PDFReader/PDFContentsSheet.swift
Features/PDFReader/TextLayer/PDFTextLayerProvider.swift
Features/PDFReader/TextLayer/EmbeddedTextExtractor.swift
Features/PDFReader/TextLayer/EmbeddedTextQuality.swift
Features/PDFReader/TextLayer/LayoutAnalyzer.swift
Features/PDFReader/TextLayer/PDFTextScanner.swift
Features/PDFReader/OCR/OCREngine.swift    protocol + OCRLine
Features/PDFReader/OCR/PageRenderer.swift
Features/PDFReader/OCR/PaddleOCREngine.swift
Features/PDFReader/OCR/DBTextDetector.swift
Features/PDFReader/OCR/CTCTextRecognizer.swift
Features/PDFReader/OCR/ImageTensor.swift
Features/Settings/PDFSettingsView.swift
Scripts/ocr/export_models.sh
Scripts/ocr/reference.py
```

---

## 12. Edge cases

| Case | Handling |
|---|---|
| Password-protected PDF | Reject at import with a localised error |
| PDF with 0 pages or a corrupt file | Reject at import |
| Huge PDF (1000+ pages, 500 MB) | Import is a file copy plus one page render. Never iterate all pages synchronously. Whole-book OCR is opt-in and cancellable. |
| Mixed PDF (some pages text, some scanned) | Per-page decision (§6) |
| Mojibake text layer | `EmbeddedTextQuality` → OCR; manual "Always use OCR for this book" |
| Invisible OCR layer from another tool (e.g. Acrobat) | Treated as embedded. Usually good. Users can force OCR. |
| Rotated pages (`/Rotate 90/180/270`) | `PageRenderer.pixelToPage` (§7.5). Must be covered by a fixture. |
| Landscape two-page scans (one PDF page = two book pages) | v1: works, because OCR tiers/columns order the text. Splitting spreads is out of scope. |
| Tap during OCR, then the user turns the page | Tap token check (§9.2) drops the stale result |
| OCR model not installed | `auto`/`always` mode + scanned page → non-blocking sheet: "This page has no text. Download OCR model (<size from manifest>)?" for the selected pack. Shown at most once per reader session. |
| User switches OCR pack | Old cached pages are re-OCR'd lazily (engine mismatch, §6). The old pack's sessions are released. Offer to delete the old pack's files. |
| Low memory or thermal pressure | On a memory warning, release the sessions (they reload on the next request). During "OCR all pages", back off while `thermalState >= .serious`. |
| Low memory warning | Release ORT sessions and the in-memory layer cache. Recreate lazily. |
| App backgrounded during whole-book OCR | Cancel the task. Progress is per page on disk, so it resumes where it stopped. |
| Furigana in scanned books | Ruby detection (§7.7). A tap on ruby maps to the base text. |
| Surrogate-pair kanji (𠮟, 𩸽) | Everything operates on grapheme clusters; `clozeOffset` counts UTF-16. Unit test it. |
| Very small text (footnotes) | May not OCR well at 2048 px. Acceptable for v1. |
| Popup position while zoomed | `rect` is computed at tap time from `pdfView.convert`. Close popups on zoom/scroll changes (observe `PDFViewScaleChanged` and the scroll view's `contentOffset`, or simply close on any page change and pinch). |

---

## 13. Licensing

- **PaddleOCR / PP-OCRv6 models and Kellenok/PP-OCRv6_manga:** Apache-2.0 (per PaddlePaddle's announcement). Confirm the license on each Hugging Face model card before publishing the release asset. Compatible with GPL-3.0 distribution. Add attribution to the README "Attribution" table and the About screen ([AboutView.swift](Features/Settings/AboutView.swift)) if it lists libraries.
- **ONNX Runtime:** MIT. Add to the README "Libraries" table.
- The models are downloaded, not bundled, but they still need attribution because the app uses them.

---

## 14. Implementation phases

Each phase ends with a green build and its acceptance criteria verified on the simulator **and** on a device for the OCR phases (performance is device-specific).

### Phase 1: Model and import
- §4.1–4.4, §5 (all of it), `FileNames` additions, `BookFileType`, `PDFImporter`, the Info.plist doc type, bookshelf touch points (§5.5).
- `ReaderLoader` routes PDFs to a **placeholder** `PDFReaderView` that shows the PDF in a bare `PDFView` with a back button.
- **Acceptance:**
  - [ ] Importing a PDF through the file picker, Files "Open in…", and `hoshi://open?url=<pdf>` creates a book with a cover and title.
  - [ ] Reimporting the same PDF is a no-op.
  - [ ] The EPUB import still works, and existing `metadata.json` files still load.
  - [ ] Sync and Match are hidden for PDFs. Export shares the PDF. Delete and rename work.

### Phase 2: PDF reader shell
- §9.1, §9.3 (without lookup), §9.4, §9.6, §10 (display settings only), page persistence (§4.4).
- **Acceptance:**
  - [ ] Paged RTL and continuous modes work. The last page persists across launches.
  - [ ] Shelf progress shows (page/total). "Mark Read" gives 100%, and reopening goes to the last page.
  - [ ] Outline jump and go-to-page work.

### Phase 3: Embedded-text tap-to-lookup
- §4.5, §7.1, §7.2, §7.7, §8 (all of it), the provider (§6) without the OCR branch, the popup wiring in §9.2 and §9.3, and the highlight overlay.
- **Acceptance:**
  - [ ] On a text PDF (horizontal **and** vertical Japanese), tapping a word opens the popup next to the word, the matched length is highlighted, and nested lookups inside the popup work.
  - [ ] Anki mining fills the sentence with the correct cloze, the document title, and the cover.
  - [ ] A tap on whitespace, a margin, or punctuation toggles focus mode or closes popups, like EPUB. A second tap on the same word closes the popup.
  - [ ] The highlight follows zoom and scroll.

### Phase 4: OCR engine (headless)
- §7.3–7.6, `OCRModelStore`, the SPM dependency, `Scripts/ocr/*`.
- A DEBUG-only developer entry point (e.g. a hidden button in `PDFSettingsView` under `#if DEBUG`) runs OCR on page N of a chosen book and logs the lines and timings.
- **Acceptance:**
  - [ ] The v6 det output format is confirmed (§7.6 "Check first"). `params.json` is extracted for every pack, and the Swift code reads it.
  - [ ] On fixtures (§15), Swift output matches `reference.py` at ≥ 95% character accuracy for **each pack**, with boxes within a few pixels.
  - [ ] A vertical tategaki scan reads in the correct order.
  - [ ] **Vertical-text gate (§7.3):** a short table in the PR description gives character accuracy on `scan_vertical.pdf` and `scan_vertical_dense.pdf` for v6 small, v6 medium and v5 mobile. The default pack is confirmed, or switched to v5 mobile, based on it.
  - [ ] **Benchmark table** in the PR description: ms per page (render / det / rec / total) and peak memory for each pack on (a) an A15/A16 iPhone and (b) an M4 iPad Pro, for CPU EP with 2 and 4 threads, plus the CoreML EP if attempted. The performance targets in §7.6 are met, or the gap is explained.
  - [ ] No main-thread work (verify with the Time Profiler or `dispatchPrecondition`).
  - [ ] Model download verifies SHA-256, the files are excluded from backup, and `.v6Medium` is hidden on devices with less than 8 GB RAM.

### Phase 5: OCR integration
- The provider's OCR branch, disk cache, prefetch, tap-token flow, the "Recognizing text…" indicator, the OCR model prompt, menu actions (re-run, force OCR, OCR all pages), `pdfOCRMode`, and the DEBUG box overlay.
- **Acceptance:**
  - [ ] On a scanned Japanese bunko PDF, tapping a word on an already-processed page opens the popup in under 100 ms. On an unprocessed page it opens after OCR finishes, and the original tap is honoured.
  - [ ] Furigana taps resolve to the base word.
  - [ ] Turning pages forward rarely shows the indicator, thanks to prefetch.
  - [ ] Cache survives an app restart, and bumping `PDFTextLayer.currentVersion` invalidates it.

### Phase 6: Polish
- Statistics (§9.5), the rest of the settings UI, the README and attribution, edge cases (§12), localisation pass, and memory-warning handling.

---

## 15. Testing

### 15.1 Fixtures (`Tests/Fixtures/pdf/`; keep them small and redistributable)

Create the PDFs yourself (e.g. export from Pages/LaTeX, or render public-domain Aozora Bunko text), so there are no licensing issues:
1. `text_horizontal.pdf`: Japanese horizontal text with embedded text.
2. `text_vertical.pdf`: tategaki with embedded text, including ruby and one surrogate-pair kanji.
3. `scan_vertical.pdf`: the same content rasterised (image only, 300 dpi), two pages.
   - `scan_vertical_dense.pdf`: a real-world-like bunko scan (about 300 dpi, slight noise and skew, ruby, 2-tier 段組 on one page). This plus `scan_vertical.pdf` is the **vertical-text gate** set (§7.3). Keep a ground-truth `.txt` for each page so accuracy can be computed automatically (`reference.py --eval`).
4. `scan_rotated.pdf`: one scanned page with `/Rotate 90`.
5. `mojibake.pdf`: a text layer with garbage mapping over a correct image (or synthesise one by placing invisible Latin junk text over an image).
6. `mixed.pdf`: page 1 text, page 2 scan.
7. `locked.pdf`: password-protected.

### 15.2 Unit tests

The repo has no app test target yet. Add a `HoshiReaderTests` unit test target in Xcode if the maintainer agrees. Otherwise, put these behind a DEBUG self-test screen. Priority order:
1. `JapaneseText`: boundaries, `sentence(in:at:)` (port the behaviour by comparing against `selection.js` outputs on the same strings, including the bracket trimming cases), and UTF-16 `clozeOffset` with surrogate pairs.
2. `PDFTextScanner`: scan stops at boundaries, crosses line wraps within a block, never crosses blocks, ruby is skipped, hit-test tolerance.
3. `LayoutAnalyzer`: tategaki right-to-left order, 2-tier 段組, ruby detection.
4. CTC decode: synthetic `[T, C]` matrices → expected text and timestep spans.
5. DB post-processing: a synthetic probability map → expected boxes after unclip.
6. `BookFileType.detect` and `BookMetadata` decoding of legacy JSON (no `pdf` key).

### 15.3 Manual QA matrix

Devices: one small iPhone (SE/mini), one Pro Max, one iPad. For each fixture, in paged RTL, paged LTR, and continuous modes: import, open, tap 10 words, mine one card, rotate the device (popups close, highlight stays correct), background and foreground, relaunch (page restored, OCR cache reused).

---

## 16. Open questions for the maintainer

1. **Model hosting:** OK to publish the ONNX model packs (v6 small, v6 medium ≈ 140 MB fp32, v5 mobile) as GitHub release assets on `Manhhao/Hoshi-Reader` (`ocr-models-v1`)? Bundling isn't recommended given the sizes.
   - **Medium quantisation:** if medium's download size is a problem, is an int8-quantised medium (≈ ¼ the size) acceptable, provided it passes the same accuracy gate against `reference.py`?
2. **Test target:** OK to add `HoshiReaderTests` to the Xcode project?
3. **Stats:** should PDF pages count toward characters read (§9.5), or only reading time?
4. **Spreads / iPad two-up:** wanted for v1?
5. **ttu sync for PDFs:** permanently out, or a future ask? ッツ Reader itself has no PDF support, so out is the recommendation.
