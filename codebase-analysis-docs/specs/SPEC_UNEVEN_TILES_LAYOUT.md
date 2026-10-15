# Spec: uneven-size tiles layout (`LayoutType.uneven`)

Status: **proposal, 2026-10-15.** Research and design only: nothing under `Sources/` or `Tests/`
changed, and no existing doc was edited. Sibling documents:
[CODEBASE_KNOWLEDGE.md](../CODEBASE_KNOWLEDGE.md) (F3, F4, F5, F12, §3.14, §4.1, §4.8) and
[IMPLEMENTATION_PLAN.md](../IMPLEMENTATION_PLAN.md) (row style, gates, decision log).
Source code is authoritative; file and line references are to `main@07779ce`.

Prototype numbers in §7 were measured on an Apple M1 Pro, macOS 27.0.1, Xcode 27 SDK
(Swift 6.4 toolchain). The prototype scripts are throwaway and not committed.

## Contents

1. [Summary and recommendation](#1-summary-and-recommendation)
2. [Goal, non-goals, interpretation](#2-goal-non-goals-interpretation)
3. [Candidate packing strategies](#3-candidate-packing-strategies)
4. [The recommended packer in detail](#4-the-recommended-packer-in-detail)
5. [Which frames get which size](#5-which-frames-get-which-size)
6. [Public API, Codable, validation, identity](#6-public-api-codable-validation-identity)
7. [Pipeline integration and cost](#7-pipeline-integration-and-cost)
8. [Edge-case catalogue](#8-edge-case-catalogue)
9. [Apple technologies](#9-apple-technologies)
10. [Prototype and measurements](#10-prototype-and-measurements)
11. [Test plan and performance gates](#11-test-plan-and-performance-gates)
12. [Open questions](#12-open-questions)
13. [Phased implementation plan](#13-phased-implementation-plan)

---

## 1. Summary and recommendation

**The request.** A mosaic whose thumbnails have *uneven sizes*: at medium density about `x`
different sizes, from 1 to `x`, the largest `x` times the smallest. Reuse existing ratios, and
solve the hard part: tiling the requested width and aspect ratio without cut or deformed images.

**Recommendation.** Add a new layout, `LayoutType.uneven`, built on an **integer-span "bento"
grid**:

- The canvas is a `C × R` grid of *unit cells*. A unit cell has the source video's aspect ratio.
- A tile is a `k × k` block of unit cells, `k ∈ 1…x`. A `k × k` block of source-aspect cells
  *has the source aspect ratio exactly*, so no frame is ever cropped or distorted, whatever its
  size. This is the same integer-ratio idea as the existing `.custom` layout (large cells are a
  fixed multiple of small cells), generalized from one ratio (1.25–2.0) to the integers `1…x`.
- Because 1×1 cells can fill any hole, the tiling is **always exact**: no gaps, no overlaps, by
  construction. The real design problem is therefore not "squaring the rectangle" but (a) choosing
  `C × R` so the canvas hits the target aspect ratio and tile count, and (b) placing the larger
  tiles so they look balanced. §4 solves both with a deterministic, microsecond-scale algorithm.
- Density picks `x`: `XXL 2, XL 2, L 3, M 3, S 4, XS 4, XXS 5` (capped by what the grid can hold).
  At **M, x = 3: sizes 1×1, 2×2 and 3×3**, about 45 % of the canvas area in the larger tiles.

**Measured quality** (§10; 720 cases with ≥ 30 frames, 3 sources × 5 target aspects × 3 widths ×
4 values of x × frame counts 30…800; the recommended packer is "A1"):

| Metric | A1 (recommended) | Existing `.custom` on the same cases |
|---|---|---|
| Exact coverage, overlaps, out-of-bounds tiles | 100 % / 0 / 0 in all 1,080 cases | not measured (cells are placed with float math) |
| Canvas aspect error (median / p95) | 0.15 % / 3.5 % | 2.6 % / 19 % |
| Tile-count error vs the requested count (median / p95) | 0.19 % / 13 % | 7.7 % / 40 % |
| Tiles whose aspect is more than 2 % off the source | 0.00 % at width ≥ 5120 px | 0 % (cells computed from the aspect) |
| Packer run time in Swift (N = 107 / 429 / 800) | 0.16 / 0.66 / 1.4 ms | n/a |

**What is not solved by the packer, and must be decided before shipping**
(§7 and §12): (1) decoding every frame at the *largest* tile size and shrinking with the existing
bilinear GPU kernel is expected to alias for `k ≥ 3` (not yet checked visually; the U-3 PR records the comparison); the pipeline should decode each frame at
its own tile size (a ⚡ change to `ThumbnailProcessor`); (2) a handful of naming, gutter and
fallback choices (Q-U1…Q-U11).

**Main alternative.** Justified rows with variable counts per row ("B", Flickr style) hit the
canvas aspect almost exactly (median 0.00 %, p95 0.19 %) and keep gutters uniform, but every
tile in a row has the same size, so it only looks "uneven" from row to row, and it needs a
dynamic-programming search (20–40 ms median in Python). It is the recommended **fallback
variant**, not the first implementation (§3.2).

---

## 2. Goal, non-goals, interpretation

### 2.1 Goal

A layout in which a contact sheet shows frames at several sizes at once, so a viewer can pick out
a few "hero" frames while still seeing the whole video. Hard requirements, in priority order:

1. **No cropped and no distorted frame.** Today the renderer stretches every frame to its cell
   without keeping the aspect ratio (`scaleTexture`, `MetalImageProcessor.swift:319`;
   `renderFrame`, `:1077`). So every cell must have the source aspect ratio.
2. **Exact use of the requested width**, canvas height close to `width / aspectRatio`.
3. **Exact coverage**: tiles are inside the canvas, never overlap, and the only empty pixels are
   the intended gutters. (`.dynamic` failed this and was retired, I-8.)
4. **Deterministic**: same inputs, same layout, on every run and machine.
5. **Tile count close to the requested count** (`calculateThumbnailCount`, density-driven).

### 2.2 Non-goals

- No cropping, letterboxing or "cover" fitting of frames.
- No content analysis in v1 (§5 describes it as a later opt-in).
- No change to frame sampling (20/60/20 split over 5–95 %), to the other layouts' output, or to
  existing output paths (rules card #3, #4).
- No new dependency (CLAUDE.md: prefer Apple frameworks).
- No mixed-aspect mosaics (one source video per mosaic).
- No change to `.iphone` (`forIphone: true` still forces the single-column layout,
  `MetalMosaicGenerator.swift:326`).

### 2.3 How "sizes 1 to x" and "reuse existing ratios" are interpreted

**Chosen interpretation (I1): linear integer spans.** A *size class* is an integer `k` from 1 to
`x`. A class-`k` tile is `k` unit cells wide and `k` unit cells tall, so its width and height are
`k` times those of the smallest tile (and its area `k²` times). "The largest is `x` times larger
than the smallest" is read as *linear*, because linear integer multiples are what preserve the
source aspect exactly. "Reuse existing ratios" is read as:

| Reused thing | Where it exists today | How the new layout reuses it |
|---|---|---|
| Large/small cell ratio as a fixed multiple | `.custom`: 2.0 / 1.6 / 1.33 / 1.25 by target aspect (`LayoutProcessor.swift:289`) | `k = 2` is the 2.0 ratio exactly; `k = 3, 4, 5` extend it. Non-integer ratios (1.25–1.6) cannot tile a grid exactly, so they are only available in variant B (rows with 4 vs 5 tiles give 1.25, 3 vs 4 give 1.33, 5 vs 8 give 1.6) |
| Cell aspect = source aspect | every layout (`originalAspectRatio`) | every unit cell and, as a consequence, every `k × k` tile |
| The five `AspectRatio` presets and `findNearest` snapping | `LayoutConfiguration.swift:64`, `MetalMosaicGenerator.swift:348` | target canvas aspect; the layout may miss it by a small, reported amount, and the generator snaps the config aspect to the nearest preset as it does for `.custom` |
| 4 px gutters between cells, flush canvas edges, width exact, height = whatever fits, integer pixel positions | `.custom`, `.classic` | same convention, so `renderRect`'s "baseline spacing 4" assumption (`MetalImageProcessor.swift:1165`) stays true |
| `DensityConfig` as the single "how many / how detailed" knob | all layouts | density chooses both the frame count (unchanged) and `x` (new table in §4.2) |

**Alternatives considered and why they were not chosen**

| # | Interpretation | Verdict |
|---|---|---|
| I2 | "x times larger" means *area* ratio `x` | Tile sides would be `√k` times the unit: not integers, so tiles cannot share a lattice and the aspect-exact tiling property is lost. Only `x ∈ {1, 4, 9, 16, …}` works, which is just I1 with squared labels. Rejected. |
| I3 | Sizes continuous (any real scale between 1 and `x`) | Needs a real-valued packer (justified rows or treemap). Rows keep the aspect (variant B); treemaps do not (§3.3). Kept as variant B. |
| I4 | Size set not consecutive, e.g. powers of two `{1, 2, 4}` | Fewer distinct sizes, ratio 4 with only three classes; tiles still tile exactly. Cheap to support later as an option (`sizeSet`). Not in v1. |
| I5 | Reuse the custom layout's *real-valued* ratios (1.25, 1.33, 1.6, 2.0) as the size classes | Only exact in variant B. For grid packing they would need a common sub-lattice (1.25 = 5/4, 1.6 = 8/5 …) of 20+ unit cells per side. Rejected for the grid. |

---

## 3. Candidate packing strategies

Notation: source aspect `a` (width/height, e.g. 16/9), target canvas aspect `A`, canvas width
`W` px, requested tile count `N`, gutter `g` px (4), `x` the largest span.

### 3.1 (a) Integer-span "bento" grid on a `C × R` lattice

**Idea.** Canvas = `C × R` unit cells of aspect `a`; tile = `k × k` block, `k ≤ x`; 1×1 fillers
complete the grid. Placement by a skyline sweep ("lowest, then leftmost free cell") with a
deterministic scheduler that decides when a larger tile is due (A1), or by anchoring the large
tiles first with a low-discrepancy sequence and filling the rest (A2).

**Why exact coverage is free.** The unit cell is a legal tile, so any non-overlapping placement
of the larger tiles can be completed with 1×1 cells. The classic "squaring the rectangle"
problem (tile a rectangle with *distinct* squares) is harder and unnecessary: the maintainer's
"sizes from 1 to x" allows repeats.

**The canvas aspect is set by the lattice.** `canvas aspect = C·a / R`, so `R ≈ C·a / A`. With
`C·R ≈ N / τ` cells (τ = tiles per cell for the chosen size mix) there are many `(C, R)` pairs
to choose from; the error is the grid granularity (§4.3). It is exactly zero when `A = a` and
`C = R`, which is the common case (16:9 video, 16:9 mosaic).

| Property | Assessment |
|---|---|
| Exact-coverage guarantee | Yes, by construction (verified: 1,080 cases, 0 overlaps, 0 out-of-bounds, 100 % of cells covered) |
| Aspect error of a tile | Zero with the aspect-matched gutter (§4.5) up to 1–2 px pixel rounding; up to ≈ 1–2 % on hero tiles with a uniform 4 px gutter |
| Cut or deformed frame risk | None by design; only pixel rounding on tiles narrower than ≈ 100 px |
| Determinism | Yes: integer scheduling, golden-ratio sequence, no hashing, no random source |
| Complexity | O(cells × seeds); 0.06 ms (N = 26) to 1.4 ms (N = 800) per call in Swift, 8 seeds |
| Meets target width | Exactly (edges are rounded from `W`) |
| Meets target aspect | Median 0.15 %, p95 3.5 % (§10); better with larger `N` |
| How `x` and the largest/smallest ratio come from density | Directly: classes are `1…x`, ratio = `x`, table in §4.2 |

### 3.2 (b) Justified rows with variable counts (Flickr style)

**Idea.** Every row holds `m` tiles of the same height; tile width is `(W − (m−1)g) / m`, height
`width / a`. Row height is therefore fixed by `m`: a row with few tiles is "large", a row with
many is "small". Choose the sequence of row counts so that the stacked heights equal
`W / A`. That is an Egyptian-fraction-like subset problem; the prototype solves it with a
dynamic program over (tile count, height in px) using big-integer bitsets, restricted to
`m ∈ [m_hi / x, m_hi]` so the largest/smallest row-size ratio is about `x`.

| Property | Assessment |
|---|---|
| Exact-coverage guarantee | Yes: each row spans `[0, W]` exactly and rows stack with a constant gap |
| Aspect error of a tile | Exactly `a` with a *uniform* gutter (no spans, so no gutter-induced error); pixel rounding only |
| Cut or deformed frame risk | None |
| Determinism | Yes if the reconstruction uses a seeded generator (the prototype does) |
| Complexity | DP over tile counts × heights × row sizes; 20 ms median, 1.4 s worst in Python, so roughly 1–50 ms in Swift; needs care to stay off the actor for large `N` |
| Meets target width / aspect | Width exact; aspect error median 0.00 %, p95 0.19 % (N ≥ 30) |
| Size variety | Per row only: median 6 distinct row sizes, but the achieved largest/smallest ratio is below the requested `x` in most cases (median 2.4 for `x = 3`) unless the DP is constrained further |
| Look | "Rows of different zoom"; a large tile is as tall as its whole row, so no 2-D hero effect |

It is the strongest option when exact canvas aspect matters more than a bento look, and it
naturally reproduces the custom layout's non-integer ratios (rows of 4 and 5 tiles: 1.25).

### 3.3 (c) Squarified treemap or binary space partition

**Idea.** Give each frame an "importance" weight (its area share) and let a treemap pick
rectangles of those areas inside the canvas.

Treemaps optimize aspect ratios *near 1*, not the video's aspect. A rectangle that is not the
source aspect forces a crop (cover) or a stretch, which is exactly what the request rules out.
Measured: **99.97 % of tiles were more than 2 % off the source aspect, median error 79 %** (§10).
A BSP/guillotine partition restricted to similar rectangles has to cut each rectangle into
`k × k` blocks of the unit cell and therefore *is* the bento grid. Rejected as a primary
strategy; kept in the prototype only as evidence.

### 3.4 (d) Other approaches considered

| Approach | Verdict |
|---|---|
| **A2: bento with anchored heroes** (place the large tiles first at low-discrepancy positions, then fill) | Hits the requested hero counts exactly (0.00 % quota miss vs 0.29 %) and is 5–7× faster, but heroes sit less evenly (worst third-of-canvas deviation 0.120 vs 0.104, left/right imbalance 0.148 vs 0.113, more edge-sharing hero pairs). Same coverage and aspect quality. Viable alternative; A1 chosen for the better visual balance and because its placement order is already the reading order. |
| **Perfect squared rectangle** (all tile sizes distinct) | Needs a search over simple perfect squared rectangles; sizes cannot be chosen freely; no tile-count control. Rejected. |
| **Exact cover with Dancing Links** to hit any hero histogram | Exponential worst case, no deterministic upper bound on time, no visual benefit over best-of-8 skyline. Rejected. |
| **Hybrid: bento first, fall back to rows B when the canvas aspect error exceeds a tolerance** | Attractive because B is near exact where A is weakest (small `N`, extreme aspect pairs). Costs a second packer to maintain. Open question Q-U4; not in v1. |
| **Letterboxed canvas**: pad the bento grid with background to hit the aspect exactly | Never crops a frame and gives an exact aspect, but visible bands; the generator already tolerates a small aspect miss by snapping. Option, not default. |
| **Multi-scale hexagon, Voronoi or masonry (columns)** | Hexagon/Voronoi tiles are not rectangles. Masonry columns equal justified rows rotated by 90° (useful for portrait mosaics; same family as B). Not pursued. |

### 3.5 Comparison

| Criterion | A1 bento skyline | A2 bento anchored | B justified rows | C treemap |
|---|---|---|---|---|
| Exact coverage | yes | yes | yes | yes (floating point) |
| Tile aspect = source | yes (gutter-matched) | yes | yes | **no (median 79 % off)** |
| Canvas aspect error, N ≥ 30 (median / p95) | 0.15 % / 3.5 % | same | 0.00 % / 0.19 % | 0 % (but tiles wrong) |
| Tile-count error, N ≥ 30 (median / p95) | 0.19 % / 13 % | 0.12 % / 3.3 % | 0.00 % / 7.5 % | 0 % |
| 2-D hero tiles | yes | yes | no (row-wide) | yes (wrong shape) |
| Gutters | horizontal 4 px, vertical 2–3 px (matched) or uniform with 1–2 % stretch | same | uniform 4 px | uniform |
| Run time (Swift, N = 107) | 0.16 ms | ≈ 0.03 ms (Python ratio) | est. 1–5 ms | < 0.05 ms |
| Needs search | no | no | yes (DP) | no |
| Verdict | **recommended** | alternative | fallback variant | rejected |

---

## 4. The recommended packer in detail

### 4.1 Inputs and outputs

Inputs: `a` (source aspect, `originalAspectRatio`), `A` (target aspect, `AspectRatio.ratio`),
`W` (`mosaicWidth`), `N` (`thumbnailCount`, a target), `x` (largest span, from density),
`g = 4`. Output: tiles `(col, row, k)` sorted in reading order, and the pixel geometry that fills a
`MosaicLayout` (`positions`, `thumbnailSizes`, `mosaicSize`, `rows = R`, `cols = C`,
`thumbnailSize` = the unit tile, `thumbCount` = number of tiles).

### 4.2 Size mix and density table

Share of canvas *area* given to spans ≥ 2: **β = 0.45**, split equally between classes
`2…x`. (Class 1 gets 55 %.) With that mix one unit cell holds
`τ = 0.55 + Σ_{k=2…x} (0.45/(x−1)) / k²` tiles, so the canvas needs about `N / τ` cells.

| Density | Factor | Default `x` | Sizes | Example at W = 5120, 1 h video, 16:9 → 16:9 |
|---|---|---|---|---|
| XXL | 0.25 | 2 | 1, 2 | N 26 → 6×6 grid, 27 tiles, unit 850×478 px, hero 1704×960 |
| XL | 0.5 | 2 | 1, 2 | N 53 → 9×9, 54 tiles, unit 565×318, hero 1135×640 |
| L | 0.75 | 3 | 1, 2, 3 | N 80 → 11×11, 79 tiles, unit 461×259, hero 1394×787 |
| **M** | **1.0** | **3** | **1, 2, 3** | **N 107 → 13×13, 107 tiles, unit 390×219, hero 1179×666** |
| S | 2.0 | 4 | 1…4 | N 214 → 19×19, 214 tiles, unit 265×149, hero 1075×610 |
| XS | 3.0 | 4 | 1…4 | N 322 → 23×23, 322 tiles, unit 218×123, hero 888×504 |
| XXS | 4.0 | 5 | 1…5 | N 429 → 27×27, 429 tiles, unit 185×104, hero 945×539 |

Rationale: the hero should stay below about a quarter of the canvas width and the unit tile above
about 100 px, so `x` grows with the cell count. The effective maximum is
`x_eff = min(x, max(1, ⌊min(C, R) / 2⌋))`, i.e. a hero never exceeds half of the shorter side
(measured rule; `⌊min(C, R)/3⌋` is the gentler alternative, Q-U2). The solver also never lets the
larger tiles cover more than 60 % of the cells.

The per-class hero counts are chosen so the **tile count lands on N**: with `cells = C·R`,
`tiles = cells − Σ (k² − 1)·n_k`. The solver starts from the area shares and nudges `n_k` by ±1
until `Σ (k² − 1)·n_k = cells − N` (reachable to within 2). That is what makes the tile-count
error 0.19 % at the median instead of ≈ 7 %.

The M-density result for 16:9 → 16:9 at N = 107 (a letter is one 2×2 tile, a capital one 3×3
tile; `.` is a 1×1 tile):

```
. . a a . . . . . B B B .
c c a a . . . . . B B B .
c c . . . . d d . B B B .
. . . . . . d d . . . e e
. F F F g g . . . . . e e
. F F F g g . . . . . . .
. F F F . . h h . I I I .
j j . . . . h h . I I I .
j j . . . . k k . I I I .
. . . . . . k k . l l . .
. M M M n n . . . l l . .
. M M M n n . . . . . . .
. M M M . . . . . . . . .
```

93 unit tiles, 10 of 2×2, 4 of 3×3 (107 tiles, 169 cells, 45 % of the area in the larger tiles).
The 3×3 tiles sit in columns 1–3 and 9–11; the heuristic does not yet put one in the bottom
right. See the balance metrics in §10.5 and Q-U2.

### 4.3 Choosing the grid `(C, R)`

1. `τ` from §4.2; `cells0 = N / τ`.
2. For every `C` from 1 to `1.5·cells0`, take `R ∈ {⌊C·a/A⌋, ⌈C·a/A⌉}`.
3. Keep pairs with `|C·R − cells0| / cells0 ≤ 0.2` (the window doubles by 1.6× until one exists).
4. Score `|C·a/(R·A) − 1| + 0.05·|C·R − cells0|/cells0`; take the minimum. (A ±20 % window is
   enough: ±35 % and ±50 % gave identical canvas errors in the prototype; ±10 % was worse, p95
   11 %.)
5. Recompute `x_eff`; if it dropped, repeat from step 1 with the smaller `x` (the mix, and so τ,
   changes). It converges in ≤ 3 iterations.
6. Apply the hard caps from §8: `unit width ≥ 120 px` (so `C ≤ ⌊(W + g) / (120 + g)⌋`) and
   `canvas height ≤ 16384 − reserve` (so `R` is capped). If a cap binds, the tile count falls
   below `N`; log it at `.info`.

### 4.4 Placement (A1)

```
sky[0..<C] = 0 ; placed[k] = 0 ; filled = 0
repeat until filled == C·R:
    y  = min(sky) ; c0 = first column with sky == y
    run = number of consecutive columns from c0 with sky == y
    maxK = min(run, R − y, x_eff)
    progress = min(1, filled / (C·R · 0.92))            # END_SLACK: quotas fall due by 92 % of the area
    pick the largest k in 2…maxK with
        placed[k] < quota[k]  and  quota[k]·progress + phase[k] − placed[k] ≥ 0.5     # error diffusion
    otherwise k = 1
    if k > 1: column offset inside the run = ⌊frac(seed·0.37 + (tileIndex+1)·φ + k·0.31) · (run − k + 1)⌋
              with φ = 0.6180339887                    # spreads heroes across the width
    sky[cols] += k ; filled += k² ; append (col, y, k)
```

`phase[k] = 0.5·frac(k·φ + seed·0.37)` staggers the classes so a 2×2 and a 3×3 are not due at the
same slot. The run is **repeated for 8 seeds** and the best result is kept by
`2·quotaMiss + thirdsDeviation + 0.5·leftRightImbalance + 0.5·adjacentHeroPairs/heroes`. Eight
seeds cost 8× one pass (still < 1.5 ms at N = 800) and cut the mean third-of-canvas deviation from
0.150 to 0.122 and the quota miss from 2.3 % to 0.5 % (16 seeds: 0.115; 32: 0.113, diminishing).

Tiles are finally sorted by `(row, col)`: this is the reading order, and the **frame order**
(§5): tile `i` receives the `i`-th extraction time.

### 4.5 Pixel geometry and gutters

Existing layouts put a 4 px gutter *between* cells and keep the canvas edges flush. The new
layout keeps that convention (so `renderRect`'s baseline-4 assumption holds). Unit cell width
`u = (W − (C−1)·g_x) / C`, height `v = u / a`; a `k × k` tile is
`k·u + (k−1)·g_x` wide and `k·v + (k−1)·g_y` tall; its left edge is
`round(c·(u + g_x))`, its right edge `round((c+k)·(u + g_x) − g_x)` (same for the vertical axis).
With an integer `g_x`, **neighbouring tiles are exactly `g_x` px apart horizontally** (measured:
110 of 110 gaps are 4 px).

A `k × k` tile has the source aspect exactly only if the gutter has the same aspect as the cell:

| Gutter model | Tile aspect error (median / p95 / max, width 5120, N = 30/107/400) | Tiles stretched > 2 px | Look |
|---|---|---|---|
| **Aspect-matched**: larger gutter = `g`, smaller = `g · min(a, 1/a)`; for 16:9, 4 px horizontal and 2.25 px vertical | 0.15 % / 0.60 % / 1.48 % (rounding only) | 1.0 % | gaps visibly a little narrower vertically (2–3 px vs 4 px) |
| Uniform `g` on both axes | 0.18 % / 0.88 % / 2.23 % | 10.9 % | uniform; hero tiles are stretched ≤ 2 % |
| Inset of each partition cell by `g/2` | 1.19 % / 2.55 % / 3.79 % | 74 % | rejected: the outer cells are also stretched |

Recommendation: **aspect-matched** (Q-U3). It makes "every tile has the source aspect to within
rounding" an exact, testable invariant. The uniform model is the fallback if the vertical gap
looks wrong in review.

### 4.6 Mapping to `MosaicLayout`

| Field | Value |
|---|---|
| `positions`, `thumbnailSizes` | integer pixel top-left and size of each tile, reading order |
| `thumbCount` | number of tiles (also what animated export extracts) |
| `rows`, `cols` | `R`, `C` |
| `thumbnailSize` | the unit tile (smallest). The header's minimum height is derived from it (`createMetadataHeader(thumbnailHeight:)`), and `mosaicOuterPadding` uses the smallest tile, so the unit tile is the consistent choice |
| `mosaicSize` | `(W, H)` with `H = round(R·v + (R−1)·g_y)` |

---

## 5. Which frames get which size

| Scheme | How | Cost | Verdict |
|---|---|---|---|
| **P: positional (default)** | The packer fixes the size of tile `i`; the frame sampled at time `t_i` goes there. Frame order is reading order, so Color DNA columns (frame-index order) and frame labels stay chronological. | None. No change to extraction order or to `processedFramesStream`. | **v1** |
| **T: time-nudged hero frames** | Keep tile positions; for each hero slot, test 3–4 candidate times inside the interval between its neighbours' times, and take the best by saliency or aesthetics score. Time order is preserved. | `4 × (#heroes)` extra low-resolution decodes plus Vision requests. At M (14 heroes): ≈ 56 requests; measured per request on a 512×288 frame: attention saliency 10.9 ms, feature print 6.8 ms, aesthetics 11.7 ms, face rectangles 17.2 ms, so about 0.4–1.0 s serial extra. Results can differ across devices and OS releases (Neural Engine vs GPU), so layouts stay deterministic but *frame choice* does not. | Phase U-5, opt-in |
| **S: fully content-driven** | Score every candidate frame, give the best frames the largest tiles, and re-place them. | Needs all frames before any can be composed, which breaks the streaming path (`processedFramesStream` yields frames as they decode and the GPU composes in 20-frame command buffers). Scoring all 800 frames at ≈ 11 ms is ≈ 9 s serial. Reorders time, so a "chronological contact sheet" is lost unless heroes are only nudged within their time slot (that is scheme T). | Not recommended |

Scheme P puts the larger tiles at fixed *screen* positions, so which moments of the video become
heroes depends only on the 20/60/20 sampling and the packer: reproducible and testable.

---

## 6. Public API, Codable, validation, identity

### 6.1 API sketch

```swift
public enum LayoutType: String, Codable, Sendable {
    case auto, custom, dynamic /* deprecated */, classic, iphone
    /// Tiles in several sizes: a bento grid where larger tiles are whole multiples of the
    /// smallest, so no frame is cropped or distorted. The largest size depends on density.
    case uneven                                   // raw value "uneven" is persisted: never rename
    public static let allCases: [LayoutType] = [.auto, .custom, .classic, .iphone, .uneven]
}
```

v1 ships **no new options**: `x` comes from the density table, β is fixed. That keeps
`LayoutConfiguration`, `MosaicConfiguration.init` and `configurationHash` untouched. If an
override is wanted (phase U-4):

```swift
public struct UnevenTilesOptions: Codable, Sendable, Hashable {
    public var maxSpan: Int?             // nil = from density; 2…8
    public var gutter: Gutter            // .aspectMatched (default) | .uniform
    public enum Gutter: String, Codable, Sendable { case aspectMatched, uniform }
}
// LayoutConfiguration:   public var uneven: UnevenTilesOptions? = nil   (decodeIfPresent, default nil)
```

Internal, pure and `Sendable` (testable without Metal or AVFoundation):

```swift
struct UnevenTilePacker: Sendable {
    struct Tile: Equatable, Sendable { var col: Int; var row: Int; var span: Int }
    struct Plan: Sendable { var cols: Int; var rows: Int; var maxSpan: Int; var tiles: [Tile] }
    static func plan(sourceAspect: Double, targetAspect: Double, width: Int, count: Int,
                     maxSpan: Int, gutter: Double) -> Plan            // deterministic, no throws
    static func geometry(for plan: Plan, width: Int, sourceAspect: Double,
                         gutter: Double, model: GutterModel) -> MosaicLayout
}
```

Naming note (Q-U1): `uneven` follows the existing one-word lowercase raw values and describes
the property rather than the algorithm, so the packer can change without renaming. `bento` is the
algorithm's name.

### 6.2 Codable compatibility

- A new `LayoutType` case is source- and decode-compatible for new libraries. A config saved with
  `"uneven"` **fails to decode in older MosaicKit versions** (unknown raw value): unavoidable,
  note it in the release notes. Optional hardening, independent of this feature: give
  `LayoutType` a decoder that maps unknown raw values to `.custom`, so future additions degrade.
- New keys (only if U-4 ships): `decodeIfPresent` with a default, added to `MissingKeyDefault`
  (rules card #2). The pinned payloads (`mosaic-config-*.json`) are never edited.
- Persisted raw values are not renamed (rules card #3).

### 6.3 Validation (rules card #8: `ConfigurationValidation.swift`)

- `layout.layoutType == .uneven` with `layout.aspectRatio` valid: nothing new to reject.
- With U-4: `maxSpan ∈ 2…8`.
- Combinations that cannot work are *not* errors but logged fallbacks inside the layout (§8): too
  few frames, extreme source aspect, canvas height over the texture limit.

### 6.4 `LayoutProcessor`, cache key, hash, paths

- `calculateLayout` dispatches with `switch layoutType` and a `default:` that falls through to
  `.custom` (`LayoutProcessor.swift:118–145`). **A new case that is not added explicitly would
  silently be laid out as `.custom`.** The PR must add `case .uneven:` and should replace the
  `default:` with explicit cases.
- The cache key (`:113`) already contains the layout raw value; any option or constant that
  changes the result must join it (§4.8 "touching layout"). For the default options nothing is
  appended, so existing keys are unchanged.
- `configurationHash` = `<width>_<density>_<aspect>_<layout>` becomes `5120_M_16-9_uneven`: a new
  folder, so **no existing output moves** (no 📁 change). Options added in U-4 must be appended
  only when non-default (`5120_M_16-9_uneven-s4`), never to existing hashes (rule 4).
- **Algorithm revisions change output for the same hash.** Policy proposal (Q-U7): freeze the
  packer after release, pin golden layouts in tests, and ship any improvement as an explicit
  `algorithmRevision` option whose non-default value joins the hash.

---

## 7. Pipeline integration and cost

What changes and what does not, walking the stages of knowledge-base §2.3:

| Stage | Change |
|---|---|
| 3 thumbnail count | None: `calculateThumbnailCount` already handles non-`.auto` types. The count is a target; the packer returns the actual count. |
| 4 layout | New `case .uneven` (§6.4). Runs under the processor's `NSRecursiveLock`; 0.06–1.4 ms, so rule 6 is respected. |
| 5 aspect normalization | Unchanged: `AspectRatio.findNearest(to: layout.mosaicSize)`. |
| 6 header | Unchanged; height derives from the unit tile. |
| 7 extraction | **Needs a change (below).** |
| 10 compositing | None: `renderFrame` already draws cells of any size from `layout.thumbnailSizes`. The required `thumbnailSizes.count == positions.count` check exists (`MetalImageProcessor.swift:896`). |
| 14 animation | None: GIF/HEICS/WebP frames are all `gifSize`; one frame per tile (`layout.thumbCount`). |

**Extraction decodes every frame at the largest tile size.**
`ThumbnailProcessor.configureGenerator` sets `maximumSize` to the maximum width and height over
*all* cells (`:496`), and `addTimestampToImage` draws each frame into a full-size context at the
decoded size (`:996`). With custom the ratio is ≤ 2, so a small cell is decoded at most 2× too
large. With `x = 3…5` it would be up to 5× per side (25× the pixels). Two consequences:

1. **Quality.** The GPU shrink uses a single-tap bilinear sampler (`scaleTexture` in
   `MetalShaders.metal:6`; `mip_filter::linear` has no effect because the source texture has no
   mip levels). A 3× or larger bilinear downscale is expected to alias (not verified visually in this research). Decoding at the tile's own size lets
   `AVAssetImageGenerator` do the (better filtered) downscale.
2. **CPU.** Measured on this Mac with a label-style rounded-clip draw into a full-size
   `CGContext`: 1.2 ms per frame at 390×219, 3.3 ms at 780×438, 6.8 ms at 1178×666, 16.6 ms at
   1920×1080. **Decode time itself did not depend on `maximumSize`** (≈ 10 ms per frame for 720p,
   1080p and 1512p sources). At M that is ≈ 0.6 s of extra CPU spread over ≤ 8 concurrent
   tasks, against ≈ 1.1 s of serial decode: noticeable but not dominant.

Recommended change (phase U-3, ⚡): group extraction times by tile size and use one
`AVAssetImageGenerator` per distinct size, each with `maximumSize` = that tile; frames still carry
their global index through `processedFramesStream` and out-of-order arrival is already supported.
The 1.7.0 lesson (the bounded source was 30–45 % slower) applies: the change must be A/B/A
benchmarked against the baseline and against `.custom` at the same frame count. A fallback that
changes nothing in the shared path is to cap `x` at 2 until U-3 lands.

---

## 8. Edge-case catalogue

Numbers come from the prototype (§10) unless stated. "Fallback" means the layout still returns a
valid `MosaicLayout` and logs the reason.

| # | Case | Numeric example | What goes wrong | Recommended behavior |
|---|---|---|---|---|
| 1 | Target aspect the grid cannot hit | 16:9 source, 21:9 target, N = 12, W = 5120: grid 5×4 gives a 5120×2304 canvas against 2194 target (4.76 % off) | Granularity of `C·a/R` is ≈ 1/R; the canvas is taller than asked | Accept and report; the generator snaps the config aspect to the nearest preset (`planMosaic`). Error shrinks with N: median 0.25 % and p95 1.6 % at N = 107 |
| 2 | Aspect error at very small N | N = 4, 21:9: only 2×2 fits, 23.8 % off | A 2×2 grid has aspect `a` | Below 12 frames use the existing classic layout (Q-U5); `x_eff` is 1 there anyway |
| 3 | Aspect pairs with a large mismatch | 21:9 source into a 1:1 mosaic at N = 30: grid 4×10, 6.8 % off (worst of 720 cases with N ≥ 30) | Few columns to trade against rows | Same as case 1; consider the hybrid with variant B (Q-U4) |
| 4 | Portrait source, 16:9 mosaic | 9:16 source, 16:9 target, N = 107: grid 22×7, canvas 5120×2891 (0.38 % off), unit 228 px wide | Only 7 rows: a 3×3 hero spans 3/7 of the height, unit tiles are narrow | Allowed; with the `⌊min(C,R)/3⌋` rule `x_eff` would be 2 (Q-U2). Frames stay portrait: cells are portrait because `originalAspectRatio` is the display aspect since F-1 |
| 5 | 9:16 mosaic from a 16:9 source | N = 107: grid 7×22, canvas 5120×9056 (0.51 % off) | Very tall canvas; in practice over the texture limit when W is large (case 13) | Cap rows by the height limit; header and DNA add height afterwards |
| 6 | Portrait source into 9:16 mosaic | 13×13 grid, 5120×9102, 0 % off | None | Normal case |
| 7 | 21:9 source | into 21:9: 13×13, 0.01 % off. Into 16:9: 12×16, 1.57 % off | Wide cells (unit 390×167); fine | Normal |
| 8 | Extreme source aspect | `a = 0.01…100` is accepted by the existing guard | Grid degenerates (e.g. `a = 50`: one tall column) | If `a` is outside [0.2, 5] fall back to classic and log |
| 9 | Very low frame count | N = 4 → 2×2, 4 tiles (no larger tile fits) | `x_eff = 1`: not uneven | Fallback to classic below 12 (case 2) |
| 10 | Low count, one hero | N = 12, 16:9: 4×4 grid, 12 unit + one 2×2 = 13 tiles | Looks like a grid with one big tile | Accept; first count at which a hero exists is ≈ 10–12 |
| 11 | Very high frame count | N = 800, x = 5, W = 5120: 36×36 grid, 799 tiles, unit 138 px | Small unit tiles | Fine; cap `N` at 5,000 inside the packer (12 ms) because the public API accepts up to 100,000 |
| 12 | Counts that do not tile exactly | cells − N is not reachable with `3a + 8b + 15c…` | Residual of 1–2 tiles | Tile count may differ from N by ≤ 2 in normal cases; N is a target for every layout (custom returned 27 for N = 12). `thumbCount` is the actual count, so extraction and animation stay consistent |
| 13 | 16384 px canvas limit | 16:9 source, 9:16 target, W = 10000: height 17683 > 16384 | `validateTextureSize` throws (`MetalImageProcessor.swift:303`); the header and Color DNA add height after the layout | Cap `R` so `H ≤ 16384 − reserve` (proposal: 819 px = 5 % of the limit) and let the tile count fall; log. Custom and classic have the same latent failure |
| 14 | `x` larger than the grid allows | x = 5 on a 7×7 grid | A 5×5 hero fills 71 % of the side | `x_eff = min(x, ⌊min(C,R)/2⌋)`; fewer classes than requested (`x_eff < x` in 100 % of the N = 4 cases, 90 % at N = 12, 68 % at N = 30, 20 % at N = 107 and 0 % at N ≥ 400) |
| 15 | Hero quota cannot be placed | N = 400: bottom rows too short for a 5×5 | Quota missed | The 0.92 slack and 8 seeds bring the miss to 0.29 % of heroes on average; the tile count then exceeds N by the missed area |
| 16 | Minimum readable tile | W = 2000, N = 800: unit tile 51 px | Labels (15 px minimum font) cover a large part of the tile; 83 % of the W = 2000, N = 400 cases have a tile under 120 px wide | Hard floor of 120 px unit width (a 15 px label is then ≈ 22 % of a 67 px tall tile): cap `C ≤ ⌊(W+g)/(120+g)⌋` and let the count fall; log |
| 17 | Hero too large | W = 5120, x = 5, N = 429: hero 945 px of 5120 (18 %) | Fine | Keep hero ≤ 50 % of the short side |
| 18 | Header / Color DNA / watermark | Header min height scales with `thumbnailSize.height`; DNA strip and header are added *after* layout | Canvas aspect shifts by their height; the snapped aspect is computed before them | Same as every layout. `thumbnailSize` = the unit tile; DNA has one column per frame in index order, which is reading order |
| 19 | Frame labels on tiles of different sizes | Font = clamp(0.08·max(w,h), 10, 24)·1.5 per cell | Unit tiles under ≈ 125 px wide get the 15 px minimum label, which is relatively large | The 120 px floor keeps the label ≈ 22 % of the tile height or less; labels on hero tiles cap at 36 px |
| 20 | Spacing ≠ 4 | `layout.spacing = 12`: `renderRect` insets 4 px per side | Unit tile 390×219 → 382×211: aspect 1.81 vs 1.78 (+1.8 %); hero tiles +0.0 % | Existing behavior for all layouts. Optional general fix (Q-U10): inset the vertical axis in proportion to the tile aspect |
| 21 | Border / shadow | Border is drawn inside the frame rect; the CPU shadow is drawn at target size (`renderFrame`) | None specific | Nothing to do |
| 22 | Pixel rounding | W = 5120, C = 13: unit width 390.154 px | Rounding each tile's size independently would make the gutter jump between 3 and 5 px | Round the *edges* (not sizes). Measured: horizontal gutters are exactly 4 px in 110/110; vertical gutters are 2 or 3 px (aspect-matched, 2.25 ideal) |
| 23 | Tiny tiles and rounding | W = 2000, N ≥ 400: 10.5 % of tiles under 100 px wide are > 2 % off aspect (1 px of 45 px) | Pixel quantization, not layout error; 0.00 % at W ≥ 5120 | Covered by the 120 px floor; the property test uses a 1.5 px tolerance |
| 24 | Mixed source aspects | A video whose display aspect changes mid-stream, or non-square pixels | Frames differ slightly from the cell aspect | Same as every layout. Out of scope; the cell aspect is `VideoInput.width/height` (display size since F-1) |
| 25 | iPhone layout | `forIphone: true` | `.iphone` is forced before the layout type is read | `.uneven` is ignored with `forIphone`; documented. On an iPhone *device*, `.uneven` works, same texture limit |
| 26 | Animated export | `gifMode = .withMosaic`; frames extracted again at `gifSize` | Frame count equals `layout.thumbCount`; tile sizes are irrelevant | Nothing to do; the animation keeps one frame per tile in chronological order |
| 27 | Determinism across runs and machines | Swift `Hasher`, `Set`/`Dictionary` order and random sources vary per process | Different layouts for the same input | Use arrays indexed by `k`, a golden-ratio sequence and integer arithmetic; sort by the unique key `(row, col)`. Pin golden layouts in tests. Verified: the Python and Swift prototypes agree tile for tile on 5 cases |
| 28 | Concurrency | `LayoutProcessor` is not an actor; it holds an `NSRecursiveLock` while computing | A slow packer would block other jobs | Packer is a pure function; 0.06–1.4 ms for N ≤ 800 |
| 29 | Cache | Key `aspect-videoAR-count-width-density-layout` | Result depends on every input; nothing else | Add options to the key only when non-default; `.auto` stays uncached. 64-entry cache is ample |
| 30 | Cancellation | Long loops must call `Task.checkCancellation()` | The packer is synchronous and short | No cancellation points needed (< 5 ms); do not add `await` to the packer |
| 31 | Older library reading a saved `"uneven"` config | Decoding fails | One-way forward incompatibility | Release note; optional tolerant `LayoutType` decoding (§6.2) |
| 32 | Dynamic type or Retina scaling | `.auto` uses screen pixels | Not applicable to `.uneven` | Width is the requested pixel width |
| 33 | Gutter at hero boundaries | A hero covers `k` cells | No internal gutter inside a hero | By construction a hero is `k·u + (k−1)·g` wide: the internal gaps are absorbed |
| 34 | Cache of unit tests on iOS | Test code must compile for iOS | e.g. no `homeDirectoryForCurrentUser` | Pure geometry tests only; one end-to-end test (§11) |
| 35 | Hero clumping | Mean 0.081 edge-sharing hero pairs per tile; 3×3 tiles all in columns 1–3 and 9–11 in the M example | Looks unbalanced | Balance terms in the seed score; further tuning is cheap (§10.5, Q-U2) |
| 36 | Fewer classes than requested reported silently | `x_eff < x` | The user asked for `x` sizes | Log at `.debug`; document that `x` is a maximum |
| 37 | Very wide `W` and few frames | W = 16384, N = 12 | Unit tile 3,276 px; the decoder gets frames larger than the source | `maximumSize` never upscales; GPU upscales (same as classic at low N) |
| 38 | Memory | Canvas 5120×2901×4 B = 59 MB | None | Same as `.custom` of that size |

---

## 9. Apple technologies

Verified against the Xcode 27 SDK on this machine (`MacOSX.sdk`, Vision headers and
`swiftinterface`, AVFoundation headers, MetalPerformanceShaders headers, SwiftUICore interface).
The guides in `AdditionalDocumentation/` do not cover these frameworks (they hold Liquid Glass,
Foundation Models, Swift concurrency and similar), so the SDK headers are the evidence.
Deployment target is 26, so every API below is available without `#available`.

| Technology | Use / maybe / skip | Availability (verified) | Cost and reason |
|---|---|---|---|
| **Metal** (existing `scaleTexture` and `compositeTexture` kernels) | **Use** (no change) | already used | Variable-size tiles need no new kernel: `renderFrame` takes the size per cell. Single-tap bilinear shrink is the weakness (§7) |
| **Core Graphics** | **Use** only where it is used today | already used | Per-frame labels and shadow. Drawing the whole canvas on CPU would be slower than the GPU path |
| **AVFoundation `AVAssetImageGenerator`** per-size generators | **Use** (phase U-3) | existing API; `images(for:)` async batching | Measured: decode time ≈ 10 ms per frame whatever `maximumSize` is, so decoding at the right size is free for decode and cheaper for the CPU label step (1.2 vs 6.8 ms). Must be A/B/A benchmarked |
| **AVFoundation `AVSampleCursor`** (snap sample times to sync frames) | **Skip** | macOS 10.10, iOS 16 (`AVSampleCursor.h`) | The generator already uses a ±1 s tolerance to land on nearby key frames; no layout benefit |
| **Vision** `VNGenerateAttentionBasedSaliencyImageRequest` (Swift: `GenerateAttentionBasedSaliencyImageRequest`) | **Maybe** (U-5 hero nudging) | macOS 10.15 / iOS 13; Swift API macOS 15 / iOS 18 | 10.9 ms per 512×288 frame (measured). Good fit: a saliency map tells how "interesting" a frame is. Runs on the Neural Engine or GPU, so scores can differ across devices |
| **Vision** `VNGenerateObjectnessBasedSaliencyImageRequest` | **Skip** | macOS 10.15 / iOS 13 | 12.2 ms; objectness favours single objects, less suited to arbitrary footage than attention saliency |
| **Vision** `VNCalculateImageAestheticsScoresRequest` (`overallScore`, `isUtility`) | **Maybe** (U-5, best single signal) | macOS 15 / iOS 18; `CalculateImageAestheticsScoresRequest` in Swift | 11.7 ms. `isUtility` flags screenshots, receipts and similar, useful to avoid hero tiles on dull frames. Model changes between OS versions |
| **Vision** `VNDetectFaceRectanglesRequest`, `VNDetectFaceCaptureQualityRequest` | **Maybe** | macOS 10.13 / 10.15, iOS 11 / 13 | 17.2 ms for rectangles. Faces make good heroes in footage with people; adds a privacy-sensitive analysis step that must stay on device (it does) |
| **Vision** `VNGenerateImageFeaturePrintRequest` + `computeDistance` (Swift `distance(to:)`) | **Maybe** (scene-change spacing: choose distinct heroes) | macOS 10.15 / iOS 13; Swift API macOS 15 | 6.8 ms per frame; pairwise distances for ~50 candidates are trivial. Prevents two near-identical frames both being heroes |
| **Core ML** (custom interestingness model) | **Skip** | n/a | Vision already wraps the useful models; a custom model adds training, size and versioning for no clear gain |
| **Accelerate / vDSP** | **Skip** for scoring and search | framework present; `vDSP` is long-standing | Scoring ≤ 800 numbers and a ≤ 5,000-tile packer take microseconds in plain Swift |
| **Accelerate / vImage** (high-quality downscale of a `CGImage`) | **Maybe**, only if per-size decoding (U-3) loses on benchmark | framework present in the SDK; headers not found in this SDK dump, so function names are unverified here | Would let one hero-size decode serve all sizes with a Lanczos shrink before labeling |
| **Metal Performance Shaders** `MPSImageLanczosScale` | **Maybe**, same fallback as vImage | macOS 10.13, iOS 9 (`MPSImageResampling.h`) | A GPU Lanczos shrink to replace the bilinear `scaleTexture` for large ratios. Costs a new dependency on MPS and per-frame encoders; weigh against per-size decode |
| **Swift Algorithms** | **Skip** | open-source package, not in the SDK | Would be a new dependency (CLAUDE.md); the packer needs only `min`, `sort` and arrays |
| **GameplayKit** (`GKMersenneTwisterRandomSource`, `GKShuffledDistribution`) | **Skip** | `GameplayKit.framework` present | Seeded, deterministic, but a heavy import for 20 lines of golden-ratio arithmetic, and its distribution classes are not documented as stable across OS releases (not verified here), which golden layouts must not depend on |
| **SwiftUI `Layout` protocol** (client-side live preview) | **Maybe**, as an `Examples/` snippet | `SwiftUICore.Layout`, `placeSubviews(in:proposal:subviews:cache:)` | Apps can call the public `LayoutProcessor.calculateLayout` and place placeholder or real thumbnails at the returned rects before generating anything. `Grid`/`gridCellColumns` can span columns but not rows, so it cannot draw a bento grid. Not part of the package |
| **Swift `InlineArray` / `Span`** (Swift 6.2) | **Skip** | `AdditionalDocumentation/Swift-InlineArray-Span.md` | Skyline arrays are tiny; no measurable gain |
| **os_signpost / OSSignposter** | **Use** | already used | One interval around the packer, as the other layout functions have |

---

## 10. Prototype and measurements

### 10.1 What was built

Python (3.9, no libraries) implementations of four packers, plus a faithful port of
`calculateCustomLayout` as a baseline, run over a matrix; and a Swift port of A1 (compiled with
`swiftc -O`) for run time and a parity check. Everything lives outside the repository; the notes
folder of this session group holds a copy.

| Packer | What it is |
|---|---|
| A1 | Bento skyline: quota solver, error-diffusion scheduling, golden-ratio column spread, best of 8 seeds (§4) |
| A2 | Bento anchored: largest tiles first at Halton-sequence positions with spacing, 1×1 fill |
| B | Justified rows: dynamic program (bitsets) over row counts and heights, row counts in `[m_hi/x, m_hi]` |
| C | Squarified treemap (Bruls et al.) with the same size mix |
| baseline | Port of `calculateCustomLayout` (3 zones, ratios 1.25–2.0) |

**Matrix (1,080 cases per packer):** source aspect {16:9, 9:16, 21:9} × target aspect
{16:9, 4:3, 1:1, 21:9, 9:16} × width {2000, 5120, 10000} × N {4, 12, 30, 107, 400, 800} ×
x {2, 3, 4, 5}. Gutter 4 px. "Tiles stretched > 2 px" counts tiles whose width differs from
`height × a` by more than 2 px (pixel rounding allowance); "> 2 % off" is the relative aspect error
of the drawn rectangle.

### 10.2 All packers

Cases with N ≥ 30 (720 cases; the density levels L, M, S, XS, XXS and XL at normal durations):

| Packer | Cases | No solution | Canvas aspect error: median / p95 / max | Tile-count error: median / p95 | Tiles stretched > 2 px | Tiles > 2 % off aspect | Python ms: median / max |
|---|---|---|---|---|---|---|---|
| A1 bento skyline (recommended) | 720 | 0 | 0.15 % / 3.54 % / 6.76 % | 0.19 % / 13.33 % | 1.06 % | 3.24 % | 4.96 / 38.8 |
| A2 bento anchored | 720 | 0 | 0.15 % / 3.54 % / 6.76 % | 0.12 % / 3.33 % | 1.09 % | 3.23 % | 0.71 / 9.7 |
| B justified rows | 720 | 0 | 0.00 % / 0.19 % / 0.72 % | 0.00 % / 7.48 % | 0.00 % | 1.23 % | 38.66 / 1359.5 |
| C squarified treemap | 720 | 0 | 0.00 % / 0.00 % / 0.00 % | 0.00 % / 0.00 % | 99.99 % | 99.97 % | 0.42 / 1.6 |

All 1,080 cases (adds N = 4 and 12):

| Packer | Cases | No solution | Canvas aspect error: median / p95 / max | Tile-count error: median / p95 | Tiles stretched > 2 px | Tiles > 2 % off aspect |
|---|---|---|---|---|---|---|
| A1 bento skyline | 1080 | 0 | 0.48 % / 26.87 % / 69.68 % | 0.19 % / 25.00 % | 1.05 % | 3.20 % |
| A2 bento anchored | 1080 | 0 | 0.48 % / 26.87 % / 69.68 % | 0.12 % / 25.00 % | 1.08 % | 3.19 % |
| B justified rows | 1080 | 18 | 0.02 % / 3.12 % / 16.37 % | 0.00 % / 50.00 % | 0.00 % | 1.21 % |
| C squarified treemap | 1080 | 0 | 0.00 % / 0.00 % / 0.00 % | 0.00 % / 0.00 % | 99.99 % | 99.96 % |

Coverage: **100.00 % in every case for every packer**, with 0 overlaps and 0 out-of-bounds tiles
for the grid packers. B had 18 "no solution" cases, all with N = 4 or 12 (the DP cannot reach the
count and height together). C covers the canvas by construction but almost no tile has the source
aspect.

### 10.3 By frame count (the effect of granularity)

| N | A1 canvas aspect error: median / p95 / max | A1 tile-count error: median / p95 | B canvas aspect error: median / p95 / max | B tile-count error: median / p95 | Baseline `.custom` canvas error: median / p95 | Baseline `.custom` count error: median / p95 |
|---|---|---|---|---|---|---|
| 4 | 21.04 % / 68.96 % / 69.68 % | 0.00 % / 50.00 % | 1.54 % / 5.00 % / 16.37 % | 25.00 % / 150.00 % | 15.33 % / 40.93 % | 0.00 % / 150.00 % |
| 12 | 4.99 % / 24.95 % / 24.99 % | 8.33 % / 33.33 % | 0.43 % / 1.92 % / 3.50 % | 8.33 % / 41.67 % | 6.94 % / 47.90 % | 50.00 % / 125.00 % |
| 30 | 1.63 % / 6.69 % / 6.76 % | 3.33 % / 20.00 % | 0.09 % / 0.33 % / 0.72 % | 3.33 % / 30.00 % | 7.35 % / 45.13 % | 26.67 % / 103.33 % |
| 107 | 0.25 % / 1.61 % / 1.68 % | 0.93 % / 0.93 % | 0.00 % / 0.02 % / 0.03 % | 0.00 % / 6.54 % | 4.50 % / 11.97 % | 4.67 % / 38.32 % |
| 400 | 0.10 % / 0.54 % / 1.08 % | 0.00 % / 0.25 % | 0.00 % / 0.02 % / 0.02 % | 0.00 % / 0.00 % | 1.54 % / 6.99 % | 8.00 % / 15.00 % |
| 800 | 0.04 % / 0.71 % / 1.32 % | 0.12 % / 0.12 % | 0.00 % / 0.02 % / 0.02 % | 0.00 % / 0.00 % | 1.44 % / 6.06 % | 5.00 % / 16.25 % |

The bento grid is at its best from about 100 frames up (density M and denser) and degrades
gracefully below; under 12 frames the existing layouts are as bad or worse, which is why §8
case 2 falls back to classic.

### 10.4 By target aspect, source aspect, width and x (N ≥ 30, A1 vs B)

| Slice | A1 canvas aspect error: median / p95 | A1 tiles > 2 % off aspect | B canvas aspect error: median / p95 | B tiles > 2 % off aspect |
|---|---|---|---|---|
| Target 16:9 | 0.09 % / 3.00 % | 2.96 % | 0.00 % / 0.14 % | 1.31 % |
| Target 4:3 | 0.07 % / 5.58 % | 2.55 % | 0.00 % / 0.20 % | 1.06 % |
| Target 1:1 | 0.08 % / 6.71 % | 1.13 % | 0.00 % / 0.16 % | 0.08 % |
| Target 21:9 | 0.47 % / 3.34 % | 9.32 % | 0.02 % / 0.17 % | 3.63 % |
| Target 9:16 | 0.41 % / 3.65 % | 0.21 % | 0.01 % / 0.23 % | 0.07 % |
| Width 2000 px | 0.15 % / 3.54 % | 9.72 % | 0.01 % / 0.15 % | 3.69 % |
| Width 5120 px | 0.17 % / 3.65 % | 0.00 % | 0.00 % / 0.21 % | 0.00 % |
| Width 10000 px | 0.17 % / 3.67 % | 0.00 % | 0.00 % / 0.19 % | 0.00 % |
| x = 2 | 0.10 % / 3.54 % | 2.88 % | 0.00 % / 0.33 % | 0.96 % |
| x = 3 | 0.16 % / 3.54 % | 3.07 % | 0.00 % / 0.18 % | 1.02 % |
| x = 4 | 0.16 % / 3.54 % | 3.52 % | 0.00 % / 0.16 % | 1.38 % |
| x = 5 | 0.16 % / 3.54 % | 3.50 % | 0.00 % / 0.15 % | 1.56 % |

All "off aspect" tiles come from narrow tiles: 10.5 % of tiles under 100 px wide, 0.07 % of tiles
100–200 px, 0 % above 200 px (pixel rounding, not layout error). Size classes: A1 delivered every
class the grid allowed (`classes == x_eff` in 100 % of N ≥ 30 cases, `== x` in 62–97 %, lower for
large `x` on small grids). B reached a largest/smallest ratio of at least 0.9·`x` in only 56 %
(x = 2), 33 % (3), 16 % (4) and 8 % (5) of cases.

### 10.5 Gutter models, grid window, seeds, hero balance

| Check | Result |
|---|---|
| Gutter models (A1, width 5120; table in §4.5) | Aspect-matched: 1.0 % of tiles stretched > 2 px. Uniform: 10.9 %. Inset by half a gutter: 74 % |
| Grid window around the ideal cell count | ±10 %: canvas error median 0.51 % / p95 11.4 %. ±20 %: 0.35 % / 3.3 %. ±35 % and ±50 %: 0.33 % / 3.0 % |
| Seeds (A1, 16:9/9:16 sources, 5 targets, N = 30/107/400, x = 3–4) | 1 seed: mean third-of-canvas deviation 0.150, quota miss 2.3 %. 8 seeds: 0.122, 0.5 %. 16: 0.115. 32: 0.113 |
| Hero balance, A1 vs A2 (N ≥ 30) | Worst third-of-canvas deviation from 1/3: 0.104 vs 0.120 mean (both 0.333 p95: a handful of heroes cannot cover three thirds). Left/right–top/bottom imbalance 0.113 vs 0.148. Edge-sharing hero pairs per tile 0.081 vs 0.094. Quota missed 0.29 % vs 0.00 % |
| Hero columns | The M example (§4.2) has no 3×3 tile in columns 4–8 or the bottom right, so balance is "good, not perfect" and the score is the tuning knob |

### 10.6 Swift run time (A1, 8 seeds, `-O`, M1 Pro, mean of 200 runs)

| Case | Grid | Tiles | Time |
|---|---|---|---|
| N 26, x 2 (XXL) | 6×6 | 27 | 0.06 ms |
| N 107, x 3 (M) | 13×13 | 107 | 0.16 ms |
| N 107, x 3, target 21:9 | 16×12 | 108 | 0.14 ms |
| N 107, x 3, 9:16 source | 22×7 | 106 | 0.13 ms |
| N 429, x 5 (XXS) | 27×27 | 429 | 0.66 ms |
| N 800, x 5 | 36×36 | 799 | 1.4 ms |
| N 2000, x 5 | 58×58 | 1999 | 3.8 ms |
| N 5000, x 6 | 92×92 | 5001 | 12.4 ms |

The Python and Swift versions produced identical tile lists in all 5 compared cases. The pipeline
spends ≈ 1 s or more per mosaic on decoding, so the packer is negligible, and the processor's
lock is held for well under 2 ms for any frame count the library itself can request (cap 800).

### 10.7 Decode and label cost per frame size (macOS, measured)

Three real clips on this Mac (1280×720, 1920×1080, 2688×1512 sources); 40 frames, 3 repeats.

| `maximumSize` | Decode ms/frame (all three clips) | Label-style CPU draw ms/frame (720p / 1080p / 1512p clip) |
|---|---|---|
| 390×219 (unit tile at M) | 10.7 / 11.3 / 11.6 | 0.8 / 1.4 / 1.2 |
| 780×438 (2×2) | 10.6 / 9.7 / 10.2 | 2.7 / 3.2 / 3.3 |
| 1178×666 (3×3) | 10.6 / 9.6 / 10.2 | 6.1 / 6.6 / 6.8 |
| 1920×1080 | 10.7 / 9.7 / 10.6 | 7.1 / 16.6 / 16.6 |

Decode time does not depend on `maximumSize`; the CPU label work does. The full pipeline was not
benchmarked here (no `Sources/` changes in this spec).

---

## 11. Test plan and performance gates

**Pure-geometry property tests** (Swift Testing, no media, microseconds each; the total packer
matrix of 200 cases should take about 40 ms in Swift, estimated from the 0.2 ms mean):

| Property | Check |
|---|---|
| Exact coverage | Cell occupancy grid: every unit cell covered exactly once; sum of `k²` equals `C·R` |
| No overlap, inside canvas | Pairwise (or occupancy) check on pixel rects; every rect inside `[0, W] × [0, H]`; gutters between neighbours equal `g` horizontally (±0) and the aspect-matched value ±1 px vertically |
| Source aspect preserved | `abs(w − h·a) ≤ 1.5` px for every tile (aspect-matched gutter); with the uniform gutter model the bound is `(k−1)·g·|1 − 1/a|` plus rounding |
| Counts | `thumbCount == positions.count == thumbnailSizes.count`; `abs(tiles − N) ≤ 2` for N ≥ 30 unless a cap bound; `x_eff` classes all present when `x_eff ≥ 2` |
| Size classes | Largest tile = `x_eff` × unit tile (±2 px); no span above `x_eff` |
| Canvas aspect | `abs(W/H / A − 1) ≤ 2 %` for N ≥ 100 over the matrix; the documented worst cases are asserted with their known values, not hidden |
| Determinism | Same inputs twice give equal tile lists; **golden layouts** pinned as literal arrays for 4 cases (M 16:9, XXL 16:9, XXS 21:9, 9:16 source) so any algorithm change is deliberate |
| Reading order | Tiles sorted by `(row, col)`; first tile at `(0, 0)` |
| Limits | Height never above `16384 − reserve`; unit width ≥ 120 px; N = 100,000 clamps and returns in < 50 ms |
| Fallbacks | N < 12, extreme source aspect and unsupported targets return a valid classic layout and do not crash |
| Codable | `LayoutType.uneven` round-trips; a config with `"layoutType": "uneven"` decodes; `allCases` contains it; pinned legacy payloads still decode (do not edit them) |
| Identity | `configurationHash` ends in `_uneven`; existing layouts' hashes and cache keys are unchanged |
| `.dynamic` guard | A switch over every `LayoutType` in `LayoutProcessor` has no `default:` that hides `.uneven` (compile-time via an exhaustive switch) |

**One end-to-end test** with the embedded 87 s fixture: `MosaicConfiguration(width: 1200, density: .xxl, layout: .uneven)` through `generateMosaicImage` (in memory, no encode), asserting the image size equals the layout size plus header and that every tile index was composed ("Missing mosaic frames" cannot occur). Budget: ≤ 3 s on macOS and ≤ 10 s on the iOS Simulator; no animated export, so it does not touch the nightly-only tests.

**Gates** (plan conventions: ⚡ = A/B/A benchmark, 📁 = output naming):

| Gate | Threshold |
|---|---|
| Packer speed | ≤ 5 ms at N = 800, ≤ 20 ms at N = 5000 (measured 1.4 / 12.4 ms) |
| ⚡ Existing layouts | A/B/A benchmark of `.custom` and `.classic` at 5120 M and 10000 XS within ±5 % of the baseline whenever the shared extraction code changes (U-3) |
| ⚡ New layout | Same N, same machine: `.uneven` M 5120 median ≤ 1.15 × `.custom` M 5120 median, and no higher peak RSS than `.custom` by more than 10 % |
| Quality | Visual comparison of 3×3 tiles decoded at tile size vs at hero size (aliasing) recorded in the U-3 PR |
| CI | Both platforms green; iOS suite time not above today's ≈ 4 min plus the end-to-end test |
| 📁 | None: new layout, new hash, no existing output moves. A README "Unreleased" entry still lists the new `LayoutType` and the decode-compat note |

---

## 12. Open questions

Each has a recommendation; none blocks U-1.

| # | Question | Recommendation |
|---|---|---|
| Q-U1 | Name and persisted raw value: `uneven` or `bento`? | `uneven`. One lowercase word like the others, names the property, survives a change of algorithm. The raw value is forever. |
| Q-U2 | Default `x` per density (2,2,3,3,4,4,5), hero-area share β = 0.45, and the hero limit `⌊min(C,R)/2⌋` or the gentler `⌊min(C,R)/3⌋`? | Ship the measured table and `/2`. Review real thumbnails of M and XXS before U-2 merges; the limits are constants. |
| Q-U3 | Gutter model: aspect-matched (vertical gap 2–3 px beside 4 px horizontal) or uniform 4 px with ≤ 2 % hero stretch? | Aspect-matched, because the invariant "no distorted frame" becomes exact. Switch to uniform only if the unequal gaps look wrong. |
| Q-U4 | When the bento grid misses the target aspect by more than 2–3 % (small N, odd aspect pairs), accept the miss, letterbox, or fall back to justified rows (B)? | Accept in v1 (the generator already snaps the aspect; the existing `.custom` misses by 2.6 % median). Revisit B as `LayoutType.uneven` variant in U-5 if users complain. |
| Q-U5 | Below 12 frames: classic fallback or a uniform grid from the same packer? | Classic fallback, reusing tested code and its own aspect handling. |
| Q-U6 | Is per-size frame extraction (U-3) a release blocker? | Yes for `x ≥ 3`. Until then cap `x` at 2 (a 2× shrink aliases far less, as `.custom` already does). |
| Q-U7 | Output identity when the packer improves later | Freeze it after release; golden layouts in tests; improvements ship behind an `algorithmRevision` option that joins the hash when non-default. |
| Q-U8 | Content-driven hero frames (scheme T) | Defer to U-5, opt-in, positional by default; document that scores can vary across devices. |
| Q-U9 | `thumbnailSize` meaning (unit tile vs mean tile) | Unit tile; header and overlay padding already key off the smallest tile. |
| Q-U10 | Make `renderRect`'s spacing inset aspect-proportional for all layouts (today `spacing ≠ 4` stretches small tiles by ~2 %)? | Separate small PR, not part of this feature; it changes pixels of existing layouts slightly. |
| Q-U11 | Release train | After 1.10.0 (F-4 and F-5 are postponed; 1.10.0 is being prepared). Propose 1.11.0 for U-1 to U-3 so ⚡ gates are not squeezed into the 1.10.0 window. |

---

## 13. Phased implementation plan

Same style as `IMPLEMENTATION_PLAN.md`: one PR per row; update the knowledge base (F4 section,
§4.2 if an issue is found, §5.2 API, §6.1 roadmap), run
`python3 codebase-analysis-docs/assets/doc_check.py`, and add the row to the plan's §8 table.

| ID | PR | Contents | Gate | Size |
|---|---|---|---|---|
| U-1 | **Packer core** (internal, no public API) | `UnevenTilePacker` (pure, `Sendable`, deterministic): size-mix solver, grid choice, skyline with seeds, geometry with the aspect-matched gutter and caps (120 px floor, 16384 limit), N clamp. All property tests and golden layouts from §11. No pipeline wiring. | CI (both platforms) | ~350 lines + tests |
| U-2 | **`LayoutType.uneven`** | New case and `allCases`; explicit `case .uneven` in `LayoutProcessor.calculateLayout` (remove the silent `default:`); fallbacks (N < 12, extreme aspect); cache key; density → `x` table; Codable and identity tests; one end-to-end test; README, DocC `LayoutAlgorithms`, knowledge base F4/§5.2/§5.6. `x` capped at 2 until U-3 (Q-U6). | CI + README "Unreleased" | ~150 lines + docs |
| U-3 | **Per-size frame extraction** ⚡ | `ThumbnailProcessor` creates one `AVAssetImageGenerator` per distinct tile size with its own `maximumSize`; indices preserved, labels use the tile size; lift the `x` cap to the density table. A/B/A against the baseline and `.custom`; visual aliasing check. Applies to every layout (for `.custom` the classes are 2). | CI + benchmark | ~120 lines |
| U-4 | *(optional)* **Options** | `UnevenTilesOptions` (`maxSpan`, `gutter`); `decodeIfPresent`; `MissingKeyDefault`; validation; hash suffix only when non-default; tests incl. pinned-payload decode. | CI | ~100 lines |
| U-5 | *(optional, Wave 5)* **Hero emphasis and fallback variant** | Opt-in scheme T (time-nudged hero frames with aesthetics or saliency, feature-print spacing); optionally justified-rows variant B for aspect misses. Decide after real-world use of U-2/U-3. | CI + benchmark | TBD |

Suggested order: U-1 → U-2 (capped) → U-3 → release; U-4 and U-5 on demand.

### Decision log entries to add when work starts

| # | Context | Decision | Type | Rationale |
|---|---|---|---|---|
| A-U1 | This spec | Interpret "sizes 1 to x" as integer linear spans of a source-aspect unit cell | Two-way until shipped (raw value persists after) | Only integer spans keep the source aspect exactly and tile a grid |
| A-U2 | This spec | Bento skyline (A1) first; justified rows (B) kept as a fallback variant | Two-way | A1 measured quality and 100 % exact coverage; B only wins on canvas aspect |
| A-U3 | This spec | New layout type instead of an option on `.custom` | One-way once shipped (raw value) | `.custom` output must not change (rule 4) |
