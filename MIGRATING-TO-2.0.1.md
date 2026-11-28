# Migrating to MosaicKit 2.0.1

2.0.1 fixes the `classic`, `custom` and `auto` layouts and deprecates `iphone`. No API is removed,
but **mosaics and animations made with these layouts look different** than with 2.0.0.

## 1. What changes

| Layout | Before | Now |
|---|---|---|
| `custom` (default) | Count often stayed flat as duration or density rose; cells down to 37 px | Count never drops, and neighboring densities differ. Cells are at least 50 px wide |
| `classic` | Ignored the mosaic aspect for large counts; a longer video or wider mosaic could give fewer cells | Follows the mosaic aspect; count never drops; full rows only |
| `auto` | Screen-sized canvas with a screen-fitted count, ignoring width, density and duration; 4 frames with no screen | Honors width, density and duration; only the canvas *shape* comes from the screen (the configured aspect when there is no screen) |
| `uneven` | — | Changes only where it falls back to `classic` (fewer than 12 frames, or a source aspect outside 0.2…5) |
| `fixedGrid` | — | Unchanged |

- **Thumbnail counts** change. Measured over 525 combinations of a 16:9 source: `custom` has
  0.58× to 2.10× as many as before (median 1.15×), `classic` 0.70× to 1.93× (median 1.07×), `auto`
  0.20× to 5.70×. More thumbnails take proportionally longer and make larger animations.
- **Narrow mosaics at high density** can get fewer frames than requested, because cells stop at
  50 px.
- **Output names and `configurationHash` are unchanged.** With `overwrite: false`, mosaics already
  on disk are kept, so one folder can hold old and new layouts until they are regenerated.

## 2. `LayoutType.iphone` is deprecated

It still decodes and is laid out as before, and `forIphone: true` still selects it. It is no longer
listed in `LayoutType.allCases`.

## 3. Tessera checklist

- Bump MosaicKit to `2.0.1`.
- Update any snapshot or count expectations for `custom`, `classic` and `auto`.
- Remove `.iphone` from layout pickers or stored defaults, if present.
