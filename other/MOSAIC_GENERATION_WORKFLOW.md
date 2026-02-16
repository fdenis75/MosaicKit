# Mosaic Generation Workflow Visualization

This document provides visual workflow diagrams for the MosaicKit mosaic generation process.

## High-Level Overview

```mermaid
flowchart TD
    A[User calls generate] --> B[MosaicGenerator Initialization]
    B --> C{Platform Detection}
    C -->|macOS| D[MetalMosaicGenerator]
    C -->|iOS| E[CoreGraphicsMosaicGenerator]

    D --> F[Common Generation Pipeline]
    E --> F

    F --> G[Calculate Layout]
    G --> H[Extract Frames]
    H --> I[Create Metadata Header]
    I --> J{Platform-Specific Composition}

    J -->|macOS| K[Metal GPU Processing]
    J -->|iOS| L[Core Graphics + vImage]

    K --> M[Save Mosaic]
    L --> M
    M --> N[Return URL]

    style A fill:#e1f5ff
    style N fill:#d4edda
    style D fill:#fff3cd
    style E fill:#fff3cd
    style K fill:#f8d7da
    style L fill:#f8d7da
```

## Detailed Generation Pipeline

```mermaid
flowchart TD
    Start([generate called]) --> Init[Initialize Task<br/>UUID, Progress Handler]

    Init --> CalcCount[Calculate Thumbnail Count<br/>Based on duration, width, density]
    CalcCount --> CountFormula["Formula: base + k × log(duration) × density<br/>Range: 4-800 frames"]

    CountFormula --> CalcLayout[Calculate Optimal Layout]
    CalcLayout --> LayoutChoice{Layout Type?}

    LayoutChoice -->|Custom| Custom3Zone[3-Zone Layout<br/>Small/Large/Small]
    LayoutChoice -->|Classic| ClassicGrid[Classic Grid Layout]
    LayoutChoice -->|Auto| AutoScreen[Screen-Aware Layout]
    LayoutChoice -->|Dynamic| DynamicCenter[Center-Emphasized Layout]
    LayoutChoice -->|iPhone| iPhoneVert[iPhone Vertical Scroll]

    Custom3Zone --> LayoutResult[MosaicLayout<br/>rows, cols, positions, sizes]
    ClassicGrid --> LayoutResult
    AutoScreen --> LayoutResult
    DynamicCenter --> LayoutResult
    iPhoneVert --> LayoutResult

    LayoutResult --> ExtractFrames[Extract Video Frames]
    ExtractFrames --> FrameExtraction

    subgraph FrameExtraction[Frame Extraction Details]
        FE1[Calculate Extraction Times<br/>Biased Distribution] --> FE2[First 1/3: 20% of frames<br/>Middle 1/3: 60% of frames<br/>Last 1/3: 20% of frames]
        FE2 --> FE3[AVAssetImageGenerator<br/>VideoToolbox Acceleration]
        FE3 --> FE4{Concurrent Extraction<br/>up to 16 parallel}
        FE4 --> FE5[Primary Pass]
        FE5 --> FE6{All frames<br/>successful?}
        FE6 -->|No| FE7[Retry Failed Frames]
        FE6 -->|Yes| FE8[Add Timestamp Overlays]
        FE7 --> FE9{Still failed?}
        FE9 -->|Yes| FE10[Use Blank Images]
        FE9 -->|No| FE8
        FE10 --> FE8
    end

    FE8 --> MetadataCheck{Include<br/>Metadata?}
    MetadataCheck -->|Yes| CreateHeader[Create Metadata Header<br/>Video info, dimensions, config]
    MetadataCheck -->|No| ComposeStart
    CreateHeader --> ComposeStart[Start Mosaic Composition]

    ComposeStart --> PlatformSwitch{Platform?}

    style Start fill:#e1f5ff
    style LayoutResult fill:#d4edda
    style FE8 fill:#d4edda
    style ComposeStart fill:#fff3cd
```

## Platform-Specific Composition: Metal (macOS)

```mermaid
flowchart TD
    Start([Metal Composition]) --> CreateBG{Create Background}

    CreateBG -->|iPhone Mode| BG1[Light Grey Background<br/>RGB 0.5, 0.5, 0.5]
    CreateBG -->|Standard Mode| BG2[Extract Dominant Colors<br/>from all frames]

    BG2 --> BG3[Create Gradient<br/>from dominant colors]
    BG3 --> BG4[Apply 12px Gaussian Blur]
    BG4 --> BG5[Convert to MTLTexture]

    BG1 --> BaseTexture[Base Mosaic MTLTexture]
    BG5 --> BaseTexture

    BaseTexture --> HeaderCheck{Metadata<br/>Header?}
    HeaderCheck -->|Yes| AddHeader[Composite Header at top<br/>GPU blend operation]
    HeaderCheck -->|No| StartBatch
    AddHeader --> AdjustY[Adjust frame Y positions<br/>to account for header]
    AdjustY --> StartBatch[Start Frame Batching]

    StartBatch --> BatchLoop[Process 200 frames per batch]

    BatchLoop --> CreateCmdBuf[Create Command Buffer]
    CreateCmdBuf --> FrameLoop{For each frame<br/>in batch}

    FrameLoop --> F1[Convert CGImage → MTLTexture]
    F1 --> F2{Scaling<br/>needed?}

    F2 -->|Yes| F3[Scale Texture<br/>GPU compute shader<br/>Bilinear/Trilinear filtering]
    F2 -->|No| F4[Use original texture]
    F3 --> F5[Composite onto Mosaic<br/>GPU compute shader<br/>Alpha-blended composition]
    F4 --> F5

    F5 --> F6{More frames<br/>in batch?}
    F6 -->|Yes| FrameLoop
    F6 -->|No| CommitBatch[Commit Command Buffer<br/>Await GPU completion]

    CommitBatch --> MoreBatches{More batches?}
    MoreBatches -->|Yes| BatchLoop
    MoreBatches -->|No| ConvertCG[Convert MTLTexture → CGImage]

    ConvertCG --> SaveStart([Proceed to Save])

    style Start fill:#fff3cd
    style BaseTexture fill:#d4edda
    style ConvertCG fill:#d4edda
    style SaveStart fill:#e1f5ff
```

## Platform-Specific Composition: Core Graphics (iOS)

```mermaid
flowchart TD
    Start([Core Graphics Composition]) --> CreateBG{Create Background}

    CreateBG -->|iPhone Mode| BG1[Light Grey Background<br/>CGContext fill]
    CreateBG -->|Standard Mode| BG2[Extract Dominant Colors<br/>from all frames]

    BG2 --> BG3[Create Gradient<br/>CIFilter radialGradient]
    BG3 --> BG4[Apply 12px Gaussian Blur<br/>CIFilter gaussianBlur]
    BG4 --> BG5[Render to CGImage]

    BG1 --> BaseImage[Base Mosaic CGImage]
    BG5 --> BaseImage

    BaseImage --> HeaderCheck{Metadata<br/>Header?}
    HeaderCheck -->|Yes| AddHeader[Composite Header at top<br/>CGContext.draw]
    HeaderCheck -->|No| StartBatch
    AddHeader --> AdjustY[Adjust frame Y positions<br/>to account for header]
    AdjustY --> StartBatch[Start Frame Batching]

    StartBatch --> BatchLoop[Process 20 frames per batch<br/>CPU-based smaller batches]

    BatchLoop --> FrameLoop{For each frame<br/>in batch}

    FrameLoop --> F1{Scaling<br/>needed?}

    F1 -->|Yes| F2[Scale Image<br/>vImageScale_ARGB8888<br/>Accelerate framework<br/>Lanczos filtering]
    F1 -->|No| F3[Use original image]

    F2 --> F4[Composite onto Mosaic<br/>CGContext.draw<br/>Hardware-accelerated blending]
    F3 --> F4

    F4 --> F5{More frames<br/>in batch?}
    F5 -->|Yes| FrameLoop
    F5 -->|No| BatchDone[Batch Complete]

    BatchDone --> MoreBatches{More batches?}
    MoreBatches -->|Yes| BatchLoop
    MoreBatches -->|No| FinalImage[Final CGImage Complete]

    FinalImage --> SaveStart([Proceed to Save])

    style Start fill:#fff3cd
    style BaseImage fill:#d4edda
    style FinalImage fill:#d4edda
    style SaveStart fill:#e1f5ff
```

## Save & Finalization

```mermaid
flowchart TD
    Start([Save Mosaic]) --> DetermineDir[Determine Output Directory]

    DetermineDir --> DirStructure["Structure:<br/>{root}/{service}/{creator}/{config}/"]
    DirStructure --> CreateDirs[Create directories if needed]

    CreateDirs --> GenFilename[Generate Filename]
    GenFilename --> FilenamePattern["{original}_{width}_{density}_{aspect}_{timestamp}.{ext}"]

    FilenamePattern --> ConvertPlatform{Platform?}
    ConvertPlatform -->|macOS| ToNSImage[Convert CGImage → NSImage]
    ConvertPlatform -->|iOS| ToUIImage[Convert CGImage → UIImage]

    ToNSImage --> EncodeFormat
    ToUIImage --> EncodeFormat

    EncodeFormat{Output Format?}

    EncodeFormat -->|JPEG| EncodeJPEG[JPEG encoding<br/>with quality setting<br/>0.0-1.0]
    EncodeFormat -->|PNG| EncodePNG[PNG encoding<br/>lossless]
    EncodeFormat -->|HEIF| EncodeHEIF[HEIF encoding<br/>CGImageDestination<br/>balanced size/quality]

    EncodeJPEG --> WriteToDisk[Write Data to Disk]
    EncodePNG --> WriteToDisk
    EncodeHEIF --> WriteToDisk

    WriteToDisk --> UpdateProgress[Update Progress: 100%<br/>Status: complete]
    UpdateProgress --> ReturnURL([Return File URL])

    style Start fill:#e1f5ff
    style ReturnURL fill:#d4edda
```

## Progress Tracking Throughout Pipeline

```mermaid
gantt
    title Mosaic Generation Progress Timeline
    dateFormat X
    axisFormat %s%%

    section Initialization
    Count Thumbnails    :0, 0

    section Layout
    Compute Layout      :0, 10

    section Extraction
    Extract Frames      :10, 70
    Add Timestamps      :crit, 65, 70

    section Composition
    Create Background   :70, 73
    Add Metadata Header :73, 75
    Process Frame Batches :75, 90

    section Finalization
    Save to Disk        :90, 100
    Complete            :milestone, 100, 100
```

## Key Decision Points

```mermaid
flowchart LR
    subgraph Initialization
        D1{Platform?}
        D1 -->|macOS| Metal[Metal GPU]
        D1 -->|iOS| CG[Core Graphics]
    end

    subgraph Configuration
        D2{Density Level?}
        D2 --> XXL[XXL: 4-50 frames]
        D2 --> M[M: 100-300 frames<br/>Default]
        D2 --> XXS[XXS: 400-800 frames]

        D3{Layout Type?}
        D3 --> Custom[Custom 3-Zone]
        D3 --> Classic[Classic Grid]
        D3 --> Auto[Auto/Dynamic]

        D4{Include Metadata?}
        D4 -->|Yes| AddHeader[+30% height header]
        D4 -->|No| NoHeader[No header]
    end

    subgraph Extraction
        D5{Accurate Timestamps?}
        D5 -->|Yes| Exact[Zero tolerance<br/>Slower, precise]
        D5 -->|No| Fast[±0.5s tolerance<br/>Faster]
    end

    subgraph Output
        D6{Output Format?}
        D6 --> JPEG[JPEG: Small file<br/>Lossy]
        D6 --> PNG[PNG: Large file<br/>Lossless]
        D6 --> HEIF[HEIF: Balanced<br/>Modern]
    end

    style Metal fill:#f8d7da
    style CG fill:#f8d7da
    style M fill:#d4edda
    style Custom fill:#d4edda
    style Fast fill:#d4edda
    style HEIF fill:#d4edda
```

## Performance Characteristics Comparison

| Aspect | Metal (macOS) | Core Graphics (iOS) |
|--------|---------------|---------------------|
| **Background Creation** | GPU-accelerated gradient | CIFilter + CPU rendering |
| **Image Scaling** | GPU compute shader (bilinear/trilinear) | vImage Accelerate (Lanczos) |
| **Composition** | GPU alpha-blending shader | CGContext hardware-accelerated |
| **Batch Size** | 200 frames (GPU optimized) | 20 frames (CPU optimized) |
| **Concurrency** | Asynchronous GPU batches | Sequential CPU batches |
| **Memory** | GPU VRAM + System RAM | System RAM only |
| **Typical Speed** | Very Fast (GPU parallel) | Fast (CPU SIMD) |

## Error Handling & Retry Logic

```mermaid
flowchart TD
    Start([Frame Extraction]) --> Extract[Extract Frame]

    Extract --> Success{Success?}
    Success -->|Yes| NextFrame
    Success -->|No| Retry{Retries<br/>left?}

    Retry -->|Yes| RetryExtract[Retry Frame Extraction]
    Retry -->|No| BlankFrame[Use Blank Image]

    RetryExtract --> RetrySuccess{Success?}
    RetrySuccess -->|Yes| NextFrame[Continue to Next Frame]
    RetrySuccess -->|No| BlankFrame

    BlankFrame --> NextFrame

    NextFrame --> MoreFrames{More<br/>frames?}
    MoreFrames -->|Yes| Extract
    MoreFrames -->|No| Complete([Extraction Complete])

    style Success fill:#fff3cd
    style BlankFrame fill:#f8d7da
    style Complete fill:#d4edda
```

## Concurrency Model

```mermaid
flowchart TD
    subgraph Main_Thread
        A[User calls generate]
        A --> B[await generator.generate]
    end

    subgraph Actor_Generator["Generator Actor (Metal/CoreGraphics)"]
        B --> C[Actor-isolated generate method]
        C --> D[Sequential: Layout Calculation]
        D --> E[Concurrent: Frame Extraction]
        E --> F[Sequential: Metadata Creation]
        F --> G[Batched: Mosaic Composition]
        G --> H[Sequential: Save to Disk]
    end

    subgraph Frame_Extraction_Concurrency
        E --> E1[Task Group]
        E1 --> E2["Concurrent Workers<br/>(up to 16 parallel)"]
        E2 --> E3[Worker 1: Frame 1]
        E2 --> E4[Worker 2: Frame 2]
        E2 --> E5[...]
        E2 --> E6[Worker N: Frame N]
        E3 --> E7[Await all workers]
        E4 --> E7
        E5 --> E7
        E6 --> E7
    end

    subgraph Batch_Processing
        G --> G1{Platform?}
        G1 -->|Metal| G2[GPU Batches: 200 frames<br/>Async GPU execution]
        G1 -->|CG| G3[CPU Batches: 20 frames<br/>Sequential processing]
    end

    H --> I([Return URL to Main Thread])

    style Actor_Generator fill:#fff3cd
    style Frame_Extraction_Concurrency fill:#e1f5ff
    style Batch_Processing fill:#f8d7da
```

## Complete End-to-End Timeline

```
┌─────────────────────────────────────────────────────────────────────┐
│ USER INPUT                                                          │
│ let url = try await generator.generate(from: video, config: config)│
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ INITIALIZATION (0-5% progress)                                      │
│ • Factory selects Metal (macOS) or Core Graphics (iOS)             │
│ • Create actor-based generator                                     │
│ • Load VideoInput from URL                                         │
│ • Initialize task with UUID                                        │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ LAYOUT CALCULATION (5-10% progress)                                │
│ • Calculate thumbnail count: base + k×log(duration)×density        │
│   Example: 5120px, 60s, M density → ~250 frames                   │
│ • Calculate optimal layout (Custom 3-zone / Classic / Auto)        │
│   → Returns: rows, cols, positions, sizes                         │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ FRAME EXTRACTION (10-70% progress) ★ MOST TIME CONSUMING ★         │
│ • Calculate extraction times with biased distribution:             │
│   - First 1/3: 20% of frames (skip intro/credits)                 │
│   - Middle 1/3: 60% of frames (capture main action)               │
│   - Last 1/3: 20% of frames (skip outro)                          │
│ • AVAssetImageGenerator with VideoToolbox acceleration            │
│ • Concurrent extraction (up to 16 parallel workers)                │
│ • Primary pass → Retry failed → Blank fallback                    │
│ • Add timestamp overlays to each frame                             │
│   Example: 250 frames @ 1080p extracted in ~15-30 seconds         │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ METADATA HEADER (70-72% progress, optional)                        │
│ • Create header with video info if config.includeMetadata = true  │
│ • Height = 30% of thumbnail height                                 │
│ • Contains: filename, duration, dimensions, FPS, codec, bitrate    │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ MOSAIC COMPOSITION (72-90% progress)                               │
│                                                                     │
│ ┌─────────────────────┬─────────────────────────────────────────┐ │
│ │ Metal (macOS)       │ Core Graphics (iOS)                     │ │
│ ├─────────────────────┼─────────────────────────────────────────┤ │
│ │ 1. Create gradient  │ 1. Create gradient background         │ │
│ │    background via   │    via CIFilter + Gaussian blur       │ │
│ │    GPU              │                                         │ │
│ │ 2. Convert to       │ 2. Render to CGImage                  │ │
│ │    MTLTexture       │                                         │ │
│ │ 3. Process in       │ 3. Process in 20-frame batches        │ │
│ │    200-frame        │                                         │ │
│ │    batches          │                                         │ │
│ │ 4. For each batch:  │ 4. For each frame:                    │ │
│ │    - Create command │    - Scale with vImage (Lanczos)      │ │
│ │      buffer         │    - Composite with CGContext.draw    │ │
│ │    - Scale frames   │                                         │ │
│ │      (GPU shader)   │                                         │ │
│ │    - Composite      │                                         │ │
│ │      (GPU shader)   │                                         │ │
│ │    - Commit batch   │                                         │ │
│ │ 5. Convert texture  │ 5. Final CGImage ready                │ │
│ │    to CGImage       │                                         │ │
│ └─────────────────────┴─────────────────────────────────────────┘ │
│                                                                     │
│ Example: 250 frames @ 200×150px → 5120×2880px mosaic              │
│          Metal: ~5-10 seconds   CG: ~10-20 seconds                 │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ SAVE TO DISK (90-100% progress)                                    │
│ • Determine output directory structure                             │
│   {root}/{service}/{creator}/{config}/                            │
│ • Generate filename                                                 │
│   {original}_{width}_{density}_{aspect}_{timestamp}.{ext}         │
│ • Convert CGImage → NSImage/UIImage                               │
│ • Encode based on format (JPEG/PNG/HEIF)                          │
│ • Write to disk                                                     │
│   Example: 5120×2880 HEIF → ~3-8 MB file in ~1-2 seconds          │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│ COMPLETION (100% progress)                                         │
│ • Update performance metrics                                       │
│ • Return file URL to user                                          │
│ • Fire completion progress handler                                 │
└─────────────────────────────────────────────────────────────────────┘

Total Time Example (1080p 60s video, 250 frames, 5120px width):
• Metal (macOS): ~25-45 seconds
• Core Graphics (iOS): ~35-60 seconds
```

## Summary

The mosaic generation workflow is a sophisticated pipeline that:

1. **Adapts to platform** - Automatically selects optimal processing backend
2. **Optimizes frame selection** - Biased distribution captures important moments
3. **Leverages hardware acceleration** - Metal GPU (macOS) or vImage/Accelerate (iOS)
4. **Processes efficiently** - Batched composition prevents timeouts
5. **Provides transparency** - Real-time progress tracking with 5 distinct phases
6. **Handles errors gracefully** - Retry logic with fallback to blank frames
7. **Delivers quality** - High-quality scaling and multiple output formats

The entire process is thread-safe via Swift actors, async/await concurrency, and platform-specific optimizations that make full use of available hardware resources.
