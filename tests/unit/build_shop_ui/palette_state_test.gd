# tests/unit/build_shop_ui/palette_state_test.gd
# Story BSUI-001: Shop Palette Rendering
# (production/epics/build-shop-ui/story-001-shop-palette-rendering.md)
#
# Covers the BLOCKING ACs (TR-BSUI-001/002/006 + GDD Core Rule 1):
#   - Core Rule 1  EVERY catalog item renders icon + name + Butter price;
#                  empty catalog shows the calm "Nothing available yet" hint.
#   - AC1          an item the player can't afford is greyed (desaturated,
#                  achromatic modulate — no red) and reports not-draggable.
#                  (Mouse-down drag gating is Story 002's logic; the rendered
#                  state + is_draggable() query ship here.)
#   - AC2          balance rising to an item's cost + balance_changed fires
#                  -> the tile is full-tint WITHIN ONE FRAME (the S6 handler
#                  re-derives synchronously; no manual refresh, no await).
#                  Both directions: rise lights up, fall re-greys.
#   - AC3          a locked item (unlock_requirement != "") shows a lock icon
#                  (shape), is not draggable, and stays locked even when the
#                  balance could afford it.
#   - AC8          colorblind-simulation: the three states are each
#                  distinguishable by tint-desaturation (achromatic modulate)
#                  + lock icon shape — never by color/hue alone.
#   - Shop seam    the palette renders whatever the injected query layer
#                  reports (Story 002 swaps PlaceholderPaletteAvailability
#                  for the real Shop without touching the palette).
#
# Run standalone: godot --headless --script tests/unit/build_shop_ui/palette_state_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const DEF_SCRIPT_PATH := "res://src/systems/equipment_def.gd"
const CATALOG_SCRIPT_PATH := "res://src/systems/equipment_catalog.gd"
const ECON_SCRIPT_PATH := "res://src/systems/economy.gd"
const SRG_SCRIPT_PATH := "res://src/systems/seeded_rng.gd"
const PALETTE_SCRIPT_PATH := "res://src/ui/build_shop_palette.gd"
const TILE_SCRIPT_PATH := "res://src/ui/palette_tile.gd"
const AVAIL_SCRIPT_PATH := "res://src/ui/palette_availability.gd"
const PLACEHOLDER_AVAIL_SCRIPT_PATH := "res://src/ui/placeholder_palette_availability.gd"

## preload alias for the inner ScriptedAvailability class's base — the
## headless cross-script ref pattern (global class cache is editor-generated).
const PaletteAvailabilityScript := preload("res://src/ui/palette_availability.gd")

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
## 否则 script.new() 触发的 _init() 与随后的 run_all() 会让每个用例跑两遍。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Build/Shop UI — Palette Rendering (Story BSUI-001)")
	print("=".repeat(48))

	_test_core_rule_1_all_items_render_icon_name_price()
	_test_core_rule_1_empty_catalog_calm_hint()
	_test_ac1_unaffordable_greyed_inert()
	_test_ac1_grey_is_achromatic_no_red()
	_test_ac2_balance_rise_lights_up_within_one_frame()
	_test_ac2_revenue_path_crosses_cost()
	_test_ac2_balance_fall_regreys()
	_test_boundary_balance_equals_cost()
	_test_ac3_locked_shows_lock_icon_shape()
	_test_ac3_lock_dominates_affordability()
	_test_ac3_locked_distinct_from_unaffordable()
	_test_ac8_colorblind_states_shape_and_lightness_not_color()
	_test_palette_renders_query_layer_not_def()
	_test_init_twice_guard()

	_free_test_nodes()

	print("\n=== PALETTE STATE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Every Node created by this test file that is NOT part of the SceneTree
## root's permanent lifecycle — freed in _free_test_nodes() so the headless
## run exits leak-free.
var _nodes_to_free: Array = []


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()


func _ED() -> Script:
	return load(DEF_SCRIPT_PATH) as Script


func _CAT() -> Script:
	return load(CATALOG_SCRIPT_PATH) as Script


func _EC() -> Script:
	return load(ECON_SCRIPT_PATH) as Script


func _SRG() -> Script:
	return load(SRG_SCRIPT_PATH) as Script


func _PALETTE() -> Script:
	return load(PALETTE_SCRIPT_PATH) as Script


func _TILE() -> Script:
	return load(TILE_SCRIPT_PATH) as Script


func _PLACEHOLDER_AVAIL() -> Script:
	return load(PLACEHOLDER_AVAIL_SCRIPT_PATH) as Script


## The PaletteTile.State enum values, read from the real script's constant
## map (never duplicated in the test — an enum reorder breaks the test).
var _tile_state_consts: Dictionary = {}


func _STATE() -> Dictionary:
	if _tile_state_consts.is_empty():
		var consts: Dictionary = _TILE().get_script_constant_map()
		_tile_state_consts = consts["State"]
	return _tile_state_consts


## Canonical def builder — all EquipmentDef fields populated with sane
## defaults; only id/name/cost/unlock vary per fixture.
func _make_def(ED: Script, id: String, name: String, cost: int, unlock: String) -> RefCounted:
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	return ED.new(
		id, name, zone, footprint, access, cost, unlock, effects,
		200, 30, 100, 300,
	)


## Frozen catalog holding the given defs (via the internal loader API).
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = _CAT().new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Initialized SimulationOrchestrator in the scene tree (delivers _ready()
## synchronously — same pattern as the save-load integration tests). The
## orchestrator is the Economy init dependency; nothing else is needed.
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	_nodes_to_free.append(orch)
	return orch


## Real Economy rig: orchestrator + SeededRNG + real Economy init'd with the
## default config (starting_capital 500, r_visit 12).
func _make_economy(seed: int) -> RefCounted:
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	return econ


## The story-001 availability placeholder (real query layer — derives from
## Economy.can_afford + unlock_requirement).
func _make_placeholder_availability(catalog: RefCounted, economy: RefCounted) -> RefCounted:
	return _PLACEHOLDER_AVAIL().new(catalog, economy)


## Builds a palette Node wired to the given catalog/economy/availability and
## added to the root (tracked for teardown). Untyped return so tests can
## reach the palette_refreshed signal dynamically.
func _make_palette(catalog: RefCounted, economy: RefCounted, availability: RefCounted):
	var palette = _PALETTE().new()
	palette.call("init", catalog, economy, availability)
	root.add_child(palette)
	_nodes_to_free.append(palette)
	return palette
## Standard 3-item catalog + fresh economy (balance 500) + palette rig.
##   treadmill_01: $350, always available
##   bench_press : $200, always available
##   yoga_mat    : $200, locked (milestone_a)
func _make_standard_rig(seed: int) -> Dictionary:
	var ED := _ED()
	var defs: Array = [
		_make_def(ED, "treadmill_01", "Treadmill", 350, ""),
		_make_def(ED, "bench_press", "Bench Press", 200, ""),
		_make_def(ED, "yoga_mat", "Yoga Mat", 200, "milestone_a"),
	]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(seed)
	var availability := _make_placeholder_availability(catalog, economy)
	var palette = _make_palette(catalog, economy, availability)
	return {"catalog": catalog, "economy": economy, "availability": availability, "palette": palette}


## Connects a spy to palette.palette_refreshed, counting emissions.
func _spy_palette_refreshed(palette) -> Array:
	var seen: Array = []
	palette.palette_refreshed.connect(func() -> void: seen.append(true))
	return seen


## Is the given modulate achromatic (r == g == b — zero hue)?
func _is_achromatic(c: Color) -> bool:
	return is_equal_approx(c.r, c.g) and is_equal_approx(c.g, c.b)


# === Core Rule 1: every tile renders icon + name + Butter price ===

func _test_core_rule_1_all_items_render_icon_name_price() -> void:
	print("\n[Core Rule 1] palette renders ALL catalog items: icon + name + price in Butter")
	var rig := _make_standard_rig(0xB5101)
	var palette: Node = rig["palette"]

	_check(int(palette.call("get_tile_count")) == 3, "Core Rule 1: 3 tiles for 3 catalog items (got %d)" % int(palette.call("get_tile_count")))

	var expected: Dictionary = {
		"treadmill_01": ["Treadmill", "$350"],
		"bench_press": ["Bench Press", "$200"],
		"yoga_mat": ["Yoga Mat", "$200"],
	}
	for id in expected:
		var tile: Node = palette.call("get_tile", id)
		_check(tile != null, "Core Rule 1: tile exists for '%s'" % id)
		if tile == null:
			continue
		_check(tile.call("get_name_text") == expected[id][0], "Core Rule 1: '%s' name renders '%s' (got '%s')" % [id, expected[id][0], tile.call("get_name_text")])
		_check(tile.call("get_price_text") == expected[id][1], "Core Rule 1: '%s' price renders '%s' (got '%s')" % [id, expected[id][1], tile.call("get_price_text")])
		_check(String(tile.call("get_icon_text")).length() > 0, "Core Rule 1: '%s' icon slot renders a placeholder glyph (got '%s')" % [id, tile.call("get_icon_text")])
		_check(int(tile.get("mouse_filter")) == Control.MOUSE_FILTER_STOP, "Core Rule 1: '%s' tile receives mouse input (STOP) — Story 002 gate-ready" % id)
		_check(int(tile.get("focus_mode")) == Control.FOCUS_ALL, "Core Rule 1: '%s' tile focusable (keyboard path)" % id)


func _test_core_rule_1_empty_catalog_calm_hint() -> void:
	print("\n[Core Rule 1 edge] empty catalog -> calm hint, nothing draggable, no error")
	var catalog := _make_catalog([])
	var economy := _make_economy(0xB5102)
	var availability := _make_placeholder_availability(catalog, economy)
	var palette: Node = _make_palette(catalog, economy, availability)

	_check(int(palette.call("get_tile_count")) == 0, "Core Rule 1[empty]: zero tiles (got %d)" % int(palette.call("get_tile_count")))
	_check(bool(palette.call("is_empty_hint_visible")), "Core Rule 1[empty]: calm hint visible")
	_check(not bool(palette.call("is_item_draggable", "anything")), "Core Rule 1[empty]: nothing draggable")
	_check(int(palette.call("get_state", "anything")) == -1, "Core Rule 1[empty]: unknown id state == -1")


# === AC1: unaffordable -> greyed, inert ===

func _test_ac1_unaffordable_greyed_inert() -> void:
	print("\n[AC1] item the player can't afford -> greyed (desaturated) + not draggable")
	var rig := _make_standard_rig(0xB5103)
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]

	# Drain balance 500 -> 100 (treadmill $350 is now unaffordable).
	_check(bool(economy.call("spend", 400)), "AC1[setup]: drain 400 succeeds (balance 100)")

	var tile: Node = palette.call("get_tile", "treadmill_01")
	_check(int(tile.get("state")) == int(_STATE()["UNAFFORDABLE"]), "AC1: treadmill state == UNAFFORDABLE (got %d)" % int(tile.get("state")))
	_check(bool(tile.call("is_greyed")), "AC1: treadmill is greyed")
	_check(not bool(tile.call("is_draggable")), "AC1: treadmill is NOT draggable (inert)")
	_check(not bool(palette.call("is_item_draggable", "treadmill_01")), "AC1: palette-level drag gate reports false")

	var mod: Color = tile.get("modulate")
	_check(_is_achromatic(mod), "AC1: greyed modulate is achromatic (r==g==b — no hue, no red) got %s" % mod)
	_check(mod.r < 1.0, "AC1: greyed modulate is reduced tint (r=%s < 1.0)" % mod.r)


func _test_ac1_grey_is_achromatic_no_red() -> void:
	print("\n[AC1] greyed state is EXACTLY achromatic — 'no red' holds literally")
	var rig := _make_standard_rig(0xB5104)
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 400)  # balance 100

	var tile: Node = palette.call("get_tile", "treadmill_01")
	var mod: Color = tile.get("modulate")
	_check(
		is_equal_approx(mod.r, mod.g) and is_equal_approx(mod.g, mod.b),
		"AC1: greyed modulate has EQUAL RGB channels (%s) — a red 'denied' state would have r > g/b" % mod
	)
	_check(mod.r == mod.g and mod.g == mod.b, "AC1: exact channel equality (not just approximate)")


# === AC2: balance_changed -> within one frame ===

func _test_ac2_balance_rise_lights_up_within_one_frame() -> void:
	print("\n[AC2] balance rises to meet cost -> balance_changed -> full-tint within one frame (no manual refresh)")
	var rig := _make_standard_rig(0xB5105)
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 400)  # balance 100 -> treadmill $350 greyed

	var seen := _spy_palette_refreshed(palette)
	var tile: Node = palette.call("get_tile", "treadmill_01")
	_check(int(tile.get("state")) == int(_STATE()["UNAFFORDABLE"]), "AC2[setup]: treadmill greyed at balance 100")

	# balance 100 -> 350 crosses the cost; credit() emits balance_changed
	# synchronously; the palette's S6 handler re-derives synchronously.
	_check(bool(economy.call("credit", 250, "test:ac2")), "AC2: credit(250) succeeds -> balance 350")

	_check(int(tile.get("state")) == int(_STATE()["AFFORDABLE"]), "AC2: tile is AFFORDABLE the moment balance_changed returns (within one frame)")
	_check(tile.get("modulate") == Color.WHITE, "AC2: tile modulate is full-tint white (got %s)" % tile.get("modulate"))
	_check(bool(tile.call("is_draggable")), "AC2: tile is now draggable")
	_check(bool(palette.call("is_item_draggable", "treadmill_01")), "AC2: palette drag gate now true")
	_check(seen.size() == 1, "AC2: palette_refreshed fired exactly once for the one balance change (got %d)" % seen.size())


func _test_ac2_revenue_path_crosses_cost() -> void:
	print("\n[AC2] game-loop revenue path (S5 -> Economy) also lights tiles up")
	var rig := _make_standard_rig(0xB5106)
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 200)  # balance 300 -> treadmill $350 greyed

	var tile: Node = palette.call("get_tile", "treadmill_01")
	_check(int(tile.get("state")) == int(_STATE()["UNAFFORDABLE"]), "AC2[rev]: treadmill greyed at balance 300")

	# 5 quota-met departures x $12 = +60 -> balance 360 >= 350.
	for i in 5:
		economy.call("on_member_completed_visit", 9000 + i)
	_check(int(tile.get("state")) == int(_STATE()["AFFORDABLE"]), "AC2[rev]: after 5 visits (+$60) tile is AFFORDABLE (balance %d)" % int(economy.get("balance")))
	_check(bool(tile.call("is_draggable")), "AC2[rev]: tile draggable after revenue crosses cost")


func _test_ac2_balance_fall_regreys() -> void:
	print("\n[AC2] balance falls below cost -> re-greys (both directions)")
	var rig := _make_standard_rig(0xB5107)
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]

	# At 500 treadmill $350 is affordable.
	var tile: Node = palette.call("get_tile", "treadmill_01")
	_check(int(tile.get("state")) == int(_STATE()["AFFORDABLE"]), "AC2[fall][setup]: treadmill affordable at balance 500")

	# Spend 200 -> 300: treadmill crosses back below cost.
	economy.call("spend", 200)
	_check(int(tile.get("state")) == int(_STATE()["UNAFFORDABLE"]), "AC2[fall]: treadmill re-greyed at balance 300 (within one frame)")
	_check(not bool(tile.call("is_draggable")), "AC2[fall]: treadmill inert again")
	# And the cheap bench ($200) is still affordable at 300.
	var bench: Node = palette.call("get_tile", "bench_press")
	_check(int(bench.get("state")) == int(_STATE()["AFFORDABLE"]), "AC2[fall]: bench ($200) stays affordable at 300 — only crossing items change")


func _test_boundary_balance_equals_cost() -> void:
	print("\n[AC2 edge] balance exactly == cost -> affordable; balance == cost - 1 -> greyed")
	var rig := _make_standard_rig(0xB5108)
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]

	# balance 500 -> 350 (exactly the treadmill cost).
	economy.call("spend", 150)
	var tile: Node = palette.call("get_tile", "treadmill_01")
	_check(int(tile.get("state")) == int(_STATE()["AFFORDABLE"]), "AC2[edge]: balance == cost (350) -> AFFORDABLE")

	# balance 350 -> 349: one Butter short.
	economy.call("spend", 1)
	_check(int(tile.get("state")) == int(_STATE()["UNAFFORDABLE"]), "AC2[edge]: balance == cost - 1 (349) -> UNAFFORDABLE")


# === AC3: locked -> lock icon (shape) ===

func _test_ac3_locked_shows_lock_icon_shape() -> void:
	print("\n[AC3] locked item (unlock_requirement != '') -> lock icon shown, not draggable")
	var rig := _make_standard_rig(0xB5109)
	var palette: Node = rig["palette"]

	var tile: Node = palette.call("get_tile", "yoga_mat")
	_check(int(tile.get("state")) == int(_STATE()["LOCKED"]), "AC3: yoga_mat (unlock 'milestone_a') state == LOCKED (got %d)" % int(tile.get("state")))
	_check(bool(tile.call("is_locked_visual")), "AC3: lock icon (shape) is visible")
	_check(not bool(tile.call("is_draggable")), "AC3: locked item is NOT draggable")
	_check(bool(tile.call("is_greyed")), "AC3: locked item is greyed (like unaffordable, but with lock)")


func _test_ac3_lock_dominates_affordability() -> void:
	print("\n[AC3] lock dominates affordability — locked stays locked even when affordable")
	var rig := _make_standard_rig(0xB510A)
	var palette: Node = rig["palette"]

	# At balance 500 the yoga_mat cost $200 IS affordable — but locked wins.
	var tile: Node = palette.call("get_tile", "yoga_mat")
	_check(int(tile.get("state")) == int(_STATE()["LOCKED"]), "AC3[dom]: yoga_mat still LOCKED at balance 500 (affordable but locked)")
	_check(bool(tile.call("is_locked_visual")), "AC3[dom]: lock icon still visible")
	_check(not bool(tile.call("is_draggable")), "AC3[dom]: still not draggable")


func _test_ac3_locked_distinct_from_unaffordable() -> void:
	print("\n[AC3] locked != merely-unaffordable — distinct visual (lock shape vs no lock)")
	var rig := _make_standard_rig(0xB510B)
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 400)  # balance 100 -> treadmill greyed

	var locked_tile: Node = palette.call("get_tile", "yoga_mat")
	var grey_tile: Node = palette.call("get_tile", "treadmill_01")

	_check(int(locked_tile.get("state")) == int(_STATE()["LOCKED"]), "AC3[distinct]: yoga_mat LOCKED")
	_check(int(grey_tile.get("state")) == int(_STATE()["UNAFFORDABLE"]), "AC3[distinct]: treadmill UNAFFORDABLE")
	_check(bool(locked_tile.call("is_locked_visual")) and not bool(grey_tile.call("is_locked_visual")),
		"AC3[distinct]: lock icon ONLY on the locked tile — shape distinguishes the two grey states")


# === AC8: colorblind-safe ===

func _test_ac8_colorblind_states_shape_and_lightness_not_color() -> void:
	print("\n[AC8] colorblind pass: states distinguishable by tint-desaturation + lock shape, NOT color alone")
	# Dedicated rig: one cheap unlocked item (affordable at balance 100), one
	# expensive unlocked item (unaffordable at 100), one locked item.
	var ED := _ED()
	var defs: Array = [
		_make_def(ED, "kettlebell", "Kettlebell", 50, ""),
		_make_def(ED, "treadmill_01", "Treadmill", 350, ""),
		_make_def(ED, "yoga_mat", "Yoga Mat", 200, "milestone_a"),
	]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(0xB510C)
	var availability := _make_placeholder_availability(catalog, economy)
	var palette: Node = _make_palette(catalog, economy, availability)
	economy.call("spend", 400)  # balance 100 -> treadmill unaffordable, kettlebell affordable

	var affordable: Node = palette.call("get_tile", "kettlebell")      # $50, unlock "" — affordable
	var unaffordable: Node = palette.call("get_tile", "treadmill_01")  # $350, greyed
	var locked: Node = palette.call("get_tile", "yoga_mat")            # locked

	# (1) NO state uses hue: every modulate across all three states is
	#     achromatic (r == g == b). No color information anywhere.
	var states: Array = [
		["affordable", affordable],
		["unaffordable", unaffordable],
		["locked", locked],
	]
	for entry in states:
		var node: Node = entry[1]
		var mod: Color = node.get("modulate")
		_check(_is_achromatic(mod), "AC8: %s modulate is achromatic (r==g==b) — got %s" % [entry[0], mod])

	# (2) Distinguishable by tint-desaturation: affordable is full-tint
	#     white; the two greyed states use the SAME reduced lightness.
	var aff_mod: Color = affordable.get("modulate")
	var unaff_mod: Color = unaffordable.get("modulate")
	var lock_mod: Color = locked.get("modulate")
	_check(aff_mod == Color.WHITE, "AC8: affordable = full tint (white) — got %s" % aff_mod)
	_check(unaff_mod.r < aff_mod.r, "AC8: unaffordable is desaturated vs affordable (lightness difference)")
	_check(unaff_mod == lock_mod, "AC8: unaffordable and locked share the same grey (lightness family)")

	# (3) Distinguishable by SHAPE: the lock icon is present ONLY on locked.
	_check(not bool(affordable.call("is_locked_visual")), "AC8: affordable has NO lock icon")
	_check(not bool(unaffordable.call("is_locked_visual")), "AC8: unaffordable has NO lock icon")
	_check(bool(locked.call("is_locked_visual")), "AC8: locked HAS the lock icon (shape)")

	# (4) The three-way read is possible with color removed entirely:
	#     full-tint + no lock = affordable; grey + no lock = unaffordable;
	#     grey + lock = locked.
	_check(
		(not bool(affordable.call("is_greyed")) and not bool(affordable.call("is_locked_visual")))
		and (bool(unaffordable.call("is_greyed")) and not bool(unaffordable.call("is_locked_visual")))
		and (bool(locked.call("is_greyed")) and bool(locked.call("is_locked_visual"))),
		"AC8: grey-ness + lock-shape alone identifies all three states (color-free read)"
	)


# === Shop seam: palette renders the query layer, not the raw def ===

func _test_palette_renders_query_layer_not_def() -> void:
	print("\n[seam] palette renders whatever the injected query layer reports (Story 002 swap point)")
	var ED := _ED()
	# A def that the raw catalog says is unlocked (unlock_requirement == "")
	# and cheap — but the query layer reports LOCKED (simulating a real Shop
	# with a runtime unlock source, Story 002).
	var defs: Array = [
		_make_def(ED, "treadmill_01", "Treadmill", 350, ""),
		_make_def(ED, "bench_press", "Bench Press", 200, ""),
	]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(0xB510D)

	var scripted := ScriptedAvailability.new()
	scripted.unlock_results = {"treadmill_01": false, "bench_press": true}
	scripted.purchase_results = {"treadmill_01": false, "bench_press": true}

	var palette: Node = _make_palette(catalog, economy, scripted)

	_check(int(palette.call("get_state", "treadmill_01")) == int(_STATE()["LOCKED"]),
		"seam: def is unlocked on paper but query says locked -> LOCKED (query wins)")
	var bench_tile: Node = palette.call("get_tile", "bench_press")
	_check(int(bench_tile.get("state")) == int(_STATE()["AFFORDABLE"]),
		"seam: query says purchasable -> AFFORDABLE")


func _test_init_twice_guard() -> void:
	print("\n[guard] init() twice -> logged error, no crash, palette still functional")
	var rig := _make_standard_rig(0xB510E)
	var palette: Node = rig["palette"]
	var before := int(palette.call("get_tile_count"))
	palette.call("init", rig["catalog"], rig["economy"], rig["availability"])
	_check(int(palette.call("get_tile_count")) == before, "guard: tile count unchanged after double init (got %d)" % int(palette.call("get_tile_count")))
	_check(int(palette.call("get_state", "bench_press")) != -1, "guard: palette still answers state queries after double init")


# === ScriptedAvailability: controlled query layer for the seam test ===

## Subclass of the palette availability contract whose answers are fully
## scripted — proves the palette consumes the QUERY result, not the raw
## EquipmentDef fields.
class ScriptedAvailability:
	extends PaletteAvailabilityScript

	var unlock_results: Dictionary = {}
	var purchase_results: Dictionary = {}

	func is_unlocked(equipment_id: String) -> bool:
		return unlock_results.get(equipment_id, false)

	func can_purchase(equipment_id: String) -> bool:
		return purchase_results.get(equipment_id, false)
