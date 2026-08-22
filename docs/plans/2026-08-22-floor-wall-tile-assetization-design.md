# Floor/Wall Tile Assetization Design

Date: 2026-08-22
Status: implemented and visually validated

## Visual direction

The floor and wall system uses commercial pixel-art restraint: one dominant
material color, structural seams only where they explain construction, and at
most two tiny finish marks. Every 32×32 PNG keeps non-dominant pixels below 15%
of its area. Strength uses dark rubber with one shared tile seam; cardio is a
nearly unmarked warm-gray sheet; flex uses two clearly oriented, staggered wood
planks; walkway uses a regular clean grout corner. North and side walls use
quiet wall faces with a two-pixel kickboard profile. Zone recognition therefore
comes from hue/value separation instead of distressed edges or texture density.

## Runtime architecture

`FloorArt` keeps the existing one-time 416×320 bake and cached `ImageTexture`,
so `WorldCanvas` still draws the floor in one call. The bake now repeats four
PNG tiles into the walkway and zone rectangles. `StructureArt` repeats the wall
assets horizontally, scales the authored vertical wall profile to each wall
orientation, then bakes the existing clocks, vents, mirrors, posters, pipes,
and other anchor decor over the clean base. The ceiling and projected external
wall extension are clean negative space rather than procedural brush fields.

## Failure behavior and verification

Both art factories follow the equipment asset-first pattern: imported
`Texture2D` loading first, raw PNG decoding for fresh headless checkouts, and a
cached clean procedural base/seam tile if an asset is missing. Tests exercise
path mapping, successful loading, 32×32 dimensions, exact 32-pixel repetition,
zone semantics, detail budgets, missing-file fallback, determinism, and texture
caching. Old assertions for cluster counts, stain colors, dominant-color caps,
and jagged boundaries were removed because those behaviors are intentionally no
longer part of the rendering contract. Visual evidence captures the same real
main scene before and after and writes a side-by-side comparison.
