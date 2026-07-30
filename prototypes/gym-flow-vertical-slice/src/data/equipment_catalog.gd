# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — EquipmentCatalog data layer
# Date: 2026-07-19
#
# Faithful to equipment-catalog.md: per-equipment def holds footprint (local) + access (local)
# + use_duration_mean/stddev/min/max_ticks. Load-time validation rules 7e-h enforced
# (mean>0, stddev>=0, min in [1,mean], max>=mean, min<=max). For the slice, data is
# authored in-code (no external file parse) — the validation path is still exercised.

class_name EquipmentCatalog
extends RefCounted

var _defs: Dictionary = {}  # id -> Dictionary

# Author a def with LOCAL footprint/access cells. Returns true if load-time validation passes.
func add_def(id: String, display_name: String, footprint_local: Array, access_local: Array,
		mean_t: int, stddev_t: int, min_t: int, max_t: int) -> bool:
	if not _validate(mean_t, stddev_t, min_t, max_t):
		return false
	if footprint_local.is_empty():
		return false
	_defs[id] = {
		"id": id, "display_name": display_name,
		"footprint_local": footprint_local, "access_local": access_local,
		"use_duration_mean_ticks": mean_t, "use_duration_stddev_ticks": stddev_t,
		"use_duration_min_ticks": min_t, "use_duration_max_ticks": max_t,
	}
	return true

func _validate(mean_t: int, stddev_t: int, min_t: int, max_t: int) -> bool:
	if mean_t <= 0: return false            # rule 7e
	if stddev_t < 0: return false            # rule 7f
	if min_t < 1: return false               # rule 7g
	if min_t > mean_t: return false          # rule 7g
	if max_t < mean_t: return false          # rule 7h
	if min_t > max_t: return false           # rule 7h
	return true

func has_def(id: String) -> bool:
	return _defs.has(id)

func get_definition(id: String) -> Dictionary:
	return _defs.get(id, {})

func get_use_duration(id: String) -> Dictionary:
	var d: Dictionary = _defs.get(id, {})
	return {
		"mean": d.get("use_duration_mean_ticks", 200),
		"stddev": d.get("use_duration_stddev_ticks", 30),
		"min": d.get("use_duration_min_ticks", 100),
		"max": d.get("use_duration_max_ticks", 300),
	}
