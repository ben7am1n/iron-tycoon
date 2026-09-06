## Validates required authored data before any simulation is constructed (GA-002).
## The root parameter is a read-only probe seam; it never modifies game resources.
extends RefCounted

const CatalogLoader := preload("res://src/systems/equipment_catalog_loader.gd")
const REQUIRED_FILES := ["equipment_catalog.json", "equipment_upgrades.json", "expansion.json", "goals.json"]

## Returns {ok, errors, data, catalog}; invalid data never enables a playable scene.
static func check(data_root: String = "res://data") -> Dictionary:
	var result := {"ok": false, "errors": [], "data": {}, "catalog": null}
	for filename: String in REQUIRED_FILES:
		var path := data_root.path_join(filename)
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			result.errors.append("缺少或无法读取必要资源：%s" % path)
			continue
		var parser := JSON.new()
		var err := parser.parse(file.get_as_text())
		file.close()
		if err != OK or not parser.data is Dictionary:
			result.errors.append("资源格式错误：%s，第 %d 行：%s" % [path, parser.get_error_line(), parser.get_error_message()])
			continue
		result.data[filename] = parser.data
	if not result.errors.is_empty():
		return result
	var catalog_result = CatalogLoader.load_from_file(data_root.path_join("equipment_catalog.json"), true)
	if not catalog_result.ok:
		result.errors.append("器械目录无效：%s" % str(catalog_result.errors))
		return result
	result.catalog = catalog_result.catalog
	if result.catalog.get_all_ids().is_empty():
		result.errors.append("器械目录不能为空")
		return result
	var upgrades: Dictionary = result.data["equipment_upgrades.json"]
	for key: String in ["max_level", "base_cost_ratio", "cost_growth", "attraction_per_level", "revenue_per_level"]:
		if not _number(upgrades.get(key)) or float(upgrades[key]) < 0:
			result.errors.append("equipment_upgrades.json：%s 必须是非负数" % key)
	if _number(upgrades.get("max_level")) and (float(upgrades.max_level) < 1 or float(upgrades.max_level) != floor(float(upgrades.max_level))):
		result.errors.append("equipment_upgrades.json：max_level 必须是正整数")
	var expansion: Dictionary = result.data["expansion.json"]
	if expansion.get("schema_version") != 1 or not _unit(expansion.get("satisfaction_threshold")):
		result.errors.append("expansion.json：schema_version / satisfaction_threshold 无效")
	var regions := _records(expansion.get("regions"), "expansion.json regions", result.errors)
	for region: Dictionary in regions:
		for key: String in ["cost", "add_width", "add_height"]:
			if not _whole(region.get(key)):
				result.errors.append("expansion.json：%s.%s 必须是非负整数" % [region.get("id"), key])
		if _whole(region.get("add_width")) and _whole(region.get("add_height")) and int(region.add_width) + int(region.add_height) <= 0:
			result.errors.append("expansion.json：区域必须扩大场地")
		if not _unit(region.get("satisfaction_threshold")):
			result.errors.append("expansion.json：区域满意度阈值无效")
	var goals: Dictionary = result.data["goals.json"]
	if goals.get("schema_version") != 1:
		result.errors.append("goals.json：schema_version 无效")
	for goal: Dictionary in _records(goals.get("goals"), "goals.json goals", result.errors):
		if not goal.get("metric", "") in ["EQUIPMENT_COUNT", "SATISFACTION", "CUMULATIVE_INCOME", "EXPANSION_COUNT"] or not _number(goal.get("target")) or float(goal.get("target", -1)) <= 0:
			result.errors.append("goals.json：%s 的目标无效" % goal.get("id"))
		if not goal.get("reward") is Dictionary or not _whole(goal.get("reward", {}).get("money")):
			result.errors.append("goals.json：%s 的奖励无效" % goal.get("id"))
		elif goal.reward.has("unlock_region"):
			var found := false
			for region: Dictionary in regions:
				found = found or region.get("id") == goal.reward.unlock_region
			if not found:
				result.errors.append("goals.json：未知奖励区域")
		if goal.has("equipment_ids"):
			if not goal.equipment_ids is Array:
				result.errors.append("goals.json：equipment_ids 必须为数组")
			else:
				for equipment_id: Variant in goal.equipment_ids:
					if not equipment_id is String or result.catalog.get_definition(equipment_id) == null:
						result.errors.append("goals.json：未知器械 %s" % str(equipment_id))
	result.ok = result.errors.is_empty()
	return result

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _whole(value: Variant) -> bool:
	return _number(value) and float(value) >= 0 and floor(float(value)) == float(value)

static func _unit(value: Variant) -> bool:
	return _number(value) and float(value) >= 0 and float(value) <= 1

static func _records(value: Variant, source: String, errors: Array) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	if not value is Array or value.is_empty():
		errors.append("%s：必须包含记录" % source)
		return records
	var ids := {}
	for item: Variant in value:
		if not item is Dictionary or not item.get("id") is String or item.id.strip_edges().is_empty() or ids.has(item.id):
			errors.append("%s：记录无效或 ID 重复" % source)
			continue
		ids[item.id] = true
		records.append(item)
	return records
