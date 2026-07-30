# Godot Engine — Version Reference

| Field | Value |
|-------|-------|
| **Engine Version** | Godot 4.7.1 |
| **Release Date** | June 18, 2026 (4.7.0); 4.7.1 patch |
| **Project Pinned** | 2026-07-15 |
| **Last Docs Verified** | 2026-07-15 |
| **LLM Knowledge Cutoff** | May 2025 |
| **Local Install** | `/opt/homebrew/bin/godot`, `/Applications/Godot.app` (4.7.1.stable.official) |
| **Risk Level** | HIGH — version is beyond LLM training data |

## Knowledge Gap Warning

The LLM's training data likely covers Godot up to ~4.3. Versions 4.4, 4.5,
4.6, and 4.7 introduced significant changes that the model does NOT know about.
Always cross-reference this directory before suggesting Godot API calls.

## Post-Cutoff Version Timeline

| Version | Release | Risk Level | Key Theme |
|---------|---------|------------|-----------|
| 4.4 | ~Mid 2025 | MEDIUM | Jolt physics option, FileAccess return types, shader texture type changes |
| 4.5 | ~Late 2025 | HIGH | Accessibility (AccessKit), variadic args, @abstract, shader baker, SMAA |
| 4.6 | Jan 2026 | HIGH | Jolt default, glow rework, D3D12 default on Windows, IK restored |
| 4.7 | Jun 2026 | HIGH | HDR output, AreaLight3D, Control offset transforms, DrawableTexture2D, VirtualJoystick, tween_await(), wasm64 |

## Migration Notes — 4.6 → 4.7.1

**Migration guide:** https://docs.godotengine.org/en/4.7/tutorials/migrating/upgrading_to_godot_4.7.html

Minor version bump — most 4.6 projects migrate smoothly. This is a fresh project,
so no source migration is needed. Key points relevant to **this project** (2D cozy
management, GDScript, PC desktop):

- **Use `TileMapLayer`, NOT `TileMap`.** `TileMap` has been deprecated since 4.3
  and is still deprecated in 4.7. Our grid/floor should be built on `TileMapLayer`
  (one node per layer). This is the single most relevant deprecation for us.
- **`Control` offset transforms (NEW in 4.7):** Controls inside Containers can now
  be moved/rotated/scaled with a visual offset transform that the Container won't
  reset. Great for juicy, animated UI (支柱4 "看得见的蜕变") without breaking layout.
  You can choose whether the visual offset affects input.
- **`DrawableTexture2D` (NEW in 4.7):** a texture you can draw onto directly — ideal
  for our **congestion/flow heatmap overlays** (可视化拥挤度与动线) without viewport
  gymnastics.
- **`tween_await()` (NEW in 4.7):** tweens can wait for signals — useful for UI/feedback
  sequencing.
- **Nearest-neighbor viewport scaling (NEW in 4.7):** applies to **3D only, does NOT
  affect 2D.** For crisp 2D pixel-art, keep using texture filter = Nearest on
  sprites/import settings as before.
- **Breaking changes that do NOT affect us:** Android OBB removal (no Android),
  custom 3D shader preprocessor macros (no 3D shaders), BlendSpace point handling
  (no 3D animation blend spaces), XR action maps (no XR).

## Verified Sources

- Official docs: https://docs.godotengine.org/en/stable/
- 4.6→4.7 migration: https://docs.godotengine.org/en/4.7/tutorials/migrating/upgrading_to_godot_4.7.html
- 4.7 release notes: https://godotengine.org/releases/4.7/
- 4.5→4.6 migration: https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.6.html
- 4.4→4.5 migration: https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.5.html
- Changelog: https://github.com/godotengine/godot/blob/master/CHANGELOG.md
