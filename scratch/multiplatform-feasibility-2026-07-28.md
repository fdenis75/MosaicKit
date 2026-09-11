# Multiplatform Feasibility — MosaicKit (2026-07-28)

## The ask

Evaluate making MosaicKit fully multiplatform: desktop (macOS/Linux/Windows) *and*
mobile (iOS/Android), ideally as one package in one language, with a small API
surface and performance as the top priority.

## Bottom line up front

**Hard no on "one Swift package, unmodified, native performance, across
macOS + Linux + Windows + iOS + Android."** That specific combination isn't
buildable from what exists today without abandoning the two things you said
matter most (small surface, performance). What *is* feasible is described in
"What I'd actually do" below — it's a smaller, less exciting scope than "fully
multiplatform," and I think that's the right trade.

## How coupled is the codebase to Apple, really?

Checked directly, not estimated:

| Framework | Files importing it | Apple-exclusive? |
|---|---|---|
| `AVFoundation` | 10 | Yes — no Linux/Windows/Android equivalent |
| `CoreGraphics` | 12 | Yes |
| `AppKit`/`UIKit` | 8 + 8 (mutually exclusive `#if`) | Yes (both are) |
| `Metal`/`MetalKit` | 4 | Yes |
| `CoreImage` | 4 | Yes |
| `ImageIO` | 3 | Yes |
| `VideoToolbox`, `CoreVideo`, `CoreMedia`, `CoreText`, `Vision` | 1 each | Yes |

23 of the package's 28 Swift files (82%) import at least one Apple-only
framework. This isn't UI chrome that can be swapped behind an `#if
canImport(AppKit)/#elseif canImport(UIKit)` shim (the package already does
that, and it's the *only* real platform abstraction in the codebase — both
branches are still Apple frameworks). The coupling is in the engine itself:

- **Decode**: `AVAssetImageGenerator` (`ThumbnailProcessor.swift`) — hardware
  frame extraction backed by VideoToolbox. No substitute exists outside
  Apple's stack; the nearest equivalent anywhere else is FFmpeg's
  `libavcodec`, a different library with different semantics.
- **GPU compositing**: hand-written Metal compute shaders
  (`Shaders/MetalShaders.metal`, dispatched from `MetalImageProcessor.swift`,
  36 references to `MTLTexture`/command-encoder APIs). Metal Shading Language
  doesn't run on non-Apple GPUs.
- **Export/transcode**: `AVAssetExportSession` and `SJSAssetExportSession`
  (itself an `AVFoundation` wrapper) for `.native`/`.sjs` preview export
  modes — Apple-only by construction.
- **Image codecs**: `ImageIO` for HEIF/JPEG/PNG encode, `CoreImage` for
  filtering, `DominantColors` (background-color extraction) is itself built
  on `CoreImage`.
- **Return types in the public protocol are Apple types**:
  `MosaicGeneratorProtocol.generateMosaicImage(...) -> CGImage`
  (`Sources/Processing/MosaicGeneratorProtocol.swift:25`). Even the API
  contract, not just the implementation, is Apple-typed.
- **Dependencies are Apple-only or Apple-flavored**: `SJSAssetExportSession`
  wraps `AVFoundation`; `libwebp-ios` (the actual pin, per
  `Package.resolved`) is an Apple-platform build of libwebp, not the
  portable library itself.

There is no cross-platform image/video abstraction anywhere to build on —
not even a partial one. `Package.swift` restricts platforms to
`.macOS(.v26), .iOS(.v26), .macCatalyst(.v26)`; Linux, Windows, and Android
aren't declared and the code wouldn't compile there (no `CoreGraphics`, no
`AVFoundation`, no `Metal` on any of those platforms — swift-corelibs-foundation
doesn't provide them and never will, they're not part of Swift's portable
surface).

## Language question: is a single unified package possible?

**Not as Swift, if "fully multiplatform" includes Linux/Windows/Android at
native performance.** Swift-the-language runs on Linux and Windows today
(official toolchains), and Android support exists via the Swift Android
Working Group — but that buys you the *language*, not the *engine*. None of
AVFoundation, VideoToolbox, Metal, CoreImage, or ImageIO exist off Apple
platforms in any form, official or unofficial. Porting the language doesn't
port the frameworks the package is built on. You'd still need to replace
every one of decode, GPU compute, and codec layers with something that runs
everywhere — at which point the "single Swift package" framing is really
"rewrite everything except the models/config structs, then re-glue it under
Swift's syntax."

If the actual goal is "single codebase across 5 platforms, GPU-accelerated,
native performance," the language that currently earns that combination is
**Rust**, via:
- `ffmpeg-next` (or raw FFI to `libav*`) for decode/demux/encode — runs on
  every target here, including Android via NDK.
- `wgpu` for GPU compute — one shader language (WGSL), compiles down to
  Metal on macOS/iOS, Vulkan on Linux/Android, D3D12 on Windows. This is the
  closest thing to "Metal, but portable" that exists.
- A thin C ABI (or UniFFI) boundary so each platform's native shell — Swift
  on Apple, Kotlin on Android, C#/C++ on Windows — calls into one shared
  core.

That's a legitimate, well-precedented architecture (it's how a lot of
cross-platform media/editing tools are built today). It is **not** "port
MosaicKit" — it's a new project that happens to reuse MosaicKit's
domain knowledge (layout algorithms, density heuristics, overlay config)
while discarding essentially 100% of the current implementation.

## Video/image handling across platforms, concretely

Two real options, not a spectrum of many:

1. **Shell out to `ffmpeg`.** The package already does exactly this for
   `PreviewExportMode.ffmpeg` on macOS (`FFmpegEncoder.swift`) — passthrough
   export to a temp file, then an external `ffmpeg` binary transcodes it.
   `ffmpeg` itself is genuinely cross-platform (macOS/Linux/Windows/Android
   builds all exist) and mosaic/contact-sheet generation is a standard
   `ffmpeg` use case (`select`, `scale`, `tile` filters can produce a grid
   directly, no custom compositor needed). This is the *only* path that
   reuses anything already in the codebase.
   License note: default `ffmpeg` builds bundle LGPL and optionally GPL
   codecs (x264/x265); an LGPL-only build avoids copyleft obligations but
   drops H.264/H.265 encode unless the system ffmpeg supplies it — same
   constraint the package already lives with today, just now load-bearing
   for every platform instead of one export mode.
2. **Rewrite the engine on native libraries per capability**: FFmpeg for
   decode, `wgpu`/Vulkan/D3D12 for GPU compositing, `libheif` +
   `libjpeg-turbo` + `libpng` + `libwebp` (the real library, not the -ios
   build) for codecs. This is the Rust-core architecture above. Full
   feature parity (custom layouts, dominant-color backgrounds, overlays,
   animated export, cancellation model) — 6-12+ months for a small team,
   optimistically, and a permanent second engine to maintain forever after.

Option 1 is cheap and real but caps out at "ffmpeg CLI can do it" — custom
layout algorithms and Metal-shader-specific effects don't transfer, you're
driving `ffmpeg` as a black box, not reusing MosaicKit's compositor.
Cancellation and progress reporting *do* transfer, though: `FFmpegEncoder`
(`Sources/Processing/Preview/FFmpegEncoder.swift`) already drives an
`ffmpeg` subprocess with a `progressHandler`/`cancellationCheck` pair,
parses `time=` output for progress, and calls `terminate()` on the process
when cancellation is requested — that control-plane pattern is exactly what
an ffmpeg-backed mosaic path would reuse. Option 2 is the only way to keep
today's *compositing* feature set (custom layouts, overlays, dominant-color
backgrounds) and control, at rewrite cost.

## Existing solutions worth knowing about (none solve this for free)

- **FFmpeg** — see above; the pragmatic fallback, not a drop-in replacement.
- **Skia** (Google, C++, used by Chrome/Flutter/Android) — cross-platform
  2D compositor, could replace `CoreGraphics`/`CoreText` for the overlay
  layer, has bindings in several languages. Doesn't touch video decode or
  GPU-shader-level image processing.
- **wgpu / Vulkan / bgfx** — cross-platform GPU compute, the real
  replacement for the Metal shader layer. Different shader language (WGSL/
  SPIR-V vs MSL), different mental model from `MetalImageProcessor.swift`.
- **Kotlin Multiplatform** — if the team would rather stay closer to Swift's
  ergonomics than Rust's, KMP + `expect`/`actual` + native FFmpeg bindings
  per platform is the other credible "one codebase" contender. Same
  fundamental shape as the Rust option: new engine, Apple gets a
  non-native-feeling wrapper instead of Metal/AVFoundation.
- **MetalPetal / GPUImage** — don't help; both are Metal-based, Apple-only.
- Nothing exists that gives you AVFoundation/VideoToolbox/Metal-equivalent
  hardware integration on Linux, Windows, *or* Android in one shared
  library. If it existed, this wouldn't be a hard question.

## Why performance and a small API argue *against* chasing this

You listed performance as the top priority and a small API surface as a
hard constraint. Both cut against multiplatform, not for it:

- The package's speed today comes from being tightly wedded to Apple's
  stack: `AVAssetImageGenerator`'s hardware decode path and GPU compute
  shaders written and tuned for Apple Silicon specifically. Worth being
  precise here: the actual CGImage-to-Metal handoff in
  `MetalImageProcessor.createTexture(from: CGImage)` currently draws each
  frame into a `CGContext` and uploads it with `texture.replace` — a copy,
  not zero-copy. A genuinely zero-copy `createTexture(from: CVPixelBuffer)`
  overload backed by `CVMetalTextureCache` already exists in the same file
  but has no callers in the generation path today. That's real headroom
  left on the table on the *current* Apple-only engine, and it cuts the
  other way on one point: it means "the existing path is already
  maximally fast" is not quite true either. What still holds is the
  structural argument — a cross-platform abstraction has to satisfy the
  least-capable backend (no VideoToolbox, no Metal, no MTLTexture cache
  equivalent), so closing MosaicKit's own zero-copy gap stays cheaper and
  more valuable than building a portable layer underneath it.
- A shared engine forces a choice: flatten the API to the lowest common
  denominator (lose overlay/layout capabilities that don't map cleanly to
  `ffmpeg` filters or a generic GPU backend), or grow the API to expose
  per-backend capability flags (`supportsHardwareDecode`,
  `supportsGPUCompositing`, ...) — which is exactly the "tentacular"
  surface you're trying to avoid.
- Maintaining two engines (Apple-native + portable) behind one protocol
  means every new feature gets built and tested twice, or the portable
  backend silently lags — a slow drift toward the API surface describing
  capabilities that aren't uniformly true, which is worse than a smaller,
  honest API.

## What I'd actually do

1. **Ship Apple-only, as today, and don't call it a limitation.**
   macOS + iOS + macCatalyst already covers "desktop and mobile" for the
   platform family where this package's performance advantage is real.
   If there's appetite for more Apple surface, iPadOS/visionOS support is a
   near-zero-cost extension of what exists — that's the actual low-hanging
   "more platforms" fruit here, not Linux/Windows/Android.
2. **If Linux/Windows desktop is a genuine, named requirement** (not
   "fully multiplatform" as an abstract goal): add a second, separate,
   small product/target that drives the `ffmpeg` binary directly using its
   `tile`/`select`/`scale` filters, following the exact pattern
   `FFmpegEncoder.swift` already establishes for preview export. Keep it
   out of the Metal engine's protocol entirely — a distinct, minimal API
   (`generateMosaicViaFFmpeg(...)`), explicitly lower-fidelity and
   lower-performance, not a conformance to `MosaicGeneratorProtocol`. This
   is days-to-weeks of work, not months, because it reuses an established
   pattern and offloads all the hard parts to `ffmpeg` itself.
3. **Treat Android as out of scope**, full stop. Swift-on-Android isn't
   production-grade, and even if it were, none of the frameworks this
   package depends on exist there. If Android is ever a hard requirement,
   it's a from-scratch Kotlin/JNI project against FFmpeg — not something
   that can share code with MosaicKit, so it shouldn't be scoped as "make
   MosaicKit multiplatform," it should be scoped as "build a second,
   unrelated library."
4. **Don't build the Rust-core rewrite** unless Linux/Windows/Android
   support is a committed product requirement backed by real demand, not a
   hypothetical. It's the only path to true feature-parity multiplatform,
   and it's a new multi-month-to-multi-year project, not an evolution of
   this repository — budget and staff it as such, separately, if it's ever
   greenlit.

No code changes made — this is the requested feasibility analysis. Filed as
a scratch report per repo convention (see `scratch/audit-*-2026-05-10.md`
for prior examples of this format).
