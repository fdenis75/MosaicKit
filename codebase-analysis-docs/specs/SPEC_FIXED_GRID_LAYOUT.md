# Spec: fixed rows × columns layout (`LayoutType.fixedGrid`)

Status: **proposed, 2026-10-15** (docs only; no code changed). Author: research session for the
maintainer. Baseline: `main@07779ce`, release 1.9.1, 1.10.0 in preparation.

How this document relates to the rest: it follows the conventions of
[CODEBASE_KNOWLEDGE.md](../CODEBASE_KNOWLEDGE.md) (cited as **KB**) and
[IMPLEMENTATION_PLAN.md](../IMPLEMENTATION_PLAN.md) (cited as **Plan**). **Source code is
authoritative**; every claim about current behavior below was checked against the files named,
at the lines named (line numbers are for `main@07779ce`). Numbers come from a throwaway script
(§4.2, not committed) and from two small experiments (§4.5, anamorphic probe).

Contents: [1 Goal](#1-goal-and-non-goals) · [2 API](#2-public-api-design) ·
[3 Algorithm](#3-algorithm) · [4 Edge cases](#4-edge-case-catalogue) ·
[5 Pipeline interactions](#5-interactions-with-the-rest-of-the-pipeline) ·
[6 Apple technologies](#6-apple-technologies) · [7 Tests and gates](#7-test-plan-and-performance-gates) ·
[8 Open questions and plan](#8-open-questions-and-phased-implementation-plan)

---

## 1. Goal and non-goals

**Goal.** Let the caller choose the number of **rows** and **columns** of a mosaic. The result is
a regular grid of `rows × columns` equally sized cells, filled with frames sampled in time order.
This is the layout people expect from a "storyboard" or "contact sheet": a 4 × 6 sheet, a
film strip (1 × 12), a poster column (8 × 1).

**The invariant that shapes everything.** `MetalImageProcessor` scales every frame to the exact
cell size and **does not preserve aspect ratio** (`scaleTexture` at
`Sources/Processing/MetalImageProcessor.swift:319`; the cell comes from `renderRect`, :1156). So
a layout must never hand a cell an aspect that differs from the source. An arbitrary
`rows × columns` on an arbitrary canvas aspect usually *would* (§4.2: only about 3 % of grids
are within 5 % of the right aspect). The design therefore has to decide what gives way: the
canvas, the frame, or the grid. It never lets the picture be deformed silently.

**Goals**
- G1. Exactly `rows × columns` cells, row-major (left to right, top to bottom) in time order.
- G2. Default behavior **cannot distort** frames and **cannot fail** for a reasonable request:
  the canvas follows the grid.
- G3. Optional modes that keep the configured `AspectRatio` canvas (letterbox, center-crop,
  bounded stretch), with a typed error and concrete suggestions when the request is impossible.
- G4. Fully backward compatible: old configs decode; existing output paths do not move
  (KB §4.1 rules 2–4).
- G5. Deterministic, pure geometry, cheap to compute (apps can call it for a live preview).
- G6. No change in throughput for the existing layouts (KB §4.3; Plan ⚡ gate).

**Non-goals**
- N1. Non-uniform grids (spans, mixed cell sizes). That is `.custom`'s job.
- N2. Choosing "interesting" frames (scene detection, quality scoring). See §6 for why not.
- N3. Per-cell user content (pinning a timestamp to a cell).
- N4. Changing the other layouts, `.dynamic`, or the shared frame-sampling policy.
- N5. Letting the width exceed the 16,384 px texture limit (the limit stays; KB §F3).
- N6. Fixing the pre-existing spacing deformation of other layouts (found in passing,
  §4.3 row S3; proposed as a separate issue).

---

## 2. Public API design

### 2.1 Why a new case plus a parameter struct

`LayoutType` is `String`-raw-valued, `Codable`, used in `configurationHash` and the `{layout}`
token (`MosaicConfiguration.swift:331`, :423, :536), and switched on in `LayoutProcessor`. Two
options:

| Option | Verdict |
|---|---|
| `case fixedGrid(rows: Int, columns: Int)` (associated values) | **Rejected.** The enum loses its `String` raw value, so rule 3 (persisted raw values) and the hash/token code break, and `allCases` stops being a list. |
| New plain case `fixedGrid` + `grid: GridSpecification?` on `LayoutConfiguration` | **Chosen.** Raw value `"fixedGrid"` is new, so nothing existing moves. The parameters live in an optional struct. |

Why optional, not a non-optional with a default (say 4 × 4): every config in the world would then
carry a meaningless `grid` key, and "layout is `.custom` but grid is 4 × 4" is a state with no
meaning. `LayoutConfiguration` has *synthesized* `Codable` (`LayoutConfiguration.swift:5`, no
custom `init(from:)`). For an `Optional` property the synthesized decoder already uses
`decodeIfPresent`, and the synthesized encoder uses `encodeIfPresent`. So **old payloads decode
unchanged and a config without a grid encodes byte-for-byte as before**. The pinned fixtures
(`*-config-*.json`) stay untouched, as KB §4.1 rule 2 requires.

### 2.2 Types

```swift
// Models/GridSpecification.swift  (new file; one primary type per file)

/// How a fixed grid reconciles the grid with the source's aspect ratio.
/// Raw values are persisted and appear in output paths: never rename (rules card #3).
public enum GridFitMode: String, Codable, Sendable, CaseIterable {
    /// Default. The canvas height follows the grid: every cell gets the source aspect.
    /// `layout.aspectRatio` is not used to shape the canvas. Frames are never distorted,
    /// cropped or letterboxed.
    case adaptCanvas
    /// The canvas keeps `layout.aspectRatio`. Frames keep their aspect ratio and are centered
    /// in their cell (bars show the background).
    case letterbox
    /// The canvas keeps `layout.aspectRatio`. Frames fill the cell; the excess of the longer
    /// side is cropped, centered.
    case crop
    /// The canvas keeps `layout.aspectRatio`. Frames are stretched, but only up to
    /// `aspectTolerance`; beyond that the request is rejected (typed error + suggestions).
    case stretch
}

public struct GridSpecification: Codable, Sendable, Hashable {
    public var rows: Int                   // 1...GridSpecification.maximumAxisCount
    public var columns: Int                // 1...GridSpecification.maximumAxisCount
    public var fit: GridFitMode            // default .adaptCanvas
    /// Largest accepted relative difference between cell aspect and source aspect before the
    /// mode must act (letterbox/crop) or refuse (stretch). Default 0.02 (2 %), range 0...0.25.
    public var aspectTolerance: Double
    /// Fixed-aspect modes only: the smallest fraction of the cell area that may be covered by
    /// the picture (letterbox) or of the picture that may survive (crop). Default 0.5.
    public var minimumFill: Double

    public static let maximumAxisCount = 50
    public static let maximumCellCount = 1000

    public init(rows: Int, columns: Int, fit: GridFitMode = .adaptCanvas,
                aspectTolerance: Double = 0.02, minimumFill: Double = 0.5)
}

public enum LayoutType: String, Codable, Sendable {
    // …existing cases untouched…
    /// A grid with a caller-chosen number of rows and columns. Requires `LayoutConfiguration.grid`.
    case fixedGrid
    // allCases gains .fixedGrid
}

public struct LayoutConfiguration: Codable, Sendable {
    // …existing members untouched…
    /// Required when `layoutType == .fixedGrid`, ignored otherwise.
    public var grid: GridSpecification?
    public init(aspectRatio: AspectRatio = .widescreen, spacing: CGFloat = 4,
                layoutType: LayoutType = .custom, visual: VisualSettings = .default,
                grid: GridSpecification? = nil)         // trailing defaulted parameter (KB §4.8)

    /// Convenience: `LayoutConfiguration.fixedGrid(rows: 4, columns: 6)`.
    public static func fixedGrid(rows: Int, columns: Int, fit: GridFitMode = .adaptCanvas,
                                 aspectRatio: AspectRatio = .widescreen,
                                 spacing: CGFloat = 4) -> LayoutConfiguration
}
```

`GridSpecification` decodes with `decodeIfPresent` for `fit`, `aspectTolerance` and
`minimumFill` (defaults above), so a later release can add keys the same way.

**Rows and columns are `Int`, not `UInt8`/`NonZero`.** `Int` matches `LayoutProcessor` (`rows`,
`cols` are `Int`), and range checking happens in `validate()` (rules card #8), which also covers
configs decoded from JSON, where no type could prevent `0` or `-3`.

**Public planning function** (pure; this is also what apps use for a live preview, §6):

```swift
extension LayoutProcessor {
    /// Computes a fixed-grid layout without touching any video. Never throws: infeasible
    /// requests come back as `.infeasible` with the reason and suggestions.
    public func planFixedGrid(
        _ grid: GridSpecification,
        sourceAspectRatio: CGFloat,          // display aspect: VideoInput.width / height
        mosaicAspectRatio: AspectRatio,
        mosaicWidth: Int,
        spacing: CGFloat = LayoutConfiguration.default.spacing,
        reservedHeight: Int = 0              // header + ColorDNA strip, see §3.4 (estimate for adaptCanvas, exact for fixed-aspect modes)
    ) -> FixedGridPlan
}

public enum FixedGridPlan: Sendable {
    case layout(MosaicLayout, effectiveWidth: Int, notes: [FixedGridNote])
    case infeasible(FixedGridIssue, suggestions: [GridSpecification])
}

/// Machine-readable, so apps can localize and so no new MosaicError case is needed (see 2.4).
public enum FixedGridIssue: Sendable, Equatable {
    case invalidCount(rows: Int, columns: Int)
    case tooManyCells(cells: Int, maximum: Int)
    case cellsTooSmall(shortSide: Int, minimum: Int)
    case aspectMismatch(cellAspect: Double, sourceAspect: Double, error: Double)
    case fillTooLow(fill: Double, minimum: Double)
    case canvasTooTall(requiredHeight: Int, maximum: Int)
    case unknownSourceAspect
}
public enum FixedGridNote: Sendable, Equatable {
    case widthReduced(from: Int, to: Int)         // canvas was trimmed or shrunk
    case stretched(error: Double)                 // within tolerance
    case letterboxed(fill: Double)
    case cropped(retained: Double)
}
```

`LayoutProcessor.calculateLayout(…)` gets the same behavior through two new defaulted
parameters (`grid: GridSpecification? = nil`, `spacing: CGFloat = 4`). For `.fixedGrid` it
delegates to `planFixedGrid` and, like today's invalid input, returns an **empty layout** when
infeasible (the signature is non-throwing; changing it would break callers). The generator does
not rely on that: `planMosaic` calls `planFixedGrid` first and throws a typed error (§2.4), so
nothing is decoded for an infeasible request.

### 2.3 Cache key, hash, paths, skip-if-exists

**`LayoutProcessor` cache.** The key (`LayoutProcessor.swift:113`) is
`"<aspect>-<videoAR>-<count>-<width>-<density>-<layout>"`. It has no spacing and no grid, and
the grid result depends on both (plus `fit`, tolerance, fill). Append
`-grid=<R>x<C>-<fit>-<tol>-<fill>-sp=<spacing>` **only for `.fixedGrid`** so existing keys are
byte-identical (checklist "touching layout" #1: the key must contain every input).

**`configurationHash`** (KB §F12; `MosaicConfiguration.swift:331`) is
`"<width>_<density>_<W-H>_<layout>"`. Two grids that differ only in `rows`/`columns` must not
share a folder or a name, and two `fit` modes give different pictures. So introduce one private
computed property `layoutToken`, used by `configurationHash` **and** both `{layout}` token maps
(:423, :536):

| `layoutType` | `layoutToken` | Example hash |
|---|---|---|
| every existing type | `rawValue` (unchanged) | `5120_M_16-9_custom` (unchanged) |
| `.fixedGrid`, `.adaptCanvas` | `fixedGrid-<R>x<C>-sp<S>` | `5120_M_16-9_fixedGrid-6x8-sp4` |
| `.fixedGrid`, other `fit` | `fixedGrid-<R>x<C>-<fit>-tol<T>-sp<S>` | `5120_M_16-9_fixedGrid-6x8-letterbox-tol2-sp4` |

`<S>` is the **effective** spacing, `max(4, spacing)` (values below 4 behave as 4, §3.1), written
without trailing zeros (`4`, `12`, `7.5`). `<T>` is `aspectTolerance` as a percentage, same
formatting (`0.02` → `tol2`, `0.035` → `tol3.5`); it is only present for the fixed-aspect
modes, because `.adaptCanvas` never reads it. The rule: **the token contains every grid
parameter that can change the pixels of a produced image** (`rows`, `columns`, `fit`,
`aspectTolerance` where it is read, and `spacing`, which sets the inset and therefore the cell
geometry). `minimumFill` is deliberately absent: it only decides whether a request is accepted
and never alters an accepted image. Without this, with `overwrite == false` a config that
differs only in spacing or tolerance would silently get the earlier file back.

Consequences, all deliberate:
- **No existing output moves** (rule 4). New layout, new paths, so no 📁 changelog line is
  needed beyond "new layout".
- Grid-specific output parameters are all in the token (above), so changing spacing, tolerance
  or fit never returns a stale file. Options shared with every layout that are not in the hash
  today (`spacing` for other layouts, `useAccurateTimestamps`, frame label settings, …) keep
  their current behavior; the README states that skip-if-exists keys on the hash only.
- `density` stays in the hash even though it no longer sets the frame count (§3.5). Changing
  density regenerates an identical image. Removing it from the hash for grids would break the
  `<width>_<density>_…` shape that tooling may parse. Recommended: keep (open question O7).
- In `.adaptCanvas` the requested `AspectRatio` does not shape the output, but is still in the
  hash. Same trade-off, same recommendation (O8). The generator's own re-snap
  (`updateAspectRatio(new:)`, `MetalMosaicGenerator.swift:349`) is for the *composition* config
  and does not feed paths (KB §F3), so it needs no change.
- Golden-string tests pin the three forms above, so the hash cannot drift unnoticed.

### 2.4 Validation and errors

Rules card #8: validation lives in `ConfigurationValidation.swift`, ideally before any decode.
Two stages, both using **existing typed errors**:

| Stage | Where | Checks | Error |
|---|---|---|---|
| Config only | `MosaicConfiguration.validate()` | `.fixedGrid` ⇒ `layout.grid != nil`. `1…50` rows and columns. `rows × columns ≤ 1000`. `aspectTolerance` finite in `0…0.25`; `minimumFill` finite in `0.1…1`. Animation (`gifMode != .disabled`) ⇒ at least 4 cells (today's minimum frame count). Column floor: `(width − (columns−1)·4) / columns ≥ 40`. Fixed-aspect modes: the slot short side `≥ 40`. | `MosaicError.invalidConfiguration(String)` |
| Config + source | `planMosaic`, after the existing duration/dimension checks (`MetalMosaicGenerator.swift:321`) and **before** `.countingThumbnails` | Source dimensions known (§4.3 row A4). `planFixedGrid` outcome. Distinct-frame check (§4.3 row T3). | `invalidConfiguration` for geometry the caller can change; `MosaicError.invalidVideo` for "this video cannot fill that many cells" |

Messages are English like every other `MosaicError` text (the package has no string catalog and
no `defaultLocalization`; adding one changes `Package.swift`). They always state the cause, the
numbers, and **one concrete way out**, for example:

> `Invalid mosaic configuration: a 5 × 5 grid in a 9:16 mosaic would squeeze 16:9 frames by 3.16×
> (cells are 0.56:1, the video is 1.78:1). Use fit .adaptCanvas, or a grid such as 18 × 6
> (1.9 % off), 21 × 7 (1.8 %) or 24 × 8 (1.8 %).`

(Those three satisfy the default 2 % tolerance at W = 5120 with the default 256 px header; with
`includeMetadata = false` the nearest are 16 × 5 (1.6 %), 19 × 6 (0.7 %), 22 × 7 (0.1 %). The
suggestion list is computed per request, not fixed.)

**No new `MosaicError` case.** `MosaicError` is a public non-frozen enum; adding a case is a
source break for clients with exhaustive `switch` (SwiftPM sources have no library evolution).
Programmatic consumers (UIs that want to localize or highlight a field) use
`planFixedGrid`'s `FixedGridIssue`, which carries the numbers. Revisit in 2.0 (O15).

**Localization.** Only the `errorDescription` strings are English, as everywhere else in the
package. `FixedGridIssue` is the localization boundary: it has no prose, only values. If the
maintainer later wants localized strings in-package, the work is package-wide
(`defaultLocalization`, an `.xcstrings` resource, `String(localized:bundle: .module)`), not
specific to this layout.

---

## 3. Algorithm

### 3.1 Inputs, constants, notation

| Symbol | Meaning | Source |
|---|---|---|
| `R`, `C` | rows, columns | `GridSpecification` |
| `W` | requested canvas width (a **maximum** for grids) | `MosaicConfiguration.width` |
| `s` | source aspect = display width ÷ height | `VideoInput.width / height` (display size since F-1) |
| `A` | mosaic aspect preset ratio | `layout.aspectRatio.ratio` |
| `g` | gutter inside the layout = **4 px** | `LayoutConfiguration.default.spacing`; the same baseline `renderRect` subtracts (`MetalImageProcessor.swift:1165`) |
| `e` | extra inset the renderer applies on top: `max(0, round(spacing) − 4)` | `renderRect` insets each cell by `e/2` per side, so the frame is `cell − e` on both axes |
| `Hmax` | `16384 − reservedHeight` | `validateTextureSize`, :303 |
| `minShort` | smallest allowed short side of a frame: **40 px** | §4.2, tables R and T |

The gutter is not the user's `spacing`. Today `spacing` is *only* an extra render-time inset
(KB §F4); the algorithms use fixed 4/5 px. The grid keeps that contract, so `spacing = 4`
(default) is a 4 px gutter, `spacing = 12` is a 12 px gutter (4 + 8 from the inset), and
`spacing < 4` behaves as 4 (`extraSpacing` is `max(0, …)`). Rounding `spacing` to an integer for
planning keeps all geometry on whole pixels; the renderer still uses the exact value (the
residual is < 1 px, listed in §4.3 row S2).

### 3.2 Mode `.adaptCanvas` (default): the canvas follows the grid

```
planAdapt(R, C, W, s, e, Hmax):
    cw = floor((W − (C−1)·g) / C)               // slot width, whole pixels
    loop:
        fw = cw − e                             // frame width inside the slot
        fh = round(fw / s)                      // round half away from zero
        ch = fh + e                             // slot height; (cw−e)/(ch−e) ≈ s
        H  = R·ch + (R−1)·g
        if H ≤ Hmax: break
        cw −= 1 (or jump by the closed-form estimate, then correct by ±1; ≤ 3 iterations)
    if min(fw, fh) < minShort: return infeasible(.cellsTooSmall)
    canvas = (C·cw + (C−1)·g) × H               // trimmed to the grid
    cell(i) for i in 0..<R·C: row = i / C, col = i % C
        position = (col·(cw+g), row·(ch+g))     // Int
        size     = (cw, ch)                     // CGSize of whole numbers
    notes: .widthReduced if canvas.width < W
```

Properties (checked by the property tests in §7):
- All `R·C` cells have the **same** integer size, so the same aspect; gutters between
  neighbors are exactly `g`; no overlap; every cell lies inside the canvas.
- The frame (cell minus `e`) has aspect `fw / round(fw/s)`, so the deformation is the rounding
  error only: at most `0.5/fh` relative. For the worst source aspect and 30 columns this is
  0.40 % at W = 5120, 1.6 % at W = 2000 and 3.6 % at W = 1000 (§4.2, table R). The `minShort`
  floor bounds it at 1.25 %.
- The canvas width is `C·cw + (C−1)·g`, which is **less than `C` px** below `W` (the floor of
  `cw` costs the fractional part, times `C`): under 0.6 % at C = 30, W = 5120. Documented as
  "width is a maximum".
- `e` is compensated: `ch = fh + e` makes the *inset* rect, the one the renderer actually
  draws, match `s`. Without this, `spacing = 20` would distort a 320 × 180 cell by 4.3 %
  (§4.3 row S3).

### 3.3 Fixed-aspect modes (`.letterbox`, `.crop`, `.stretch`)

```
planFixed(R, C, W, A, s, e, mode, tol, minFill, Hmax):
    Wc = W
    O  = headerHeight(Wc) + dnaHeight           // overlay heights, exact (see 3.4)
    Hf = round(Wc / A)                          // FINAL canvas height, keeps the aspect
    Hc = Hf − O                                 // grid area = what is left for the cells
    if Hf > 16384: Wc = floor(16384 · A); recompute O, Hf, Hc   // note .widthReduced
    if Hc < R · minShort + (R−1)·g: infeasible(.cellsTooSmall)
    cw = floor((Wc − (C−1)·g) / C);  ch = floor((Hc − (R−1)·g) / R)
    σ  = (cw − e) / (ch − e)                    // slot aspect after the render inset
    m  = max(σ/s, s/σ) − 1                      // relative mismatch
    fill = min(σ/s, s/σ)                        // picture area ÷ slot area (letterbox) or
                                                // surviving picture fraction (crop)
    if min(cw − e, ch − e) < minShort: infeasible(.cellsTooSmall)
    if m ≤ tol:           every mode stretches the frame to the slot (error ≤ tol)   // .stretched note
    elif mode == .stretch: infeasible(.aspectMismatch, suggestions)
    elif fill < minFill:   infeasible(.fillTooLow,     suggestions)
    elif mode == .letterbox:
        if σ > s: fh = ch − e; fw = round(fh · s)          // pillarbox
        else:     fw = cw − e; fh = round(fw / s)          // letterbox
        slot origin + ((cw − fw − e)/2, (ch − fh − e)/2) ; size = (fw + e, fh + e)
        // the renderer subtracts e again, so it draws exactly (fw × fh)
    elif mode == .crop:
        positions/sizes as the slot; ThumbnailProcessor crops each decoded frame to σ'
        (centered CGImage.cropping(to:)) before label/vignette; see 3.6
```

Letterbox needs **no renderer change**: the layout emits the smaller inner rectangles and the
background shows around them. Crop needs one change in `ThumbnailProcessor` (§3.6). Stretch
needs none.

`suggestions` = up to three grids `(R', C')` with `R'·C'` as close to `R·C` as possible whose
mismatch is `≤ tol` (so they work in this mode), searched over `1…maximumAxisCount` on both
axes: 2,500 cheap evaluations, no allocation beyond the result. Ties prefer the smaller cell
count difference, then fewer rows.

### 3.4 Header, ColorDNA strip, watermark: what eats height

The layout reports `mosaicSize` for the **cell area only**; the header is composited on top
(`generateMosaicStream` adds `metadataHeight`, `MetalImageProcessor.swift:887`) and the ColorDNA
strip is appended afterwards on the CPU (`OverlayProcessor.applyColorDNA`). The texture check
(`validateTextureSize(mosaicSize)`, :895) sees cells + header, **not** the strip.

So the planner receives `reservedHeight` (an **upper-bound estimate** for `.adaptCanvas`, whose
height is derived from the cells and only needs a limit check):

```
reservedHeight = headerReserve + (overlay.colorDNA.show ? colorDNA.height : 0)
headerReserve  = config.includeMetadata ? ceil(0.10 · W) + 32 : 0
```

`0.10·W + 32` is an upper bound for the header: the automatic height is about 4.5 % of `W`
for a landscape canvas (fonts are 1 % of the width; a portrait canvas raises the font, so
up to roughly 9 %), and the density-based minimum is capped for grids as below, so it cannot
exceed `W/20 × 1.0 × 2 = 0.10·W` (XXS density, portrait canvas). The final
`validateTextureSize` remains the safety net. The ColorDNA height is
added to the check for **grids** because it is a real extension of the canvas (§4.3 row S6).

**Fixed-aspect modes: the final image keeps the aspect.** The renderer puts the header and the
strip *on top of* `layout.mosaicSize`, so a grid area of `W/A` would make the final image taller
than configured (16:9, W = 5120: grid area 5120 × 2880 + 256 px header = 5120 × 3136, aspect 1.63,
not 1.78). Rule: **the target is the final canvas, and the overlays are subtracted from the grid
area**:

```
finalHeight = round(W / A)
gridHeight  = finalHeight − headerHeight − colorDNAHeight      (headerHeight = 0 if includeMetadata is false;
                                                                colorDNAHeight = 0 if the strip is off)
```

Example: 16:9, W = 5120, header 256, strip 24 → `finalHeight` 2880, `gridHeight` 2600, the
cells are laid out in 5120 × 2600, and the final image is exactly 5120 × 2880. This needs the
**exact** header height before layout. It does not depend on the cells once the grid header cap
above applies (the minimum-height rule then only sees `min(cellHeight, W/20)`), so G-3 extracts
the height computation of `createMetadataHeader` into a pure helper
`ThumbnailProcessor.metadataHeaderHeight(for:width:…)` (no behavior change) that both the
planner and the header renderer call. The `layout.aspectRatio` re-snap (`updateAspectRatio`)
then compares `layout.mosaicSize` (grid area, aspect ≈ 1.97 in the example, still nearest to
16:9) and only influences header font scaling, so it is left as is. In `.adaptCanvas` the final
aspect is whatever the grid yields, so no subtraction is needed there.

**Header minimum-height cap (grids only).** `createMetadataHeader` raises the header to
`thumbnailHeight × (0.3…1.0)`, doubled for portrait canvases (`ThumbnailProcessor.swift:686`).
That rule assumes dense layouts with small cells. With big cells it explodes: a 1 × 1 grid of
16:9 at W = 5120 has a 2,880 px cell, so the header becomes 864 px (density M or lower), 1,728
px for a portrait mosaic, and up to 2,880 px at XXS. For `.fixedGrid` the generator passes
`thumbnailHeight: min(layout.thumbnailSize.height, W/20)` (256 px at W = 5120, comparable to
the small cells `.custom` produces there). Other layouts are untouched.

### 3.5 Frame count, density and extraction

- **Frame count = `R × C`.** `calculateThumbnailCount(…, layoutType: .fixedGrid, grid:)` returns
  it, *before* the `duration < 5 → 4` early return (`LayoutProcessor.swift:500`), which would
  otherwise answer 4 for a short video. `planMosaic` rejects `< 5 s` first anyway.
- **Density does not set the count** for grids: the user's rows × columns win. Density still
  (a) appears in the hash/path and (b) scales the header minimum fraction (§3.4). It is *not* an
  error to pass one: every `MosaicConfiguration` has a density, `.default` has `.xl`. The
  README row says "ignored for the frame count". A debug log line records it.
- **Extraction.** `ThumbnailProcessor.processedFramesStream` already takes the count from
  `layout.positions.count` (:158) and the decode box from the largest cell
  (`configureGenerator`, :496). Frame `i` goes to `positions[i]`, so row-major order needs no
  new code: it is the order the layout emits.
- **Sampling policy.** The existing split is 20 % / 60 % / 20 % over 5…95 % of the duration
  (`calculateExtractionTimes`, :505; KB §4.1 rule 9), i.e. the middle third is sampled three
  times denser. For a *grid read left to right* that makes uneven time jumps, and for small
  counts it is poor: 1 frame is taken at 65 %, 2 frames at 35 % and 65 %, 4 frames at 35, 50, 65,
  80 % (the first third and the last 15 % are never shown; table in §4.3 row T1). Recommended:
  add a `uniform` policy used for grids, `t_i = d · (0.05 + 0.90 · (i + 0.5) / n)`, and keep the
  weighted one for every other layout (no behavior change, no 📁). This makes the policy a
  parameter of the shared function rather than a third copy (rule 9; Plan S-7 can still unify
  the preview copy). The same policy must feed `extractFramesForGif` so an animation shows the
  same moments as the cells. Open question O4.

### 3.6 Crop mode: decode size

`AVAssetImageGenerator.maximumSize` *fits inside* the box preserving aspect (verified in §4.5:
a 853 × 480 source with a 400 × 400 box returns 400 × 225). For `.crop` the decoded frame must
**cover** the frame rect, so the box must be

```
decodeW = fw · max(1, s/σ'),   decodeH = fh · max(1, σ'/s)        (σ' = fw/fh)
```

and the crop is the centered `fw × fh` window (scaled), done with `CGImage.cropping(to:)`. That
call returns an image that "retains a reference to the original" (`CGImage.h`, checked in the
macOS 27 SDK), so it is zero-copy; the CPU label/vignette pass (`addTimestampToImage`) then
works on the cropped image. The Metal scale kernel and `createTexture(from:)` are unchanged.

### 3.7 Order, determinism, complexity

- **Order.** Row-major: `index = row · C + col`, time ascending. ColorDNA columns, `.frameIndex`
  labels and the animation frames use the same index, so they stay chronological. Column-major
  and others are cheap (a permutation of `positions`) but not in v1 (O17).
- **Determinism.** Integer arithmetic after one `floor`/`round` per quantity, IEEE division only
  (no `pow`, `sqrt`, trigonometry), so results are identical on Apple silicon and Intel and
  across OS versions. The only inputs are the ones in the cache key. Golden tests pin positions
  for a set of configs.
- **Complexity.** Planning is O(R·C) time and memory (≤ 1000 cells); the shrink loop is ≤ 3
  iterations; the suggestion search is O(50²). Nothing needs `Task.checkCancellation()`.
  Extraction and composition are the existing O(R·C) streaming pipeline (batches of 20).

---

## 4. Edge-case catalogue

### 4.1 Reading guide

Recommended behaviors use these verbs: **Reject** (typed error with suggestion), **Adjust**
(deterministic automatic change, logged, reported in `FixedGridPlan.notes`), **Letterbox**,
**Crop**, **Follow** (canvas follows the grid: the default), **Document** (no code change).
"Err" columns are relative aspect errors `max(r, 1/r) − 1` with `r = cell aspect / source aspect`.
Pixel examples use `W = 5120`, gutter 4, no header unless said.

### 4.2 The deformation study (numbers behind the design)

**Method.** For source aspects 16:9, 4:3, 1:1, 21:9 and 9:16 (a rotated phone clip; after F-1
inspection reports display size, so a portrait clip *is* 9:16), mosaic aspects 16:9, 4:3, 1:1,
21:9, 9:16, and every grid `1…30 × 1…30` (900 grids): 5 × 5 × 900 = **22,500 combinations**.
Cell aspect `= ((W − (C−1)g)/C) / ((W/A − h − (R−1)g)/R)` with `g = 4`, `W = 5120`; `h` = header
height (0 or 4.5 % of `W`, the typical automatic header). Exact when a canvas keeps the
configured aspect and frames are stretched into cells. To first order the cell aspect is
`A · R / C`, so a grid matches only along the line **`C/R ≈ A/s`**.

**Result 1: how many combinations are acceptable** (naive fixed-aspect canvas, stretch):

| Tolerance | No header | Header 4.5 % of W |
|---|---|---|
| ≤ 2 % | **1.5 %** | 1.2 % |
| ≤ 5 % | **3.1 %** | 3.0 % |
| ≤ 10 % | **6.0 %** | 5.9 % |

For grids up to 10 × 10 (no header): 3.0 % / 3.8 % / 6.0 %. So with a fixed canvas aspect
**about 97 % of all grids deform the picture by more than 5 %**, and the deformation is
typically huge, not marginal (see the 216 % example below).

**Result 2: by source × mosaic aspect** (percentage of the 900 grids within 2 % / 5 % / 10 %,
no header):

| Source \ mosaic | 16:9 | 4:3 | 1:1 | 21:9 | 9:16 |
|---|---|---|---|---|---|
| 16:9 | 3.6 / 4.8 / 9.3 | 1.6 / 3.7 / 7.3 | 1.2 / 2.8 / 5.4 | 1.6 / 3.7 / 7.1 | 0.6 / 1.6 / 3.1 |
| 4:3 | 1.6 / 3.7 / 7.2 | 3.3 / 5.2 / 9.4 | 1.6 / 3.7 / 7.3 | 1.1 / 2.6 / 5.6 | 0.9 / 1.8 / 4.1 |
| 1:1 | 1.2 / 2.7 / 5.2 | 1.6 / 3.6 / 7.2 | 3.3 / 5.3 / 9.3 | 0.9 / 2.2 / 4.2 | 1.2 / 2.7 / 5.2 |
| 21:9 | 1.4 / 3.8 / 7.6 | 1.1 / 2.9 / 5.6 | 0.9 / 2.1 / 4.1 | 2.9 / 5.2 / 9.1 | 0.3 / 1.4 / 2.4 |
| 9:16 (rotated phone) | 0.6 / 1.9 / 3.2 | 0.9 / 2.0 / 4.1 | 1.2 / 2.8 / 5.4 | 0.2 / 1.3 / 2.4 | 3.3 / 5.2 / 9.4 |

Even when source and mosaic aspect are **equal** (the diagonal) only 3.3–3.6 % of the grids pass
at 2 %: only the near-square grids `R ≈ C`. The best case for a user is therefore a coincidence.

**Result 3: for a user-chosen grid, how many of the 25 (source, mosaic) pairs are fine?**
No header, within 2 / 5 / 10 %: 1 × 1, 2 × 2, 3 × 3, 4 × 4, 5 × 5, 10 × 10 → **5 / 5 / 5** (only
the five matched pairs on the diagonal). 6 × 8 → 3 / 3 / 3. **3 × 5 → 0 / 0 / 3. 4 × 6 → 0 / 0 /
0. 1 × 10 and 10 × 1 → 0 / 0 / 0.** The grids people ask for most (4 × 6, 3 × 5, strips) are
exactly those that never match on a fixed canvas.

**Result 4: the "impossible grid" from the brief** (16:9 video, 9:16 mosaic; no header):

| Grid | Cell aspect | Error vs 16:9 | Note |
|---|---|---|---|
| 3 × 3 | 0.56 | **216 %** | squeezed to 32 % of its width |
| 5 × 5 | 0.56 | **216 %** | same, any square grid |
| 4 × 6 | 0.375 | **375 %** | |
| 10 × 3 | 1.875 | 5.7 % | study only: needs `aspectTolerance` ≥ 0.06; not a default-tolerance suggestion |
| 16 × 5 | 1.8 | 1.6 % | |
| 19 × 6 | 1.78 | 0.6 % | |

(Errors include the 4 px gutters; the cell aspect column is the gutter-free `A·R/C`.) Within the default 2 % only 18 grids up to 50 × 50 qualify (16 × 5, 19 × 6, 22 × 7, 25 × 8, …). Only **14 of 900** grids (1.6 %) up to 30 × 30 are within 5 % for this pair; the smallest are 13 × 4 (3.1 %),
16 × 5 (1.6 %), 19 × 6 (0.6 %). Fixed-aspect mode therefore needs a good error and suggestions
(§2.4), and the default must not depend on the aspect preset. Other sets (grids within 5 %):
16:9 in 4:3: 33 grids, smallest 4 × 3; 16:9 in 21:9: 33 grids, smallest 3 × 4; 21:9 in 9:16: 13
grids, smallest 4 × 1.

**Result 5: what letterbox/crop cost** (`fill = min(r, 1/r)`; over all 22,500 combinations):
median **0.42**, 25th percentile 0.21, 10th percentile 0.10; only **13.9 %** of the
combinations keep `fill ≥ 0.8`. So on a fixed canvas, letterboxing leaves more than half of the
median cell empty, and cropping throws away more than half of the median picture. That is why
the recommended default `minimumFill` is 0.5 (reject below it) and why `.adaptCanvas` is the
default.

**Derived threshold.** `aspectTolerance` default **2 %**. Reasons: (a) it is the order of the
unavoidable rounding error (0.4 % at W = 5120 and 30 columns, at most 1.25 % at the 40 px minimum
tile, table R); (b) at 2 % a letterbox bar is ≤ 1 % per side, i.e. visual noise that costs picture
area without benefit, so the mode simply stretches; (c) 5 % and 10 % admit only 3 % and 6 % of
the combinations, so a higher default would not make the feature more usable, only the
distortion more visible. Users can raise it to 25 % for `.stretch`.

**Table R: rounding error of `.adaptCanvas`** (worst case over the five sources; whole-pixel
`cw = floor`, `fh = round`):

| Canvas W | 1 col | 5 | 10 | 20 | 30 |
|---|---|---|---|---|---|
| 1000 | 0.10 % | 0.23 % | 0.35 % | 1.47 % | 3.57 % |
| 2000 | 0.02 % | 0.17 % | 0.23 % | 0.35 % | 1.61 % |
| 3840 | 0.02 % | 0.13 % | 0.12 % | 0.53 % | 0.36 % |
| 5120 | 0.01 % | 0.04 % | 0.13 % | 0.18 % | 0.40 % |
| 10000 | 0.01 % | 0.05 % | 0.04 % | 0.20 % | 0.10 % |

**Table H: canvas height with `.adaptCanvas`** at W = 5120, header 4.5 % of W. Share of the 900
grids whose height exceeds 16,384, and the largest `R` that fits for `C = 1, 2, 3, 6`:

| Source | Grids over the limit | Max rows for C = 1 / 2 / 3 / 6 |
|---|---|---|
| 16:9 | 8 % | 5 / 11 / 16 / 33 |
| 4:3 | 11 % | 4 / 8 / 12 / 25 |
| 1:1 | 15 % | 3 / 6 / 9 / 18 |
| 21:9 | 5 % | 7 / 14 / 22 / 43 |
| 9:16 | 27 % | 1 / 3 / 5 / 10 |

A shrink to fit (width becomes a maximum) removes all of these without distortion. Example:
10 × 1 at W = 5120 fits at about 2,880 px for 16:9, 1,630 for 1:1 and 920 for 9:16 (computed with
the 4.5 % header; the planner's larger reserve gives slightly less).

**Table T: minimum tile.** `.adaptCanvas` cell width depends only on `C`. Smallest cell width
for 30 columns: W = 1000 → 29 px; 2000 → 63 px; 5120 → 167 px; 10000 → 329 px. Share of column
counts `1…30` under 64 / 96 / 128 px: W = 1000 → 53 % / 67 % / 77 %; W = 2000 → 3 % / 33 % /
50 %; W ≥ 5120 → 0 %. So the minimum-tile rule is a real constraint only for small canvases.

### 4.3 The catalogue

Columns: **case · example · what goes wrong · recommended behavior**. Case IDs are stable
handles for tests (`A` aspect, `S` spacing/geometry, `G` grid shape, `H` header/overlays, `T`
time/sampling, `P` pipeline interplay, `B` batch/other).

#### A. Aspect ratio

| ID | Case | Example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| A1 | Fixed canvas, grid not on the `C/R ≈ A/s` line | 16:9 video, 9:16 mosaic, 5 × 5 | Cells are 0.56:1; frames squeezed by 3.16× (216 % error); §4.2 | Default `.adaptCanvas` avoids it. In `.stretch`: **Reject** `aspectMismatch` + suggestions (18 × 6, 21 × 7, 24 × 8 with the default header; 16 × 5, 19 × 6, 22 × 7 without). In `.letterbox`/`.crop`: fill 0.32 < 0.5 → **Reject** `fillTooLow` + the same suggestions |
| A2 | Moderate mismatch, fixed canvas | 16:9 video, 16:9 mosaic, 3 × 4: cell aspect 1.33 (33 % error) | Visible stretch | Fill is 0.75, so letterbox/crop are allowed (fill ≥ 0.5); `.stretch` rejects with suggestions (3 × 3, 4 × 4, 2 × 2 without a header) |
| A3 | Mismatch within tolerance | 4:3 video, 16:9 mosaic, 3 × 4: cell 1.333 vs 1.333, error 0.0 % | Letterbox would add 0-px bars | Within `aspectTolerance` (2 %): **stretch**, no bars, no crop; `.stretched` note |
| A4 | Source aspect unknown or wrong | `VideoInput(url:)` swallowed inspection errors, so `width`/`height` are `nil`; `planMosaic` substitutes `1.0` (`MetalMosaicGenerator.swift:325`) | A 16:9 clip gets square cells: 78 % stretch, silently, for every layout today | For grids **Reject** `unknownSourceAspect` ("inspect the video first: `VideoInput(from:)`") rather than guess. (Alternative: load the first track's display size in `planMosaic`; O14) |
| A5 | Rotated phone video | 9:16 clip (stored 640 × 360, 90° transform) | Pre-F-1 sources were reported 16:9: cells 216 % off. Fixed in F-1 (`RotatedSourceTests`) | Rely on F-1; add a grid test on `rotated_portrait.mp4` (portrait cells). Document that `s` must be the **display** aspect |
| A6 | Non-90° or flipped transforms | 180° rotation, mirroring | None: aspect unchanged | Document; no code |
| A7 | Anamorphic / non-square pixels | 720 × 480, SAR 32:27 (displays 16:9) | Risk: cells built from stored 3:2 would be 16 % off | **Measured (§4.5): AVFoundation applies the pixel aspect ratio** to `naturalSize` (853.33 × 480) and to decoded frames (853 × 480, 1.777). The residual is rounding, 0.04 %. No code; add the probe as a test if an anamorphic fixture is ever added |
| A8 | Extreme source aspect | 32:9 (3.56) or a 1:20 clip (0.05); the processor already refuses aspects outside `0.01…100` (`LayoutProcessor.swift:103`) | 32:9 in 4 columns at W = 5120: cells 1,277 × 359, fine. 1:20 in 6 columns: one row is 17,000 px tall, so the width shrinks to about 4,800 and tiles are 790 × 15,800 | Shrink and `minShort` rules apply unchanged. Aspects outside `0.01…100` give an empty layout today; for grids they become a typed `invalidConfiguration` |
| A9 | Source aspect changes mid-stream (concatenated clips) | 16:9 then 4:3 | Some frames stretched | **Document**; aspect comes from the first video track's display size. (Per-frame fitting would need the decoded size; not in v1) |
| A10 | Baked-in black bars | 2.39:1 film in a 16:9 container | Bars waste cell area | **Document**; crop-detect is out of scope (N2) |
| A11 | Interaction with existing aspect snapping | `.adaptCanvas` 1 × 10 gives a 17.9:1 canvas | `updateAspectRatio(new: findNearest(layout.mosaicSize))` (`MetalMosaicGenerator.swift:349`) snaps to 21:9 for the composition config; only header font scaling and the portrait-header doubling use it | Acceptable: snapping already works this way for `.custom`. Keep. **Document** that for grids `layout.aspectRatio` shapes the canvas only in fixed-aspect modes |
| A12 | Portrait canvas doubles the header minimum | `layout.aspectRatio = .vertical` ⇒ `minFraction × 2` (`ThumbnailProcessor.swift:692`) | Only matters with big cells | Covered by the header cap (§3.4, H1) |
| A13 | Mixed aspect batch | 100 videos, 16:9 and 9:16, 4 × 6 `.adaptCanvas` | Output sizes differ per video (5,120 × ~1,720 vs 5,120 × ~6,100); a catalog expecting uniform sheets is surprised | **Document**; uniform sheets need a fixed-aspect mode |

#### S. Spacing, rounding and geometry

| ID | Case | Example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| S1 | Width does not divide evenly | W = 5120, C = 7: `(5120 − 24)/7 = 728.0` fits exactly; C = 9: `(5120 − 32)/9 = 565.3` | Fractional cell widths; positions are truncated `Int`, sizes fractional, texture sizes truncated by `Int(size.width)` (`scaleTexture` :331) so cells would differ by a pixel | Whole-pixel `cw = floor`; **trim the canvas** to `C·cw + (C−1)·g`. Loss `< C` px (≤ 0.6 % at 30 columns, W = 5120); `.widthReduced` note |
| S2 | Fractional `spacing` | `spacing = 7.5` | `inset = 1.75` ⇒ frame rect 3.5 px smaller, fractional; texture size truncates to 1 px off | Plan with `round(spacing)`; residual aspect error `< 1/fh` (0.3 % at fh = 300). **Document** "use whole numbers" |
| S3 | `spacing` > 4 deforms cells (pre-existing, all layouts) | 16:9 cell 320 × 180, `spacing = 20`: renderer draws 304 × 164 (aspect 1.854, +4.3 %) | The inset removes the same pixels on both axes, so aspect changes; the shipped layouts do not compensate | **Grid: compensate** (`ch = fh + e`, §3.2). Other layouts: separate issue, not here (N6). Same-order cases: spacing 10 on 640 × 360 → 0.7 %; on 160 × 90 → 3.1 % |
| S4 | `spacing` < 4 | `spacing = 0` | `extraSpacing = max(0, …)` so the gutter stays 4 | **Document**: the minimum gutter is 4 px (existing contract) |
| S5 | Huge spacing | `spacing = 400` on 100 px cells | `maxInset = (min(w,h) − 1)/2` clamps in `renderRect`, frames become 1 px | Validate: frame short side `cw − e ≥ minShort` (**Reject** `cellsTooSmall`) |
| S6 | ColorDNA strip adds height after the texture check | 12 × 1 `.adaptCanvas`, strip 24 px, canvas at 16,380 | Cells + header pass `validateTextureSize`; the CPU strip pushes the final image past 16,384 (not checked today) | Planner subtracts `colorDNA.height` via `reservedHeight` (§3.4) |
| S7 | Watermark relative to canvas | 5120 × 286 strip (1 × 10), image watermark with `scale = 0.2` | `OverlayProcessor` sizes the image from the **width** (`targetW = mosaicW × scale`, :267); 1,024 px wide may be taller than the 286 px strip | Test with a strip; clamp the watermark to the canvas height if needed (small fix in `OverlayProcessor`, same PR as G-3) |
| S8 | Odd canvas dimensions | `C·cw + (C−1)·g` odd | Some encoders want even sizes | Not required for HEIF/JPEG/PNG/WebP (existing layouts also produce odd sizes). **Document** |
| S9 | Shadow and border near gutters | gutter 4, shadow radius 4 offset −2 | Shadows overlap neighbors and clip at canvas edges | Existing behavior for all layouts; no change |

#### G. Grid shape and size

| ID | Case | Example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| G1 | `rows` or `columns` < 1 or > 50 | `0 × 4`, `-1 × 3`, `1 × 90` | Division by zero, empty layout, or unusable tiles | **Reject** `invalidConfiguration` in `validate()` (also protects decoded JSON) |
| G2 | 1 × 1 | single frame | Mosaic is one frame + header; animation has one frame | Allowed. With `gifMode != .disabled`: **Reject** (needs ≥ 4 cells, today's minimum) |
| G3 | Single row (1 × N), "film strip" | 1 × 10 16:9, W = 5120: cells 508 × 286, canvas 5120 × 286 | Header is as tall as the strip; canvas is 17.9:1 | Valid and intended. Header cap (§3.4) keeps it proportionate; snap to 21:9 for fonts (A11) |
| G4 | Single column (N × 1), "poster" | 10 × 1 16:9: cells 5120 × 2880 | Height 28,800 > 16,384 | **Adjust**: shrink the width to about 2,880 (`.widthReduced`), valid while tiles stay ≥ `minShort`. A 9:16 source shrinks to about 920 |
| G5 | Many rows × many columns | 30 × 30 = 900 cells | Time, CPU shadow pass per frame, `Set<Int>` of 900 | Allowed up to 1000 cells. Gate: benchmark (§7) |
| G6 | Cell count over the cap | 40 × 40 = 1600 | Time and memory | **Reject** `tooManyCells` (> 1000) with the cap in the message |
| G7 | Tiny tiles | W = 1000, C = 30: cw = 29 px | Unreadable, rounding error 3.6 % (table R), label wider than the tile (min label font is 15 px: `overlayFontSize` :1381) | **Reject** `cellsTooSmall` when frame short side < 40 px; suggest `maxColumns(width:)` and a larger width. A softer advisory at < 64 px is logged |
| G8 | Square source in many columns | 1:1, C = 30, W = 2000: 63 × 63 | Same | As G7 |
| G9 | Grid larger than the 16,384 px *width* | `width` ≤ 16,384 is validated at generation | Already rejected | Unchanged |
| G10 | Tall single column of portrait video | 9:16, 2 × 1, W = 5120: 5,120 × 9,102 per cell | 18,204 > 16,384 | **Adjust**: shrink to about 4,480 px wide (`2·fh + gutter ≤ Hmax − reserve`, with the 10 % header reserve); `.widthReduced` |
| G11 | Grid asked in `.iphone`-style | "1 column, 8 rows, 1200 wide" | `.iphone` is fixed 1200 px / 8000 px high (`LayoutProcessor.swift:539`) | `fixedGrid` with `columns: 1` and `width: 1200` gives the same shape with user-chosen rows. **Document** as the migration path |

#### H. Header, overlays, labels

| ID | Case | Example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| H1 | Header minimum height from big cells | 1 × 1, 16:9, W = 5120, density M: header ≥ 0.3 × 2,880 = 864 px; portrait ×2 = 1,728; XXS 2,880 | Header larger than useful, can push past 16,384 | Cap `thumbnailHeight` passed for grids to `W/20` (§3.4) |
| H2 | Header hidden | `includeMetadata = false` | none | `headerReserve = 0` |
| H3 | Header too wide for text | C = 1 narrow canvas (917 px after shrink) | Header text shrinks (existing fitting) | Existing behavior |
| H4 | ColorDNA | R·C columns across canvas | 900 columns over 5,120 px = 5.7 px each: fine; 1 × 1: a single color bar | Allowed. Index order = time order (row-major) |
| H5 | Frame labels on tiny tiles | 40 px tile, label min font 15 px (×1.5 factor already in size) | Label covers a large part of the tile | Advisory log below 64 px; consider auto-hiding labels under 64 px in a later change (O18) |
| H6 | Label position vs letterbox | letterboxed frame in a bigger slot | Labels anchor to the frame, not the slot | Labels are drawn into the frame image (`addTimestampToImage`), so they follow the frame. OK |

#### T. Time, sampling, short videos

| ID | Case | Example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| T1 | Weighted sampling at tiny counts | 1 cell → t = 65 %; 2 → 35/65 %; 4 → 35/50/65/80 % (count `n`: `first = ⌊0.2n⌋`, `mid = ⌊0.6n⌋`) | A poster frame at 65 %; the start and end of the video never appear | `uniform` policy for grids: cell-centered, 5…95 % (§3.5) |
| T2 | Video shorter than 5 s | 3 s clip | Pipeline rejects (`MosaicError.invalidVideo("video too short")`, :322) | Unchanged; the check precedes grid planning |
| T3 | Fewer distinct frames than cells | 5 s at 24 fps = 120 frames, 30 × 30 = 900 cells; or 5 s at 1 fps | Duplicates by construction | **Reject** `invalidVideo` when `cells > floor(0.9 · duration · fps)`: "this video has about 108 distinct frames, the grid needs 900" |
| T4 | Many cells, fast mode | 60 s, 900 cells = one every 0.06 s, `useAccurateTimestamps = false` (1 s tolerance, `configureGenerator` :491) | The generator snaps neighbors to the same keyframe: visible duplicates | Log a warning when spacing `< 0.5 s` and the mode is not accurate; recommend `useAccurateTimestamps`. (Auto-switching changes speed; O16) |
| T5 | Static or black video | all frames equal | Grid of one picture | Not an error |
| T6 | Variable frame rate, missing `frameRate` | `VideoInput.frameRate == nil` | T3 cannot be evaluated | Skip T3 when fps unknown (log) |
| T7 | Cancellation | user cancels during a 900-cell run | none new | Existing tracked task + `Task.checkCancellation` in the extraction loop; planning is synchronous and < 1 ms |

#### P. Interplay with the rest of the pipeline

| ID | Case | Example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| P1 | `forIphone: true` | `generate(for:config:forIphone: true)` overrides the layout to `.iphone` in **three** places (`MetalMosaicGenerator.swift:147`, :150, :326) | The user's grid is silently ignored | **`fixedGrid` wins** over the `forIphone` layout override (an explicit rows × columns request is more specific); `forIphone` still selects its header font/colors. One helper `effectiveLayoutType(config:forIphone:)` replaces the three expressions. Log at info. (O6) |
| P2 | Backfill path derives the layout separately | `.withMosaic`, mosaic exists, animation missing (:139–153) | That block calls `calculateLayout` without grid/spacing, so it would compute a *different* layout | Route both through one `makeLayout(…)` used by `planMosaic` and the backfill |
| P3 | Animated export | 6 × 8 grid + `gifMode = .withMosaic` | Animation uses `layout.thumbCount` frames at `gifSize`, not cell size: 48 frames at 10 fps = 4.8 s | Works unchanged: no cell geometry involved, so no distortion. Frame count = cells. `.gifOnly` skips composition but still plans the layout. **Reject** < 4 cells. Large grids hit I-20 (`.nochange` holds all frames): 900 RGBA frames at 1080p ≈ 7.5 GB. Recommend limiting animated grids to ≤ 200 cells (O12) |
| P4 | `.gifOnly` with grid | animation only | Layout is computed only for the count | Same validation; canvas geometry unused |
| P5 | `generateMosaicImage` | in-memory path | Same `planMosaic` | Covered by `MosaicCompositionPathTests`-style test |
| P6 | `useMovieColorsForBg` | gradient from first 5 frames | Bars/gutters show the gradient | Fine; letterbox bars use the same background |
| P7 | Skip-if-exists | `overwrite = false`, same grid | Name contains grid ⇒ correct skip; a different grid ⇒ no stale hit | Tested via hash golden tests (§7) |
| P8 | Library downgrade | config with `"fixedGrid"` read by 1.9.x | Unknown raw value ⇒ decode error in the old library | Accepted (forward compatibility is not promised). Not softened with a silent fallback to `.custom`: wrong layout in a wrong folder would be worse than an error |
| P9 | `density` also chosen | density `.xxl` + 6 × 8 | Surprise that density does nothing | Grid wins; density only affects the hash and the header minimum. README row says so (§3.5, O7) |

#### B. Performance, memory and the size limit

| ID | Case | Example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| B1 | Canvas at the 16,384 limit | 16,384 × 16,384 RGBA8 = **1.0 GiB** texture, plus a same-size `CGImage` copy and the encoder | Memory spikes, worse on iOS | Limit unchanged. Planner honors `Hmax`. Advisory in README: wide canvases with many rows are memory heavy. Existing layouts already reach 16,384 × N |
| B2 | Extraction time | time ∝ cells (AVAssetImageGenerator is the cost; batches of 20 on the GPU) | 900 cells is about 8× the frame count of a typical `.m` mosaic (107 frames, 5120 px, 1 h video); time not yet measured | Benchmark scenario `mosaic-grid-6x10` and `mosaic-grid-20x20` recorded (§7). Not a pass/fail for the grid itself; the gate is "no regression on existing scenarios" |
| B3 | CPU shadow path | default `addShadow = true` renders each frame on the CPU (KB §F5), 8 in parallel | 900 CPU passes dominate | **Document** "turn off shadows for grids above ~200 cells" |
| B4 | Concurrent batches | coordinator limit × big grids | Peak RSS (already 1.3–3.5 GB in the Plan §8.1 baselines) | No change; B1/B3 advice |
| B5 | Non-deterministic frames | Vision-driven crop (if added) | Not byte-reproducible across OS versions | Only in the optional saliency phase (G-7); default is deterministic |

### 4.4 What the table decides (summary)

1. **Default `.adaptCanvas` never fails for a reasonable grid and never deforms.** It shrinks
   the width instead of the picture (a documented "width is a maximum").
2. **Fixed-aspect modes are opt-in** and honest: tolerance 2 %, fill ≥ 0.5, typed error with
   suggestions (A1, A2).
3. **Resource limits are hard, explained errors** (G1, G6, G7, T3), not silent clamps.
4. **Four existing quirks are routed around for grids only** and recorded as follow-up issues:
   spacing inset deformation (S3), header minimum explosion (H1), `forIphone` override (P1),
   unknown dimensions defaulting to square (A4).

### 4.5 Experiment: anamorphic probe

`ffmpeg -f lavfi -i testsrc=size=720x480 … -vf setsar=32/27` (H.264, MP4; stored 720 × 480, 3:2,
displays 16:9). A throwaway Swift script (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`)
loaded the video track and generated a frame:

| Query | Result |
|---|---|
| `AVAssetTrack.naturalSize` | 853.33 × 480 (pixel aspect ratio applied) |
| `AVAssetImageGenerator` frame, no limit | 853 × 480 (1.777) |
| same, `maximumSize = 400 × 400` | 400 × 225 (aspect-preserving fit) |

Conclusion: stored-vs-display aspect is not a risk for grids (A7); `maximumSize` fits, it does
not fill, which is why crop needs the larger decode box (§3.6).

---

## 5. Interactions with the rest of the pipeline

Following KB §3.14 (cross-feature matrix) and the "touching layout" checklist (KB §4.8):

| Stage / feature | Interaction | Change |
|---|---|---|
| **F4 Layout engine** (`LayoutProcessor`) | New case, `planFixedGrid`, cache key, `calculateThumbnailCount` branch | yes |
| **F3 Generation** (`planMosaic`, backfill, `generate`) | Pre-decode planning with typed errors; one `effectiveLayoutType` and one `makeLayout` helper; `forIphone` precedence; pass `reservedHeight`, grid, spacing | yes |
| **F2 Inspection** | Needs trustworthy display dimensions (relies on F-1). No change | none |
| **Frame extraction** (`ThumbnailProcessor`) | `uniform` sampling policy; crop mode decode box and cropping | yes (⚡) |
| **F5 Overlays** | Header minimum cap for grids; ColorDNA height in the limit; watermark clamp on strips | small |
| **F6 Animated export** | Frame count = cells, minimum 4, same sampling policy | small |
| **F7 WebP** | none | none |
| **F12 Paths / skip-if-exists** | `layoutToken` in the hash and `{layout}`; golden tests | yes |
| **F13 Validation** | Rules in §2.4 | yes |
| **F10 Coordinator / F11 jobs** | none (per-video planning; errors surface as ordinary failed results) | none |
| **Metal** (`MetalImageProcessor`) | none: letterbox emits smaller rects; crop is done before the texture upload | none |
| **Previews (F8/F9)** | none | none |

**Knowledge-base and docs to update when this is implemented** (same PR as each phase, per
CLAUDE.md "keep the doc current"; the exact rows are listed in each Plan row of §8):
- KB **Executive summary** (one line), **§1.6/§1.8** (public entry points), **§2.3** (stage
  table: layout stage and planMosaic order), **Part 3 F3** (planMosaic, `forIphone`), **F4**
  (layout table row, cache key, edge cases, tests), **F5** (header cap, strip, watermark), **F6**
  (grid frame count, sampling), **F12** (hash/token table, §5.7), **F13** (validation list),
  **§3.14** (matrix: F3/F6 → F4 rows unchanged, note the new `LayoutType` dependency), **§4.1**
  (rule 9: sampling policy is now a parameter), **§4.2** (new issue rows, below), **§4.3**
  (budgets: cell cap), **§4.5** (constants: 4 px gutter, 40 px, 50/1000, 0.02, 0.5, W/20),
  **§4.8** (layout checklist: add "include the layout token in the hash"), **§5.2/§5.3/§5.5/§5.6/§5.7**
  (API, schema, errors, cookbook, naming), **§6.1** roadmap, and the `model-schema.mmd` diagram.
- `IMPLEMENTATION_PLAN.md`: rows G-1…G-7 in §8 tracking, decisions in the §9 log.
- `CLAUDE.md` **and** `AGENTS.md` (mirrored): `LayoutType` list, key-types table.
- `README.md` (layout table, "Unreleased"), DocC `LayoutAlgorithms.md`, `QuickStart.md`,
  `Examples/` (a SwiftUI preview snippet, §6).
- Proposed new issue-register rows (IDs assigned by the maintainer at implementation time, next
  free `I-n`): **spacing > 4 deforms cells in every layout** (S3; fix: compensate in each layout
  or inset the frame by aspect); **header minimum height scales with cell height** (H1);
  **`forIphone` overrides the layout in three places** (P1, consolidated by the helper);
  **unknown dimensions default to a square aspect** (A4).

---

## 6. Apple technologies

Availability checked against the Xcode 27.0 / macOS 27.0 SDK on this machine (headers and
`.swiftinterface` files; the `AdditionalDocumentation` guides contain nothing on layout, image
cropping or Vision, only Swift 6.2 `InlineArray`/`Span`, SwiftUI Liquid Glass etc.). The
package targets 26, so anything newer needs `#available`.

| Technology | Verdict | Cost | Reason / verification |
|---|---|---|---|
| **Core Graphics** (`CGImage.cropping(to:)`, `CGContext`) | **Use** | ~0 (zero-copy crop) | Crop mode (§3.6). `CGImage.h` (SDK 27): the cropped image "retains a reference to the original". Label/vignette code already draws with `CGContext` |
| **Metal compute** (existing `scale` kernel) | **Use as is**; extend later: **maybe** | none now | Letterbox needs no kernel change (smaller rects). A source-rect parameter in the scale kernel would move the crop to the GPU, but the CPU crop is free and keeps `Shaders/` untouched. Revisit only if a ⚡ run shows the crop upload matters |
| **Accelerate / vDSP / vImage** | **Skip** | n/a | The study is 22,500 evaluations of ~6 flops (the Python script ran all of it, including output, in 0.13 s); a live preview recomputes 900 grids in well under a millisecond in plain Swift. vDSP's setup cost exceeds the work. vImage scaling is redundant with Metal |
| **Vision** (`VNGenerateAttentionBasedSaliencyImageRequest`, macOS 10.15 / iOS 13; face rectangles; new Swift `CalculateImageAestheticsScoresRequest`, macOS 15 / iOS 18 per the SDK interface) | **Maybe**, opt-in, last phase | A request per frame × up to 1000 frames; unmeasured | Only meaningful with `.crop`: shift the crop window toward the salient region instead of the center. Costs per-frame inference, makes output depend on the OS model (non-reproducible across versions, B5), and `ThumbnailProcessor` already imports Vision. Aesthetic scoring to *pick* frames is out of scope (N2) and multiplies extraction. Measure before promising |
| **Core Image** (`CIImage.cropped`, `CILanczosScaleTransform`) | **Skip** | adds a second image path | The pipeline is CGImage → Metal. Core Image would only duplicate crop/scale. Lanczos quality is a separate topic (the bilinear kernel at large reduction) |
| **AVFoundation** (`AVAssetImageGenerator` times, tolerances, `maximumSize`; `AVAssetTrack.nominalFrameRate`, `timeRange`) | **Use** (already) | none | Sampling is `images(for:)` with per-frame results; PAR handled (§4.5). `AVSampleCursor` could count sync samples for an exact "distinct keyframes" estimate (T3/T4): **maybe**, later, only if the cheap rule produces user complaints |
| **SwiftUI `Grid` / `GridRow` / `Layout`** (macOS 13 / iOS 16; `Layout` lives in `SwiftUICore` since 18) | **Use in client apps**, not in the package | n/a | `Grid` distributes space its own way and would not match the pixel-exact rectangles. Recommended live preview: call `planFixedGrid` and draw its cells in a `Canvas` (or a custom `Layout` whose `placeSubviews` reads the plan), so the preview equals the output. The package stays UI-free (no SwiftUI import in `Sources/`). Put a short snippet in `Examples/` |
| **Swift Testing** parameterized tests (`@Test(arguments:)`) | **Use** | none | The property sweep (§7) is naturally parameterized and runs in milliseconds |
| **Swift Algorithms** | **Skip** | new dependency | Rule: no dependency without clear justification (CLAUDE.md). `stride`, nested loops and a sort cover everything |
| **Swift 6.2 `InlineArray` / `Span`** | **Skip** | n/a | Arrays of ≤ 1000 small structs, planned once per video. No hot loop |
| **MetalPerformanceShaders** (`MPSImageLanczosScale`) | **Skip** for this feature | n/a | Would improve all downscaling, not grids; separate performance experiment (Plan wave 5) |
| **`os_signpost` / `OSSignposter`** | **Use** | negligible | One interval around `planFixedGrid`, matching the other layout functions; no `emitEvent` spam (Plan S-7) |
| **Localization** (`String(localized:)`, String Catalogs) | **Skip for now** | `Package.swift` change | §2.4: structured `FixedGridIssue` is the localization seam |

---

## 7. Test plan and performance gates

### 7.1 Unit and property tests (`Tests/MosaicKitTests/FixedGridLayoutTests.swift`)

All pure geometry, no media, no GPU: they add well under a second to the iOS job (the CI budget
in CLAUDE.md is ~40 s macOS / ~3 min iOS tests; nothing here touches the 80 %-of-iOS-time
animated suite). Use `@Test(arguments:)`.

| # | Property / case | How |
|---|---|---|
| 1 | **Count (feasible grids only)**: `thumbCount == positions.count == thumbnailSizes.count == R·C` | sweep `R, C ∈ {1,2,3,4,5,7,10,16,30,50}`, 5 source aspects, widths {1000, 2000, 5120, 10000}, spacing {4, 6, 12, 20}, **filtered by a reference predicate** (`R·C ≤ 1000` and frame short side ≥ 40) so e.g. 50 × 50 and 50 columns at width 1000 are excluded here |
| 1b | **Excluded combinations are infeasible with the intended issue** | the complement of the sweep in 1 must return `.infeasible`: `R·C > 1000` → `.tooManyCells`; frame short side < 40 → `.cellsTooSmall`; `R` or `C` outside 1…50 → `.invalidCount`. Asserts the issue case and its numbers, and that no layout is produced (e.g. 50 × 50 → `tooManyCells(2500, 1000)`; 1 × 50 at W = 1000 → `cellsTooSmall`, cells 16 px wide) |
| 2 | **No overlap** | cells are regular: check neighbors in row and column directions, plus a full pairwise check for a sampled subset (n ≤ 200) |
| 3 | **Inside the canvas**: `x + w ≤ canvas.w`, `y + h ≤ canvas.h`, `x, y ≥ 0` | same sweep |
| 4 | **Exact gutters**: horizontal and vertical neighbor distance equals 4 | same sweep |
| 5 | **Bounded aspect error** (`.adaptCanvas`): inset frame `(w − e)/(h − e)` within `0.5/(h−e) + 1e-9` of `s` (≤ 1.25 % once `minShort` holds) | sweep; proves the `e` compensation |
| 6 | **Width is a maximum**: `canvas.w ≤ W`, `W − canvas.w < C` unless shrunk; `canvas.h ≤ 16384 − reserved`; in fixed-aspect modes `canvas.h + header + strip == round(canvas.w / A)` (final aspect kept) | feasible sweep incl. G4, G10 |
| 7 | **Determinism**: two calls, and a third on a fresh `LayoutProcessor`, return equal values; **golden positions** for 6 configs pinned as literals | |
| 8 | **Row-major order**: `positions[i]` has non-decreasing `y`, and within a row increasing `x`; index `i` ↔ `(i/C, i%C)` | |
| 9 | **Cache**: two grids differing only in `R`, `C`, `fit`, tolerance, fill or spacing do not share an entry; existing keys unchanged (golden string) | |
| 10 | **Fixed-aspect modes**: letterbox frames keep `s` within 1 px; fill = predicted; crop `retained` = predicted; stretch within `tol` or rejected; suggestions all satisfy `m ≤ tol` and appear in order | table-driven from §4.2 (16:9 in 9:16, 5 × 5 → `.fillTooLow`; with the header off the suggestions are exactly the grids within 2 % nearest to 25 cells: 16 × 5, 19 × 6, 22 × 7; the test recomputes each one and asserts `m ≤ tol`) |
| 11 | **Validation table**: each G/T/S row gives the stated error text fragment | |
| 12 | **Codable**: round trip; old pinned payloads (`mosaic-config-1.0.0/1.3.2/1.7.0/legacy-minimal.json`) decode and **re-encode without a `grid` key**; a payload without `fit`/`aspectTolerance`/`minimumFill` decodes with defaults | never edit the pinned fixtures |
| 13 | **Hash/paths**: the golden forms (§2.3); changing only `spacing` (4 → 12), only `aspectTolerance` (in a fixed-aspect mode) or only `fit` changes the hash and path, while changing only `aspectTolerance` or `minimumFill` under `.adaptCanvas` / only `minimumFill` does not; existing layouts' hashes byte-identical; `{layout}` token; animation file name; skip-if-exists with `overwrite == false` does not return a file made with different spacing | extends `MosaicConfigurationTests` |
| 14 | **`calculateThumbnailCount`** returns `R·C` for a 3 s duration | covers the early-return trap |

### 7.2 Integration tests (embedded media, kept small)

- `test_video.mp4` (87 s), 3 × 4, `.adaptCanvas`, width 1200: image size equals the plan, no
  throw. ~1–2 s.
- `rotated_portrait.mp4` (8 s, 360 × 640), 2 × 3, `.adaptCanvas`: cells are portrait
  (extends the F-1 test pattern).
- The same clip, 2 × 3 `.letterbox` in a 16:9 canvas: frames are pillarboxed (assert the
  planned inner rects, not pixels).
- `forIphone: true` with a grid keeps the grid (P1). `generate` backfill path computes the same
  layout as `planMosaic` (P2).
- A too-few-frames case: `rotated_portrait.mp4` (8 s at 30 fps, so `⌊0.9·8·30⌋ = 216` distinct
  frames) with 30 × 30 = 900 cells rejects with `invalidVideo` before any decode (T3) and
  without creating a file.
- No new media fixtures are needed (so no iOS 10-bit pitfall, I-22). All new tests compile on
  iOS (no macOS-only APIs).

### 7.3 Performance gates

| Change | Gate |
|---|---|
| G-1 model + validation + hash | CI only (no pipeline change) |
| G-2 layout + `planMosaic` wiring | **⚡ A/B/A** on the existing P-1 scenarios (`mosaic-5120-M`, `mosaic-10000-XS`; ±5 % noise band, Plan §8.1) to prove existing layouts are unaffected, because `planMosaic`, the backfill and `calculateLayout` are touched |
| G-3 uniform sampling, header cap, ColorDNA/watermark | **⚡** (touches `ThumbnailProcessor`) |
| G-4 letterbox, stretch, suggestions | CI only |
| G-5 crop | **⚡** (touches the per-frame CPU stage) plus a crop scenario |
| G-7 saliency | **⚡** and a per-frame cost measurement before merge |

New opt-in benchmark scenarios in `BenchmarkTests` (recorded, not gated): `mosaic-grid-6x10`
(60 cells, 5120 px, shadows on) and `mosaic-grid-20x20` (400 cells, 10000 px, shadows off),
reporting wall time, source-seconds/s and peak RSS with the same A/B/A discipline. Expected
shape: time grows with the number of cells because extraction dominates (KB §4.3); the numbers
become the basis for the cell cap (O3) and the animated-grid cap (O12).

---

## 8. Open questions and phased implementation plan

### 8.1 Open questions for the maintainer

Each has a recommendation. **Decisions (maintainer, PR #66 review, 2026-10-15):** silence on a
question means the recommendation is accepted; all are accepted except O5, which is pending
clarification (his comment there was "see q3").

| # | Question | Recommendation | Decision |
|---|---|---|---|
| O1 | Default fit mode | **`.adaptCanvas`**: only 3 % of grids work on a fixed canvas (§4.2) | agreed 2026-10-15 |
| O2 | Raw value / case name | `fixedGrid` (descriptive, cannot be confused with `classic`, which is also a grid) | agreed 2026-10-15 |
| O3 | Limits | 50 per axis, 1000 cells, 40 px frame short side. Re-tune after the first benchmark runs | agreed 2026-10-15 |
| O4 | Sampling for grids | **Uniform, cell-centered over 5…95 %** as a parameter of the shared function; other layouts keep 20/60/20 | agreed 2026-10-15 |
| O5 | Width semantics | "Width is a maximum"; canvas trimmed to the grid (loses < C px) and shrunk to fit 16,384 | **pending maintainer clarification** |
| O6 | `forIphone` vs grid | Grid wins; `forIphone` keeps header styling | agreed 2026-10-15 |
| O7 | Density with grids | Ignored for the count, kept in the hash; documented. (Alternative: reject non-default density: too hostile, every config has one) | agreed 2026-10-15 |
| O8 | Requested aspect in the hash for `.adaptCanvas` | Keep (simplicity, stable shape). Cost: switching only the aspect preset regenerates an identical image | agreed 2026-10-15 |
| O9 | Ship `.stretch` in the first release? | No: ship `.adaptCanvas` first (G-2), then `.letterbox` + `.stretch` (G-4), then `.crop` (G-5) | agreed 2026-10-15 |
| O10 | Crop target | Center crop first; saliency later and opt-in | agreed 2026-10-15 |
| O11 | Header cap constant | `W/20` for grids only. Fixing the rule for all layouts is a separate, output-changing issue (📁) | agreed 2026-10-15 |
| O12 | Animated grids | Minimum 4 cells; recommend ≤ 200 cells until I-20 (streaming) lands; soft limit in docs, hard limit later if needed | agreed 2026-10-15 |
| O13 | Release | Additive public API ⇒ **minor**: 1.11.0 after 1.10.0 (F-4/F-5 stay postponed; G-1…G-3 would be the headline) | agreed 2026-10-15 |
| O14 | Unknown source dimensions | Reject for grids now; load the first video track's display size in `planMosaic` as a later fix for all layouts (A4) | agreed 2026-10-15 |
| O15 | Typed errors | Reuse `invalidConfiguration`/`invalidVideo`; a `MosaicError.gridInfeasible(FixedGridIssue)` case can come with 2.0 | agreed 2026-10-15 |
| O16 | Fast-mode duplicates (T4) | Log only; do not silently switch to accurate timestamps (slower) | agreed 2026-10-15 |
| O17 | Column-major / other orders | Not in v1; `GridSpecification` can gain `order` later with `decodeIfPresent` | agreed 2026-10-15 |
| O18 | Auto-hide labels on tiny tiles | Out of scope; advisory log only | agreed 2026-10-15 |

Decision log (style of `IMPLEMENTATION_PLAN.md` §9; all two-way until code ships):

| # | Date | Context | Decision | Type | Rationale |
|---|---|---|---|---|---|
| A-G1 | 2026-10-15 | O1, O2, O9 | `.adaptCanvas` is the default; case name `fixedGrid`; fixed-aspect modes ship after it (G-4, G-5) | Two-way (spec only) | 97 % of grids deform on a fixed canvas (§4.2) |
| A-G2 | 2026-10-15 | O3, O12 | Limits 50 per axis, 1000 cells, 40 px frame short side; animated grids need ≥ 4 cells and are advised ≤ 200 | Two-way | Re-tune after the first benchmark runs |
| A-G3 | 2026-10-15 | O4 | Grids use uniform, cell-centered sampling over 5…95 %; other layouts keep 20/60/20 | Two-way | Left-to-right reading needs even time steps |
| A-G4 | 2026-10-15 | O6, O7, O8 | The grid wins over `forIphone`; density is ignored for the count but stays in the hash; the requested aspect stays in the hash | Two-way | Stable hash shape; explicit request is more specific |
| A-G5 | 2026-10-15 | O10, O11, O17, O18 | Center crop first, saliency later; header cap `W/20` for grids only; no other frame orders; no label auto-hiding | Two-way | Keeps v1 small |
| A-G6 | 2026-10-15 | O13–O16 | Minor release (1.11.0) after 1.10.0; reject unknown source dimensions; reuse existing typed errors; log fast-mode duplicates | Two-way | Additive API; no new `MosaicError` case before 2.0 |
| A-G7 | 2026-10-15 | O5 | **Pending maintainer clarification** ("width is a maximum" vs another reading of his "see q3"); the spec text is unchanged | n/a | Awaiting answer |

### 8.2 Phased implementation plan

Style of `IMPLEMENTATION_PLAN.md` (one PR per row, KB updated in the same PR, `doc_check.py`
green, CI on both platforms). IDs are `G-n` ("grid"). ⚡ = benchmark A/B/A. No 📁 row: the layout
is new, so no existing output moves.

| ID | PR | Contents | Gate | Size |
|---|---|---|---|---|
| G-0 | **Decisions** | Maintainer answers O1–O18 (or accepts the recommendations); this spec is merged | none | docs |
| G-1 | **Model, validation, hash** | `GridFitMode`, `GridSpecification`, `LayoutType.fixedGrid`, `LayoutConfiguration.grid` (+ `fixedGrid(rows:columns:)`), `validate()` rules, `layoutToken` in `configurationHash` and both `{layout}` maps. **The new case is handled explicitly everywhere, with no fall-through:** `LayoutProcessor.calculateLayout` gets its own `case .fixedGrid` (returns the empty layout, never the `default` branch that would lay it out as `.custom`), and `MosaicConfiguration.validate()` throws `invalidConfiguration("fixedGrid layout is not available in this build yet")` after the other checks, so every entry point (`generate`, `generateMosaicImage`, coordinators) fails before any decode. G-2 deletes that throw. Tests: Codable, legacy fixtures re-encode unchanged, hash goldens (incl. spacing/tolerance/fit), validation table, and "`.fixedGrid` never produces a `.custom` layout". KB F13/F12/§5.2/§5.3/§5.5/§5.7 | CI | ~250 lines |
| G-2 | **`.adaptCanvas` layout** ⚡ | `LayoutProcessor.planFixedGrid` (adapt mode), `calculateLayout` case + cache-key suffix, `calculateThumbnailCount` branch, `effectiveLayoutType` + `makeLayout` helpers (P1, P2), pre-decode planning errors, `reservedHeight`, `FixedGridPlan`/`Issue`/`Note`, removal of the G-1 "not available" throw. Property tests 1, 1b, 2–9, 12, 14; integration tests with `test_video.mp4` and `rotated_portrait.mp4`. KB F3/F4/§2.3/§3.14/§4.5 | CI + ⚡ (existing scenarios unchanged) | ~400 lines |
| G-3 | **Sampling, header cap, overlays** ⚡ | `uniform` sampling policy (mosaic and animation), grid header cap `W/20` and the pure `metadataHeaderHeight` helper (needed by G-4), ColorDNA in the height limit, watermark clamp, T3 distinct-frame check, animation ≥ 4 cells, T4 log. Tests 11 (T/H rows), strip watermark. KB F5/F6/§4.1 rule 9 | CI + ⚡; benchmark `mosaic-grid-6x10` recorded | ~250 lines |
| G-4 | **Fixed-aspect modes without cropping** | `.letterbox` and `.stretch`, `aspectTolerance`, `minimumFill`, final-canvas aspect rule (§3.4: overlay heights subtracted from the grid area), suggestion search, error text with suggestions, `FixedGridPlan` notes. Property tests 6 (fixed-aspect clause) and 10 | CI | ~300 lines |
| G-5 | **`.crop` mode** ⚡ | Larger decode box and `CGImage.cropping` in `processedFramesStream`; tests with the rotated fixture; benchmark crop scenario | CI + ⚡ | ~150 lines |
| G-6 | **Docs and examples** | README layout table + "Unreleased", DocC `LayoutAlgorithms.md`/`QuickStart.md`, `Examples/` SwiftUI `Canvas` preview using `planFixedGrid`, CLAUDE.md/AGENTS.md mirror, KB §1.6/§1.8/§5.6/§6.1, `model-schema.mmd`. (Smaller doc edits already land with G-1…G-5 per the plan rule.) | CI | docs |
| G-7 | *(optional)* **Saliency-aware crop** ⚡ | Vision attention saliency shifts the crop window; opt-in `GridFitMode.cropSmart` or a flag; per-frame cost measured first | CI + ⚡ + measurement | ~200 lines |
| X-1 | *(separate issues, not part of G)* | Spacing inset deformation in other layouts (S3); header minimum scaling (H1); unknown dimensions (A4) | per issue | |

**Dependencies.** G-1 → G-2 → G-3; G-4 needs G-3 (header-height helper); G-5 needs G-4; G-6 closes the series. G-2 and
G-3 are the minimum useful release (`.adaptCanvas`, correct sampling, safe overlays).

**Risk summary.** Highest: P2/P1 wiring in `MetalMosaicGenerator` (three places derive the
layout; one helper fixes it, covered by tests). Medium: the header cap and watermark clamp
(small, grid-only). Low: model and hash (additive, golden-tested). The shipped layouts' code
paths are not edited except to pass new defaulted parameters, which is why only the ⚡ A/B/A
"nothing regressed" gate is needed on G-2.
