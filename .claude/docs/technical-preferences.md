# Technical Preferences

<!-- Populated by /setup-engine. Updated as the user makes decisions throughout development. -->
<!-- All agents reference this file for project-specific standards and conventions. -->

## Engine & Language

- **Engine**: Godot 4.7.1
- **Language**: GDScript
- **Rendering**: Godot 2D renderer (Forward+ / Mobile as needed; 2D pixel-art focus)
- **Physics**: Godot 2D physics (as needed; navigation via NavigationServer2D)

## Input & Platform

<!-- Written by /setup-engine. Read by /ux-design, /ux-review, /test-setup, /team-ui, and /dev-story -->
<!-- to scope interaction specs, test helpers, and implementation to the correct input methods. -->

- **Target Platforms**: PC (macOS primary, Windows secondary)
- **Input Methods**: Keyboard/Mouse
- **Primary Input**: Keyboard/Mouse (drag-and-drop grid placement, top-down management)
- **Gamepad Support**: Partial
- **Touch Support**: None
- **Platform Notes**: Core interaction is mouse drag-and-drop on a grid. No touch-only interactions. Gamepad support is a stretch goal, not required for MVP.

## Naming Conventions

- **Classes**: PascalCase (e.g., `GymFloor`)
- **Variables**: snake_case (e.g., `move_speed`)
- **Signals/Events**: snake_case past tense (e.g., `equipment_placed`)
- **Files**: snake_case matching class (e.g., `gym_floor.gd`)
- **Scenes/Prefabs**: PascalCase matching root node (e.g., `GymFloor.tscn`)
- **Constants**: UPPER_SNAKE_CASE (e.g., `MAX_MEMBERS`)

## Performance Budgets

- **Target Framerate**: 60 fps
- **Frame Budget**: 16.6 ms
- **Draw Calls**: Modest — 2D pixel-art; keep batched, target < 200 draw calls typical scene
- **Memory Ceiling**: [TO BE CONFIGURED — set when target hardware is known]

## Testing

- **Framework**: GUT (Godot Unit Test)
- **Minimum Coverage**: [TO BE CONFIGURED]
- **Required Tests**: Balance formulas, gameplay systems (layout/economy/satisfaction), navigation/congestion logic

## Forbidden Patterns

<!-- Add patterns that should never appear in this project's codebase -->
- [None configured yet — add as architectural decisions are made]

## Allowed Libraries / Addons

<!-- Add approved third-party dependencies here -->
- [None configured yet — add as dependencies are approved]

## Architecture Decisions Log

<!-- Quick reference linking to full ADRs in docs/architecture/ -->
- [No ADRs yet — use /architecture-decision to create one]

## Engine Specialists

- **Primary**: godot-specialist
- **Language/Code Specialist**: godot-gdscript-specialist (all .gd files)
- **Shader Specialist**: godot-shader-specialist (.gdshader files, VisualShader resources)
- **UI Specialist**: godot-specialist (no dedicated UI specialist — primary covers all UI)
- **Additional Specialists**: godot-gdextension-specialist (GDExtension / native C++ bindings only)
- **Routing Notes**: Invoke primary for architecture decisions, ADR validation, and cross-cutting code review. Invoke GDScript specialist for code quality, signal architecture, static typing enforcement, and GDScript idioms. Invoke shader specialist for material design and shader code. Invoke GDExtension specialist only when native extensions are involved.

### File Extension Routing

| File Extension / Type | Specialist to Spawn |
|-----------------------|---------------------|
| Game code (.gd files) | godot-gdscript-specialist |
| Shader / material files (.gdshader, VisualShader) | godot-shader-specialist |
| UI / screen files (Control nodes, CanvasLayer) | godot-specialist |
| Scene / prefab / level files (.tscn, .tres) | godot-specialist |
| Native extension / plugin files (.gdextension, C++) | godot-gdextension-specialist |
| General architecture review | godot-specialist |
