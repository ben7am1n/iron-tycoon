# GA-005 — One room, one coach, two-device visual sample

Status: Planned
Last Updated: 2026-09-06
Layer: Feature
Type: Visual/Feel
TR-ID: TR-GA-001, TR-GA-002, TR-GA-003
ADR Governing Implementation: docs/architecture/adr-0011-community-day-session.md
Manifest Version: 2026-09-06
Dependencies: GA-003/004 first-day end-to-end proof before visual production.

## Scope

Improve the verified first-day room and its actual moving characters. The coach is recognizable by teal clothing, broad shoulders and silver hair streak; treadmill/yoga mat show grounded exercise poses. Background noise is reduced and three lighting phases remain readable. Preserve the original sandbox default look through an optional community profile.

## Acceptance Criteria

- [ ] At the standard 1280×720 window, community world pixels scale uniformly and the coach remains clearly identifiable among four class members.
- [ ] Coach idle, walking and guidance have anchored feet and visible pose changes; direction selection never rotates the entire body image in screen space.
- [ ] Treadmill and yoga mat use equipment-specific contact anchors, with wait/train/swap states visible in the real class.
- [ ] A daylight / dusk / night triptych from the same engine scene demonstrates phase lighting without washing out faces or clothing.
- [ ] Background decoration contrast is lower than active characters and equipment; important paths and waiting positions remain readable.
- [ ] Capture actual in-engine before/after and movement/class evidence. Report direction/animation coverage honestly; any unproduced production frames and external five-player recognition test remain outstanding.

## Implementation Notes

Use docs/plans/2026-09-06-gym-adventure/art-direction.md. This is a working sample, not the full 880-frame production asset set. Reuse original geometry, logic and current assets where appropriate. New procedural pixel sprites are source assets; edits to existing raster images require the image generation workflow. Logic and visual state must remain separate; no visual script may award money or advance course training.

## Test Evidence

production/qa/evidence/gym-adventure-visual-sample.md plus original PNG viewport captures. Source/anchor validation and full regression complement visual inspection but cannot certify subjective similarity or external player preferences.
