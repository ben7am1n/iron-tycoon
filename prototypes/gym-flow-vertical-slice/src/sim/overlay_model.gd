# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — OverlayModel (shape-first readability)
# Date: 2026-07-19
#
# Faithful to congestion-overlay.md (GDD #8):
#  - DEFAULT-VISIBLE (loaded = shown); no player toggle needed for the slice.
#  - SHAPE-FIRST: a cell shows a GLYPH + color, never a bare heat blob, so the
#    player can tell at a glance WHICH machine has a queue (resolves concept-proto
#    friction "can't tell who's queuing").
#  - Aggregates: static occupancy (GridSystem) + dynamic queue/use (MemberSim)
#    + density background (Congestion). Per-tick rebuild, pure function of inputs.
#  - Determinism: bit-identical given same grid+member+congestion state.
# Cross-script class_name annotations omitted (GDScript dynamic) for headless parse.

class_name OverlayModel
extends RefCounted

const GLYPH_IDLE := "○"      # access cell, no queue
const GLYPH_QUEUE := "▶"    # access cell, queue present (len shown separately)
const GLYPH_USE := "■"       # access cell, machine in use (occupant != -1)
const GLYPH_ENTRANCE := "IN"
const GLYPH_EXIT := "OUT"
const GLYPH_SOLID := "▦"     # footprint / wall

var _grid
var _region: Rect2i
var _cong

# per-cell overlay entry: {kind, glyph, queue_len, density}
var _cells: Dictionary = {}

func _init(grid) -> void:
	_grid = grid
	_region = grid.get_dimensions()

# Rebuild every tick from live state. Pure aggregation, no side effects elsewhere.
func build(member, cong) -> void:
	_cong = cong
	_cells = {}
	for x in range(_region.position.x, _region.end.x):
		for y in range(_region.position.y, _region.end.y):
			var c := Vector2i(x, y)
			_cells[c] = _classify(c, member, cong)

func _classify(c: Vector2i, member, cong) -> Dictionary:
	var occ: int = _grid.get_occupant_id(c)
	if occ != -1:
		# footprint of an equipment instance
		var qlen: int = member.get_queue_length(occ)
		var glyph := GLYPH_SOLID
		if qlen >= 1:
			glyph = GLYPH_USE if member.get_equip_occupancy(occ)["occupant"] != -1 else GLYPH_QUEUE
		return {"kind": "equip", "glyph": glyph, "queue_len": qlen,
		        "density": cong.get_density(c)}
	var aids: Array = _grid.get_access_ids(c)
	if not aids.is_empty():
		var eid: int = aids[0]
		var qlen: int = member.get_queue_length(eid)
		var glyph := GLYPH_IDLE
		if qlen >= 1:
			glyph = GLYPH_USE if member.get_equip_occupancy(eid)["occupant"] != -1 else GLYPH_QUEUE
		return {"kind": "access", "glyph": glyph, "queue_len": qlen,
		        "density": cong.get_density(c)}
	return {"kind": "open", "glyph": "", "queue_len": 0, "density": cong.get_density(c)}

func get_glyph(cell: Vector2i) -> String:
	return _cells.get(cell, {"glyph": ""})["glyph"]

func get_queue_len(cell: Vector2i) -> int:
	return _cells.get(cell, {"queue_len": 0})["queue_len"]

# HOT = an access/equip cell whose queue length >= threshold (default 2).
# This is the "shape-first" signal the player reads at a glance.
func is_hot(cell: Vector2i, threshold: int = 2) -> bool:
	var e: Dictionary = _cells.get(cell, {"kind": "open", "queue_len": 0})
	return (e["kind"] == "access" or e["kind"] == "equip") and e["queue_len"] >= threshold

func density_at(cell: Vector2i) -> float:
	return _cells.get(cell, {"density": 0.0})["density"]

# Peak per-equipment congestion across all machines (through the readability layer).
# Direction matches the fun core: clumped layout -> higher peak than spread.
func peak_congestion(member) -> float:
	var peak := 0.0
	for eid in member._equip_state.keys():
		var v: float = _cong.get_congestion(eid)
		if v > peak:
			peak = v
	return peak

func access_summary(member) -> Dictionary:
	var out := {}
	for eid in member._equip_state.keys():
		var ac: Array = _grid.get_access_cells(eid)
		if ac.is_empty():
			continue
		var cell: Vector2i = ac[0]
		out[eid] = {"queue_len": member.get_queue_length(eid),
		              "glyph": get_glyph(cell), "hot": is_hot(cell)}
	return out
