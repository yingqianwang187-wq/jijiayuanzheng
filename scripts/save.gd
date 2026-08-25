# ==================================================================
# scripts/save.gd —— 本地存档（Save，存档唯一负责方）
# 作者   ：B（数值 + 玩法 + 存档）
# 依据   ：docs/契约.md §3.2 / §3.6、scripts/data.gd、scripts/contract.gd（只读）
# 职责   ：存档读写（user://save.json，FileAccess + JSON）。
#          只有本文件知道存档文件路径与格式；其他脚本不得直接读写存档文件。
# 铁律   ：load 失败（缺失 / 损坏 / 解析失败）必须返回默认值并继续运行，不允许报错崩溃；
#          旧版本存档（v0.14 兼容）自动补齐缺失字段并保留已有进度，不丢档（设计文档 §10.12）。
# 自动加载：本文件注册为名为 Save 的 autoload（注册顺序 Contract → Data → Save → Game）。
# 依赖   ：Contract（版本号）、Data（默认机娘配置 / 关卡上限）。
# 说明   ：save_game() 需要"当前状态"快照，而运行状态唯一持有者是 Game（契约 §3.1），
#          故通过 Game 的唯一只读快照入口 Game.get_save_snapshot() 获取（见交付说明）。
#          读档 / 默认值逻辑完全不依赖 Game（本文件的独立职责，契约 §3.2）。
# 变更规则：改本文件 = 改存档格式。若变更存档结构，需同步升级版本号并通知 A / B。
# ==================================================================
extends Node

## 存档文件路径与格式（契约 §3.2：user://save.json，FileAccess + JSON）
const SAVE_PATH := "user://save.json"

## 写档：把当前状态（来自 Game 快照）写入 user://save.json
## 签名：save_game()（契约 §3.2 / §3.6，无参数；UI / Game 均可调用）
## 存档形状（v0.8）：{ gold, exp_balance, idle_pending, idle_pending_exp, idle_last_time,
##   unlocked_level, first_cleared, mechs{level, exp}, diamond, summon_ticket,
##   fragments{id:int}, owned_mechs{id:true}, pity, novice_free_pull,
##   novice_pool_left, novice_first_ten_done, formation[{id,row,col}],
##   formation_presets{index:[...]}, level_stars{level:star}, cleared_boss{level:true},
##   chapter_chest_claimed }
func save_game() -> void:
	var snapshot: Dictionary = Game.get_save_snapshot()
	var save_dict := {
		"version": Contract.CONTRACT_VERSION,
		"gold": int(snapshot.get("gold", 0)),
		"exp_balance": maxi(int(snapshot.get("exp_balance", 0)), 0),
		"unlocked_level": int(snapshot.get("unlocked_level", 1)),
		"mechs": {},
		"first_cleared": [],
		"idle_pending": maxi(int(snapshot.get("idle_pending", 0)), 0),
		"idle_pending_exp": maxi(int(snapshot.get("idle_pending_exp", 0)), 0),
		"idle_last_time": int(snapshot.get("idle_last_time", 0)),
		"diamond": maxi(int(snapshot.get("diamond", 0)), 0),
		"summon_ticket": maxi(int(snapshot.get("summon_ticket", 0)), 0),
		"fragments": {},
		"owned_mechs": {},
		"pity": clampi(int(snapshot.get("pity", 0)), 0, Data.SUMMON_PITY_SSR_LIMIT),
		"novice_free_pull": bool(snapshot.get("novice_free_pull", true)),
		"novice_pool_left": maxi(int(snapshot.get("novice_pool_left", 0)), 0),
		"novice_first_ten_done": bool(snapshot.get("novice_first_ten_done", false)),
		"formation": [],
		"formation_presets": {},
		"level_stars": {},
		"cleared_boss": {},
		"chapter_chest_claimed": bool(snapshot.get("chapter_chest_claimed", false)),
	}
	var mechs: Dictionary = snapshot.get("mechs", {})
	for key in mechs:
		var entry: Dictionary = mechs[key]
		# 写盘统一用字符串键，避免 StringName 键在 JSON 序列化时的差异
		save_dict["mechs"][str(key)] = {
			"level": maxi(int(entry.get("level", 1)), 1),
			"exp": maxi(int(entry.get("exp", 0)), 0),
		}
	var first_cleared: Variant = snapshot.get("first_cleared", [])
	if first_cleared is Array:
		for l in first_cleared:
			save_dict["first_cleared"].append(int(l))
	var fragments: Dictionary = snapshot.get("fragments", {})
	for key in fragments:
		var mech_id := StringName(str(key))
		if Data.MECH_GIRLS.has(mech_id):
			save_dict["fragments"][str(key)] = maxi(int(fragments[key]), 0)
	var owned_mechs: Dictionary = snapshot.get("owned_mechs", {})
	for key in owned_mechs:
		var mech_id := StringName(str(key))
		if Data.MECH_GIRLS.has(mech_id):
			save_dict["owned_mechs"][str(key)] = true
	# 阵型 / 星级 / BOSS（v0.8 战斗 2.0）
	var formation: Variant = snapshot.get("formation", [])
	if formation is Array:
		for slot in formation:
			if slot is Dictionary and Data.MECH_GIRLS.has(StringName(str(slot.get("id", "")))):
				save_dict["formation"].append({
					"id": str(slot.get("id", "")),
					"row": clampi(int(slot.get("row", 0)), 0, 2),
					"col": clampi(int(slot.get("col", 0)), 0, 2),
				})
	var formation_presets: Dictionary = snapshot.get("formation_presets", {})
	for key in formation_presets:
		var preset: Variant = formation_presets[key]
		if preset is Array:
			var preset_save: Array = []
			for slot in preset:
				if slot is Dictionary and Data.MECH_GIRLS.has(StringName(str(slot.get("id", "")))):
					preset_save.append({
						"id": str(slot.get("id", "")),
						"row": clampi(int(slot.get("row", 0)), 0, 2),
						"col": clampi(int(slot.get("col", 0)), 0, 2),
					})
			save_dict["formation_presets"][str(key)] = preset_save
	var level_stars: Dictionary = snapshot.get("level_stars", {})
	for key in level_stars:
		var level := int(key)
		if level >= 1 and level <= Data.MAX_LEVEL:
			save_dict["level_stars"][str(level)] = clampi(int(level_stars[key]), 1, 3)
	var cleared_boss: Dictionary = snapshot.get("cleared_boss", {})
	for key in cleared_boss:
		var level := int(key)
		if level >= 1 and level <= Data.MAX_LEVEL:
			save_dict["cleared_boss"][str(level)] = true
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Save.save_game: 无法打开存档文件写入：" + SAVE_PATH)
		return
	file.store_string(JSON.stringify(save_dict))
	file.close()

## 读档：返回契约 §3.2 v0.8 存档形状各字段（详见 save_game 注释）
## 失败（文件缺失 / 损坏 / 解析失败）→ 返回默认值并继续运行，不报错崩溃。
## 旧版本存档（v0.14 兼容）→ 以默认值打底，逐个字段补齐缺失项并保留已有合法进度（不丢档）。
## 钳制：数值字段 ≥ 0、pity 0..80、level_stars 1..3、formation row/col 0..2、
##       idle_last_time 非法（非正数/非数字）取当前时间。
## 签名：load_game() -> Dictionary
func load_game() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return _default_data()
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return _default_data()
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return _default_data()
	var parsed_dict: Dictionary = parsed
	# 旧档自动补齐：用默认值打底，合法字段逐个覆盖（设计文档 §10.12）
	var result := _default_data()
	# —— 基础数值 ——
	if parsed_dict.has("gold"):
		result["gold"] = maxi(int(parsed_dict["gold"]), 0)
	if parsed_dict.has("exp_balance"):
		result["exp_balance"] = maxi(int(parsed_dict["exp_balance"]), 0)
	if parsed_dict.has("unlocked_level"):
		result["unlocked_level"] = clampi(int(parsed_dict["unlocked_level"]), 1, Data.MAX_LEVEL)
	var mechs: Variant = parsed_dict.get("mechs", {})
	if mechs is Dictionary:
		for key in mechs:
			var entry: Variant = mechs[key]
			var mech_id := StringName(str(key))
			if entry is Dictionary and Data.MECH_GIRLS.has(mech_id):
				result["mechs"][mech_id] = {
					"level": maxi(int(entry.get("level", 1)), 1),
					"exp": maxi(int(entry.get("exp", 0)), 0),
				}
	var first_cleared: Variant = parsed_dict.get("first_cleared", [])
	if first_cleared is Array:
		for l in first_cleared:
			var level := int(l)
			if level >= 1 and level <= Data.MAX_LEVEL:
				result["first_cleared"].append(level)
	if parsed_dict.has("idle_pending"):
		result["idle_pending"] = maxi(int(parsed_dict["idle_pending"]), 0)
	if parsed_dict.has("idle_pending_exp"):
		result["idle_pending_exp"] = maxi(int(parsed_dict["idle_pending_exp"]), 0)
	var idle_last_time: Variant = parsed_dict.get("idle_last_time", 0)
	if (idle_last_time is float or idle_last_time is int) and int(idle_last_time) > 0:
		result["idle_last_time"] = int(idle_last_time)
	# —— 阶段 1 抽卡（v0.7）——
	if parsed_dict.has("diamond"):
		result["diamond"] = maxi(int(parsed_dict["diamond"]), 0)
	if parsed_dict.has("summon_ticket"):
		result["summon_ticket"] = maxi(int(parsed_dict["summon_ticket"]), 0)
	if parsed_dict.has("pity"):
		result["pity"] = clampi(int(parsed_dict["pity"]), 0, Data.SUMMON_PITY_SSR_LIMIT)
	if parsed_dict.has("novice_free_pull"):
		result["novice_free_pull"] = bool(parsed_dict["novice_free_pull"])
	if parsed_dict.has("novice_pool_left"):
		result["novice_pool_left"] = maxi(int(parsed_dict["novice_pool_left"]), 0)
	if parsed_dict.has("novice_first_ten_done"):
		result["novice_first_ten_done"] = bool(parsed_dict["novice_first_ten_done"])
	var fragments: Variant = parsed_dict.get("fragments", {})
	if fragments is Dictionary:
		for key in fragments:
			var mech_id := StringName(str(key))
			if Data.MECH_GIRLS.has(mech_id):
				result["fragments"][mech_id] = maxi(int(fragments[key]), 0)
	var owned_mechs: Variant = parsed_dict.get("owned_mechs", {})
	if owned_mechs is Dictionary:
		for key in owned_mechs:
			var mech_id := StringName(str(key))
			if Data.MECH_GIRLS.has(mech_id):
				result["owned_mechs"][mech_id] = true
	# —— 战斗 2.0（v0.8）：阵型 / 星级 / BOSS ——
	var formation: Variant = parsed_dict.get("formation", [])
	if formation is Array:
		var formation_result: Array = []
		for slot in formation:
			if slot is Dictionary and Data.MECH_GIRLS.has(StringName(str(slot.get("id", "")))):
				formation_result.append({
					"id": StringName(str(slot.get("id", ""))),
					"row": clampi(int(slot.get("row", 0)), 0, 2),
					"col": clampi(int(slot.get("col", 0)), 0, 2),
				})
		result["formation"] = formation_result
	var formation_presets: Variant = parsed_dict.get("formation_presets", {})
	if formation_presets is Dictionary:
		for key in formation_presets:
			var preset: Variant = formation_presets[key]
			if preset is Array:
				var preset_result: Array = []
				for slot in preset:
					if slot is Dictionary and Data.MECH_GIRLS.has(StringName(str(slot.get("id", "")))):
						preset_result.append({
							"id": StringName(str(slot.get("id", ""))),
							"row": clampi(int(slot.get("row", 0)), 0, 2),
							"col": clampi(int(slot.get("col", 0)), 0, 2),
						})
				result["formation_presets"][str(key)] = preset_result
	var level_stars: Variant = parsed_dict.get("level_stars", {})
	if level_stars is Dictionary:
		for key in level_stars:
			var level := int(key)
			if level >= 1 and level <= Data.MAX_LEVEL:
				result["level_stars"][level] = clampi(int(level_stars[key]), 1, 3)
	var cleared_boss: Variant = parsed_dict.get("cleared_boss", {})
	if cleared_boss is Dictionary:
		for key in cleared_boss:
			var level := int(key)
			if level >= 1 and level <= Data.MAX_LEVEL:
				result["cleared_boss"][level] = true
	# 章节星数宝箱领取标记（v0.8；旧档无此字段 → 默认 false，补齐不丢）
	if parsed_dict.has("chapter_chest_claimed"):
		result["chapter_chest_claimed"] = bool(parsed_dict["chapter_chest_claimed"])
	return result

## 默认档数据（契约 §3.2，v0.8）：金币/钻石/余额/待收获均 0、机娘取 Data 初始配置
## （Lv1、个人经验 0）、拥有开局 2 位机娘、解锁关卡 1、first_cleared 为空、
## pity 0、新手福利默认、阵型空（Game 启动时按拥有自动生成）、星级/BOSS 记录空
func _default_data() -> Dictionary:
	var mechs := {}
	for mech_id in Data.START_MECHS:
		mechs[mech_id] = { "level": 1, "exp": 0 }
	var owned := {}
	for mech_id in Data.START_MECHS:
		owned[mech_id] = true
	return {
		"gold": 0,
		"exp_balance": 0,
		"mechs": mechs,
		"unlocked_level": 1,
		"first_cleared": [],
		"idle_pending": 0,
		"idle_pending_exp": 0,
		"idle_last_time": int(Time.get_unix_time_from_system()),
		"diamond": 0,
		"summon_ticket": 0,
		"fragments": {},
		"owned_mechs": owned,
		"pity": 0,
		"novice_free_pull": true,
		"novice_pool_left": Data.SUMMON_NOVICE_POOL_LEFT,
		"novice_first_ten_done": false,
		"formation": [],
		"formation_presets": {},
		"level_stars": {},
		"cleared_boss": {},
		"chapter_chest_claimed": false,
	}
