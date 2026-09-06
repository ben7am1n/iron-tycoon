## GA-001: cold identity restoration and historical use-start snapshots.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if result.fail else 0)

## Standalone and shared-runner entry point.
func run_all() -> Dictionary:
	test_cold_load_preserves_identity_move_cancel_and_sale()
	test_invalid_identity_rejects_before_mutation()
	test_legacy_identity_requires_unique_geometry()
	test_pending_use_restores_historical_congestion()
	print("FOUNDATION RESTORE: %d passed, %d failed" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}

func _check(value: bool, label: String) -> void:
	if value:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: " + label)

func _rig() -> Dictionary:
	var orch := SimulationOrchestrator.new()
	root.add_child(orch)
	orch._ready()
	var rng := SeededRNG.new()
	rng.init(9173)
	var time := TimeSystem.new()
	time.init(orch, rng)
	orch.time_system = time
	var grid := GridSystem.new()
	grid.init(12, 10)
	for y in 10:
		for x in 12:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	orch.grid_system = grid
	var cat := EquipmentCatalog.new()
	var fp: Array[Vector2i] = [Vector2i.ZERO]
	var ac: Array[Vector2i] = [Vector2i(1, 0)]
	var long_fp: Array[Vector2i] = [Vector2i.ZERO, Vector2i(0, 1)]
	var effects: Array[Dictionary] = []
	cat._add_definition(EquipmentDef.new("bike", "Bike", ["cardio"], fp, ac, 120, "", effects, 40, 8, 20, 80))
	cat._add_definition(EquipmentDef.new("yoga_mat", "Yoga", ["flexibility"], fp, ac, 40, "", effects, 40, 8, 20, 80))
	cat._add_definition(EquipmentDef.new("treadmill", "Treadmill", ["cardio"], long_fp, ac, 180, "", effects, 40, 8, 20, 80))
	cat._freeze()
	orch.equipment_catalog = cat
	var members := MemberSim.new()
	members.init(orch, rng)
	orch.member_sim = members
	var congestion := Congestion.new()
	congestion.init(orch, rng)
	orch.congestion = congestion
	var sat := Satisfaction.new()
	sat.init(orch, rng)
	orch.satisfaction = sat
	var economy := Economy.new()
	economy.init(orch, rng)
	orch.economy = economy
	var placement := PlacementSystem.new()
	placement.init(grid, cat)
	orch.placement_system = placement
	var selection := SelectionSystem.new()
	selection.init(grid, placement, cat, economy)
	selection._post_init()
	orch.selection_system = selection
	var save := SaveLoad.new()
	save.init(orch)
	return {"orch": orch, "grid": grid, "placement": placement, "selection": selection, "save": save, "sat": sat, "economy": economy}

func _place(rig: Dictionary, id: String, cell: Vector2i, rotate: bool = false) -> void:
	rig.placement.begin_drag(id)
	rig.placement.on_mouse_moved(cell)
	if rotate:
		rig.placement.on_rotate_pressed()
	rig.placement.on_drop()

func _snapshot() -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(120)
	snap.fill(1)
	return snap

func _blob(rig: Dictionary) -> Dictionary:
	return SaveLoad._normalize_types(JSON.parse_string(JSON.stringify(rig.save._perform_save(), "", true, true)))

func test_cold_load_preserves_identity_move_cancel_and_sale() -> void:
	var a := _rig()
	_place(a, "yoga_mat", Vector2i(2, 2), true)
	_place(a, "bike", Vector2i(6, 2))
	a.grid.set_equipment_level(0, 3)
	var b := _rig()
	var result: RefCounted = b.save.load(_blob(a), _snapshot())
	_check(result.ok, "cold load accepted")
	var placed: Array[PlacedInstance] = b.grid.get_placed_instances()
	_check(placed[0].equipment_id == "yoga_mat" and placed[1].equipment_id == "bike", "identical geometry retains exact identities")
	_check(placed[0].rotation == 90 and placed[0].anchor == Vector2i(2, 2), "anchor and rotation restored")
	_check(b.grid.get_equipment_level(0) == 3, "upgrade restored")
	b.placement.begin_relocate(0)
	_check(b.placement.is_dragging(), "cold-loaded item relocates")
	b.placement.on_mouse_moved(Vector2i(2, 5))
	b.placement.on_drop()
	b.placement.begin_relocate(0)
	b.placement.on_cancel()
	b.selection.on_cell_clicked(Vector2i(2, 5))
	_check(b.selection.get_selected_instance_id() == 0, "canceled relocation remains selectable")
	var balance: int = b.economy.balance
	_check(b.selection.sell_selected(), "restored yoga sells")
	_check(b.economy.balance == balance + 20, "refund uses yoga price, not bike")
	_check(b.grid.get_placed_instances().size() == 1, "sale removes only yoga")

func test_invalid_identity_rejects_before_mutation() -> void:
	var rig := _rig()
	_place(rig, "yoga_mat", Vector2i(2, 2))
	for id in ["missing", "treadmill"]:
		var blob := _blob(rig)
		blob.grid_system.records[0]["equipment_id"] = id
		var before := JSON.stringify(rig.save._perform_save(), "", true, true)
		var result: RefCounted = rig.save.load(blob, _snapshot())
		_check(not result.ok, "invalid identity rejected: " + id)
		_check(before == JSON.stringify(rig.save._perform_save(), "", true, true), "invalid identity mutates no state")

func test_legacy_identity_requires_unique_geometry() -> void:
	var rig := _rig()
	_place(rig, "yoga_mat", Vector2i(2, 2))
	var blob := _blob(rig)
	blob.grid_system.records[0].erase("equipment_id")
	_check(not rig.save.load(blob, _snapshot()).ok, "ambiguous legacy yoga/bike rejected")
	var unique := _rig()
	_place(unique, "treadmill", Vector2i(2, 2))
	blob = _blob(unique)
	blob.grid_system.records[0].erase("equipment_id")
	_check(unique.save.load(blob, _snapshot()).ok, "unique legacy geometry recovered")
	_check(unique.grid.get_placed_instances()[0].equipment_id == "treadmill", "legacy recovery persists identity")

func test_pending_use_restores_historical_congestion() -> void:
	var a := _rig()
	a.sat.on_member_entered(9)
	a.sat.on_use_started(9, 0)
	var data: Dictionary = a.sat.serialize()
	_check(data.has("pending_uses"), "use-start inputs serialized")
	if not data.has("pending_uses"):
		return
	data.pending_uses[9].congestion = 0.8
	var b := _rig()
	_check(b.sat.deserialize(data).ok, "pending use loads")
	_check(b.sat.get_pending_use(9).congestion == 0.8, "historic snapshot retained despite current zero congestion")
	a.sat.deserialize(data)
	a.sat.on_use_completed(9)
	b.sat.on_use_completed(9)
	_check(a.sat.get_accumulator(9) == b.sat.get_accumulator(9), "resumed use quality matches control")
	data.pending_uses[9].congestion = 2.0
	var before: Dictionary = b.sat.serialize()
	_check(not b.sat.deserialize(data).ok, "invalid pending snapshot rejected")
	_check(b.sat.serialize() == before, "invalid snapshot preserves state")
