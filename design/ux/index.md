# design/ux/ — UX Design Directory

> **Status**: ✅ Established (2026-08-02 — gate-check item #4: `/ux-design` scheduled before the first UI story)
> **Owner**: ux-designer
> **Source**: gate-check `production/gate-checks/gate-production-2026-08-02.md` item #4 (CD + AD共同强调: UX specs / accessibility / patterns 缺失，须在首个 UI story 前产出)

This directory holds the UX layer of the design tree — the formalization of *how*
screens, HUD, and interactions feel and behave, derived from the GDDs (which remain
normative for rules). All specs here were authored via the `/ux-design` skill and
validated against the `/ux-review` checklist before being declared ready for
`/team-ui`.

## Authoring Conventions (per `design/CLAUDE.md`)

- Per-screen specs: `design/ux/[screen-name].md`
- HUD design: `design/ux/hud.md`
- Interaction pattern library: `design/ux/interaction-patterns.md`
- Accessibility requirements: `design/ux/accessibility-requirements.md`
- Author with `/ux-design`; validate with `/ux-review` before passing to `/team-ui`.
- Every spec carries: Status header, source GDD(s), pillar mapping, input/platform
  from `.claude/docs/technical-preferences.md`, and a link to the accessibility tier.

## Specs

| File | Scope | Source GDD(s) | Status |
|---|---|---|---|
| [accessibility-requirements.md](accessibility-requirements.md) | Project-wide accessibility tier (Standard / WCAG-AA baseline) + cross-cutting requirements + settings surface | art bible §Accessibility, tech prefs | ✅ Approved |
| [interaction-patterns.md](interaction-patterns.md) | Shared interaction vocabulary: drag-snap (A3-validated), selection, soft-confirm, palette, HUD transport, overlay toggle, animation/sound standards | GDDs #4/#8/#12/#13/#15/#16, vertical slice A3 | ✅ Approved |
| [hud.md](hud.md) | HUD: philosophy, information architecture, layout zones, elements, dynamic behaviors, platform variants, accessibility | GDD #16 (Approved) | ✅ Approved |
| [selection-ui.md](selection-ui.md) | Selection UI: inspect/move/sell of placed equipment | GDD #13 (In Review) | ✅ Approved |
| [build-shop-ui.md](build-shop-ui.md) | Build/Shop palette: purchase + drag-and-place flow | GDDs #12 (Approved) + #15 (Designed) | ✅ Approved |

## Coverage vs. Planned Screens

The gate-check requires UX specs **before Selection UI, HUD, and Shop enter
`/team-ui`** — all three now have specs. Remaining UI systems are **not yet specced**
and will need their own `/ux-design` pass before they enter `/team-ui`:

| System | Status | When |
|---|---|---|
| Selection UI (#13) | ✅ specced | ready for team-ui |
| HUD (#16) | ✅ specced | ready for team-ui |
| Build/Shop UI (#12/#15) | ✅ specced | ready for team-ui |
| Congestion/Flow Overlay (#8) | ⚠️ interaction patterns covered in library; full overlay spec deferred | before its team-ui story |
| Equipment Info Panel (#17) | ⚠️ not specced (opened by selection-ui.md OQ2) | Vertical Slice |
| Pause menu shell (HUD OQ2) | ⚠️ not specced | before a shippable build |
| Onboarding / Tutorial (#20) | ⚠️ not specced | Vertical Slice |

## Dependencies & Notes

- **Player journey map missing** — `design/player-journey.md` does not exist. All
  specs carry an Open Question noting this gap (template at
  `.claude/docs/templates/player-journey.md`). Recommend creating it before the
  first UI playtest.
- **Input/platform**: Keyboard/Mouse primary (drag-and-drop), Gamepad partial
  (stretch, non-MVP-blocking), Touch none; PC desktop (macOS primary, Windows
  secondary) — per `.claude/docs/technical-preferences.md`.
- **Accessibility tier**: Standard (WCAG-AA baseline) — all specs satisfy it by
  construction; `/ux-review` checks tier match.
- **drag-snap** interaction was validated in vertical slice A3
  (`prototypes/gym-flow-vertical-slice/REPORT.md` §2) — low risk, but the pattern
  library formalizes it so `/team-ui` implements once, consistently.

## Next Steps

- [ ] Run `/ux-review all` on `design/ux/` before the first team-ui story (already
      self-validated in this gate; formal review pass recommended).
- [ ] Create the player journey map (`design/player-journey.md`) before the first
      UI playtest.
- [ ] Resolve open presentation decisions at team-ui kickoff: palette edge/tile size
      (build-shop-ui.md OQ2), build/select affordance (OQ3), toolbar anchoring
      (selection-ui.md OQ3).
- [ ] Gate-check item #5 (`/asset-spec` + assets/ skeleton) can now be scheduled —
      UX specs give asset specs their screen context.
