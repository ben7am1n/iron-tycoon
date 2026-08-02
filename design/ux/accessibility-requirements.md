# Accessibility Requirements — 撸铁大亨 (Iron Tycoon)

> **Status**: ✅ Approved (2026-08-02 — ux-design gate, gate-check item #4)
> **Author**: user + ux-designer
> **Last Updated**: 2026-08-02
> **Template**: Accessibility Requirements
> **Implements Pillar**: Pillar 2 (松弛不紧绷 — accessibility *is* the calm promise) · Pillar 3 (一眼看懂 — legible for everyone)
> **Owner**: ux-designer (tier decisions); ui-programmer (implementation); Settings & Accessibility (#22) (runtime options)

---

## 1. Committed Tier

**Standard (WCAG-AA baseline)**, adapted for a cozy desktop management game.
This is a *project-wide* commitment: every screen spec, HUD element, and interaction
pattern in `design/ux/` must satisfy or exceed this tier. The art bible's
Accessibility section (icon+color dual channel, ≥16px @1080p, high-contrast option,
no flashing) is folded in as the visual floor; this document is the normative spec.

| Dimension | Commitment |
|---|---|
| Target platforms | PC (macOS primary, Windows secondary) — desktop only, no touch |
| Primary input | Keyboard/Mouse (drag-and-drop on grid) |
| Gamepad | **Partial** (stretch goal; MVP keyboard/mouse complete, gamepad non-blocking) |
| Contrast | WCAG-AA: 4.5:1 normal text, 3:1 large text (≥24px / ≥18.66px bold), 3:1 UI components & state boundaries |
| Color independence | No information conveyed by color alone (icon + shape + text dual channel) |
| Flashing | No flashing content; nothing exceeds 3 flashes/sec (photosensitive safety) |
| Motion | All non-essential motion reduced under a global reduced-motion setting |
| Text size | Body ≥ 16px @1080p logical (art bible); UI scale 0.8×–1.5×, integer scaling |
| Focus | Visible focus indicator on every interactive element; full keyboard path |
| Screen reader | Not a screen-reader game (visual-first simulation); tooltips must not be the *only* channel for critical info |

---

## 2. Rationale (why Standard, not Basic/Comprehensive)

- **Basic is insufficient** because the game's core loop is spatial (drag, rotate,
  placement feedback, congestion read) and the art bible already commits to
  colorblind-safe dual-channel and no-flash rules — Basic would *under*state
  existing obligations.
- **Comprehensive (screen-reader narration of the sim) is out of scope for MVP**:
  the simulation is a fast-moving visual medium (10 Hz member flow), and a
  screen-reader interpretation of a pixel-art gym is a large, unvalidated surface.
  Documented as a post-MVP consideration (see Open Questions).
- The committed tier matches what the art bible already promises and what the GDDs
  already require (colorblind-simulation ACs in HUD/Shop/Selection).

---

## 3. Cross-Cutting Requirements

These apply to **every** screen, HUD element, and pattern in `design/ux/`.

### 3.1 Color Independence (non-negotiable, art-bible §Accessibility)

- Every state communicated with color **must** also carry an icon/shape/text channel.
- The critical confusable pair is **Sage (#8FBF9F) ↔ Dusty Rose (#E0A0A0)**
  (green↔red family). Any "good/bad" or "satisfied/crowded" indicator must be
  legible with color desaturated.
- Concrete dual-channel commitments already in the GDDs (must be honored):
  - Satisfaction meter: numeric % + face/heart icon whose *shape* changes.
  - Speed cluster: active button marked by outline + filled-dot icon.
  - Shop palette: affordable/unaffordable by desaturation, locked by **lock icon**.
  - Congestion glyph: outline-to-filled shape (like a battery).
  - Access-blocked: barricade icon, shape-first, Dusty Rose secondary.
  - Selection cue: Soft Charcoal outline + corner "selected" icon (never color alone).

### 3.2 Keyboard-Only Operation (complete path)

- Every interactive element must be reachable and operable with keyboard alone.
- Tab order / focus order must be defined per screen (see each spec's Interaction Map).
- **Esc** is the global cancel/deselect key (consistent across all screens — see
  interaction-patterns.md Navigation/Modal patterns).
- Keyboard must never be a *worse* path than mouse: selling via Del triggers the
  same soft-confirm as clicking Sell (GDD #13 Core Rule 5).
- Space/1/2/3 HUD transport shortcuts; R (rotate) during placement drag; H (toggle
  flow overlay) — all documented in interaction-patterns.md Hotkeys section.

### 3.3 Focus Visibility

- Every focused interactive element shows a **2px Soft Charcoal or high-contrast
  outline** distinct from the selection cue (so "keyboard focus" never reads as
  "grid selection").
- Focus indicator must not rely on color alone (outline + inset shadow).
- Focus must never be trapped in a modal without a documented exit (Esc always works).

### 3.4 Text & Scaling

- Body/values ≥ 16px @1080p logical; titles ≥ 20px; labels ≥ 14px with AA contrast.
- UI scale setting: 0.8×, 1.0×, 1.25×, 1.5× (integer multipliers for pixel font).
- All HUD and overlay elements must fit within the play area at 1.5× without
  overlapping the center grid.
- Layout-critical text (button labels, money, prices) must tolerate the localization
  expansion budget (see 3.6).

### 3.5 Motion & Flashing

- **No flashing** anywhere: nothing animates ≥3 times/sec (photosensitive safety,
  art-bible prohibition). The sell-confirm morph, breathe cycles, heatmap fade —
  all ≤ ~1 cycle/sec.
- **Reduced motion setting**: when ON, disable/limit: satisfaction breathe cycle,
  money count-up (snap instead of tween), heatmap fade-in (instant), selection
  glow pulse (static outline only). Must not remove information, only animation.
- No screen shake, no strobe, no alarm pulses (art bible prohibitions).

### 3.6 Localization & Text Expansion

- Text elements flagged HIGH PRIORITY in each spec must tolerate **40% expansion**
  (EN→DE/FR style) without layout breakage: button labels stay on one line, money
  values don't collide with icons, tooltips wrap.
- Numeric/currency display must be locale-formattable (thousands separators,
  currency symbol position) without breaking layout.
- Chinese (primary locale) and English must both render in the chosen pixel font
  at full glyph coverage (art bible §7 — architecture confirms font resource).

### 3.7 Tooltips / Discoverability

- Tooltips must **augment**, never be the sole channel for critical information.
  Critical states (access-blocked, unaffordable, sell-confirm) are always legible
  from the persistent UI itself; tooltips add detail on hover only.
- Tooltip dismiss: on mouse-leave, on Esc, or after 4 s — never requires a click.

---

## 4. Screen-Specific Requirements Index

| Screen / Spec | Key accessibility commitments |
|---|---|
| `design/ux/hud.md` | Money/satisfaction/time all readable via icon+number+shape; no red/alarm; keyboard transport; focus on speed buttons |
| `design/ux/selection-ui.md` | Keyboard select/deselect (Esc, Del), focus vs selection cue separation, toolbar keyboard path, colorblind-safe selection cue |
| `design/ux/build-shop-ui.md` | Palette states distinguishable without color (desat + lock icon); keyboard palette navigation; "save $X more" text not color |
| Flow overlay (per congestion-flow-overlay.md) | Shape-first glyphs; heatmap is *supplemental* (toggle-gated); access-blocked always shape+tooltip; heatmap never the only crowding signal |
| (future) pause menu / settings | Full keyboard nav; settings incl. UI scale, high-contrast, reduced motion, colorblind mode (#22) |

---

## 5. Settings Surface (Settings & Accessibility #22 — Vertical Slice)

The runtime accessibility settings the committed tier depends on:

| Setting | Options | Default | Notes |
|---|---|---|---|
| UI scale | 0.8× / 1.0× / 1.25× / 1.5× | 1.0× | integer multipliers |
| High-contrast theme | Off / On | Off | heavier outlines, higher contrast text (art bible) |
| Reduced motion | Off / On | Off | §3.5 |
| Colorblind assist | Off / On | Off | strengthens shape/pattern channels; verified via desaturation test |
| Key rebinding | full action map | defaults | includes R, H, Space, 1/2/3, Esc, Del |

MVP note: Settings lives in the pause-menu shell (HUD OQ2); until it ships, the
defaults above are the shipped values and the committed tier holds at defaults.

---

## 6. Validation

- **Design-time**: every `/ux-review` run checks the spec against this document
  (tier match, focus order, contrast, colorblind, reduced-motion).
- **Implementation-time**: ui-programmer verifies focus order + keyboard path per
  screen against the spec's Interaction Map.
- **QA**: manual walkthroughs include a desaturated-color pass and keyboard-only
  pass per screen; GDD-level colorblind ACs (HUD AC6, Shop AC8, Selection AC8)
  are run as written.
- **Tooling**: colorblind-simulation pass (desaturate) and reduced-motion
  verification are part of the UI story DoD.

---

## 7. Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| AQ1 | Screen-reader narration of the sim (Comprehensive tier) — evaluate post-MVP; a pixel-art 10 Hz sim is a large surface to narrate meaningfully. | ux-designer / producer | Post-MVP decision |
| AQ2 | Gamepad completeness — tech prefs say "Partial, stretch goal". Confirm the gamepad navigation order for the HUD + shop palette *before* any gamepad story starts; MVP ships keyboard/mouse-complete. | ux-designer / ui-programmer | Before first gamepad story |
| AQ3 | Pixel font choice (CN+EN full coverage) and its minimum legible size — must be resolved at `/create-architecture` (art bible §7). | art-director / architecture | At architecture |
| AQ4 | Colorblind assist mode's exact effect on the heatmap (it is already dual-channel) — define when Settings (#22) is designed. | ux-designer / accessibility-specialist | With #22 |
