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
		# v0.13：体力 / 秘境 / 背包 / 开箱
		"stamina": clampi(int(snapshot.get("stamina", Data.STAMINA_MAX)), 0, Data.STAMINA_MAX),
		"stamina_last_time": int(snapshot.get("stamina_last_time", 0)),
		"stamina_buy_count": maxi(int(snapshot.get("stamina_buy_count", 0)), 0),
		"last_reset_day": str(snapshot.get("last_reset_day", "")),
		"dungeon_cleared": {},
		"bag": { "items": {}, "capacity": clampi(int(snapshot.get("bag", {}).get("capacity", Data.BAG_START_CAPACITY)), 0, Data.BAG_MAX_CAPACITY) },
		"boxes": maxi(int(snapshot.get("boxes", 0)), 0),
		# v0.14：装备 / 宝石
		"equip_inventory": [],
		"equipped": {},
		"gem_stock": {},
		# v0.15：设置 / 商城
		"settings": {},
		"shop_day": str(snapshot.get("shop_day", "")),
		"shop_bought": {},
		# v0.16：爬塔 / 签到 / 任务 / 新手
		"tower_highest": maxi(int(snapshot.get("tower_highest", 0)), 0),
		"tower_daily_count": maxi(int(snapshot.get("tower_daily_count", 0)), 0),
		"sign_days": maxi(int(snapshot.get("sign_days", 0)), 0),
		"sign_last_day": str(snapshot.get("sign_last_day", "")),
		"task_daily": { "progress": {}, "claimed": [] },
		"task_weekly": { "progress": {}, "claimed": [] },
		"novice_progress": {},
		"novice_claimed": [],
	}
	# 设置（白名单键 + 默认值补齐）
	var settings_src: Dictionary = snapshot.get("settings", {})
	for key in Data.SETTINGS_KEYS:
		if settings_src.has(str(key)):
			save_dict["settings"][str(key)] = settings_src[str(key)]
		else:
			save_dict["settings"][str(key)] = Data.SETTINGS_DEFAULTS[key]
	# 当日已购商品（只认 SHOP_ITEMS）
	var shop_bought_src: Dictionary = snapshot.get("shop_bought", {})
	for item_id in shop_bought_src:
		if Data.SHOP_ITEMS.has(StringName(str(item_id))):
			save_dict["shop_bought"][str(item_id)] = true
	# v0.16：任务进度（progress 只认任务表 key，claimed 转 int 数组）
	var task_daily_src: Dictionary = snapshot.get("task_daily", {})
	_serialize_task(save_dict["task_daily"], task_daily_src, Data.DAILY_TASKS)
	var task_weekly_src: Dictionary = snapshot.get("task_weekly", {})
	_serialize_task(save_dict["task_weekly"], task_weekly_src, Data.WEEKLY_TASKS)
	var novice_progress_src: Dictionary = snapshot.get("novice_progress", {})
	for day in novice_progress_src:
		var day_map: Dictionary = novice_progress_src[day]
		if day_map is Dictionary:
			save_dict["novice_progress"][str(day)] = {}
			for task_id in day_map:
				save_dict["novice_progress"][str(day)][str(task_id)] = maxi(int(day_map[task_id]), 0)
	var novice_claimed_src: Variant = snapshot.get("novice_claimed", [])
	if novice_claimed_src is Array:
		for day in novice_claimed_src:
			var d := int(day)
			if d >= 1 and d <= 7:
				save_dict["novice_claimed"].append(d)
	# 背包物品（item_id → count，只认 Data.ITEMS）
	var bag_src: Dictionary = snapshot.get("bag", {})
	var bag_items_src: Dictionary = bag_src.get("items", {})
	for item_key in bag_items_src:
		if Data.ITEMS.has(StringName(str(item_key))):
			save_dict["bag"]["items"][str(item_key)] = maxi(int(bag_items_src[item_key]), 0)
	# 秘境通关记录 {kind: {tier: true}}
	var dungeon_cleared_src: Dictionary = snapshot.get("dungeon_cleared", {})
	for kind in dungeon_cleared_src:
		var tier_map: Dictionary = dungeon_cleared_src[kind]
		if tier_map is Dictionary:
			save_dict["dungeon_cleared"][str(kind)] = {}
			for tier in tier_map:
				save_dict["dungeon_cleared"][str(kind)][str(tier)] = true
	# v0.14：装备实例 / 穿戴 / 宝石库存
	var equip_inventory: Variant = snapshot.get("equip_inventory", [])
	if equip_inventory is Array:
		for eq in equip_inventory:
			if eq is Dictionary and Data.EQUIP_SLOTS.has(StringName(str(eq.get("slot", "")))):
				var eq_save := {
					"uid": str(eq.get("uid", "")),
					"slot": str(eq.get("slot", "")),
					"star": clampi(int(eq.get("star", 1)), 1, 5),
					"level": clampi(int(eq.get("level", 0)), 0, Data.ENCHANT_MAX_LEVEL),
					"gems": [],
				}
				var gems: Variant = eq.get("gems", [])
				if gems is Array:
					for g in gems:
						if g is Dictionary and StringName(str(g.get("quality", ""))) in Data.GEM_QUALITIES:
							eq_save["gems"].append({
								"quality": str(g.get("quality", "")),
								"affixes": g.get("affixes", []),
							})
				save_dict["equip_inventory"].append(eq_save)
	var equipped_src: Dictionary = snapshot.get("equipped", {})
	for mech_id in equipped_src:
		var slots: Dictionary = equipped_src[mech_id]
		if slots is Dictionary:
			save_dict["equipped"][str(mech_id)] = {}
			for slot_key in slots:
				save_dict["equipped"][str(mech_id)][str(slot_key)] = str(slots[slot_key])
	var gem_stock_src: Dictionary = snapshot.get("gem_stock", {})
	for q in gem_stock_src:
		if StringName(str(q)) in Data.GEM_QUALITIES:
			save_dict["gem_stock"][str(q)] = maxi(int(gem_stock_src[q]), 0)
	var mechs: Dictionary = snapshot.get("mechs", {})
	for key in mechs:
		var entry: Dictionary = mechs[key]
		# 写盘统一用字符串键，避免 StringName 键在 JSON 序列化时的差异
		save_dict["mechs"][str(key)] = {
			"level": maxi(int(entry.get("level", 1)), 1),
			"exp": maxi(int(entry.get("exp", 0)), 0),
			"star": clampi(int(entry.get("star", 1)), 1, Data.MAX_STAR),
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
					# 星级（v0.10）：旧档无此字段 → 默认 1，补齐不丢
					"star": clampi(int(entry.get("star", 1)), 1, Data.MAX_STAR),
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
	# —— v0.13：体力 / 秘境 / 背包 / 开箱 ——
	if parsed_dict.has("stamina"):
		result["stamina"] = clampi(int(parsed_dict["stamina"]), 0, Data.STAMINA_MAX)
	if parsed_dict.has("stamina_last_time"):
		var slt: Variant = parsed_dict["stamina_last_time"]
		if (slt is float or slt is int) and int(slt) > 0:
			result["stamina_last_time"] = int(slt)
	if parsed_dict.has("stamina_buy_count"):
		result["stamina_buy_count"] = maxi(int(parsed_dict["stamina_buy_count"]), 0)
	if parsed_dict.has("last_reset_day"):
		result["last_reset_day"] = str(parsed_dict["last_reset_day"])
	var dungeon_cleared: Variant = parsed_dict.get("dungeon_cleared", {})
	if dungeon_cleared is Dictionary:
		for kind in dungeon_cleared:
			var tier_map: Variant = dungeon_cleared[kind]
			if tier_map is Dictionary:
				result["dungeon_cleared"][str(kind)] = {}
				for tier in tier_map:
					result["dungeon_cleared"][str(kind)][str(tier)] = true
	var bag_data: Variant = parsed_dict.get("bag", {})
	if bag_data is Dictionary:
		result["bag"]["capacity"] = clampi(int(bag_data.get("capacity", Data.BAG_START_CAPACITY)), 0, Data.BAG_MAX_CAPACITY)
		var bag_items: Variant = bag_data.get("items", {})
		if bag_items is Dictionary:
			for item_key in bag_items:
				if Data.ITEMS.has(StringName(str(item_key))):
					result["bag"]["items"][str(item_key)] = maxi(int(bag_items[item_key]), 0)
	if parsed_dict.has("boxes"):
		result["boxes"] = maxi(int(parsed_dict["boxes"]), 0)
	# —— v0.14：装备 / 宝石 ——
	var equip_inventory: Variant = parsed_dict.get("equip_inventory", [])
	if equip_inventory is Array:
		for eq in equip_inventory:
			if eq is Dictionary and Data.EQUIP_SLOTS.has(StringName(str(eq.get("slot", "")))):
				var eq_load := {
					"uid": StringName(str(eq.get("uid", ""))),
					"slot": StringName(str(eq.get("slot", ""))),
					"star": clampi(int(eq.get("star", 1)), 1, 5),
					"level": clampi(int(eq.get("level", 0)), 0, Data.ENCHANT_MAX_LEVEL),
					"gems": [],
				}
				var gems: Variant = eq.get("gems", [])
				if gems is Array:
					for g in gems:
						if g is Dictionary and StringName(str(g.get("quality", ""))) in Data.GEM_QUALITIES:
							eq_load["gems"].append({
								"quality": StringName(str(g.get("quality", ""))),
								"affixes": g.get("affixes", []),
							})
				result["equip_inventory"].append(eq_load)
	var equipped_src: Variant = parsed_dict.get("equipped", {})
	if equipped_src is Dictionary:
		for mech_id in equipped_src:
			var slots: Variant = equipped_src[mech_id]
			if slots is Dictionary:
				result["equipped"][StringName(str(mech_id))] = {}
				for slot_key in slots:
					result["equipped"][StringName(str(mech_id))][StringName(str(slot_key))] = StringName(str(slots[slot_key]))
	var gem_stock_src: Variant = parsed_dict.get("gem_stock", {})
	if gem_stock_src is Dictionary:
		for q in gem_stock_src:
			if StringName(str(q)) in Data.GEM_QUALITIES:
				result["gem_stock"][StringName(str(q))] = maxi(int(gem_stock_src[q]), 0)
	# —— v0.15：设置 / 商城 ——
	var settings_src: Variant = parsed_dict.get("settings", {})
	if settings_src is Dictionary:
		for key in Data.SETTINGS_KEYS:
			var key_str: String = str(key)
			if settings_src.has(key_str):
				# 音量字段钳到 0..1，其余字段按存档值（缺失键已由默认值打底）
				if key_str == "music_volume" or key_str == "sfx_volume":
					result["settings"][key_str] = clampf(float(settings_src[key_str]), 0.0, 1.0)
				else:
					result["settings"][key_str] = settings_src[key_str]
	var shop_day: Variant = parsed_dict.get("shop_day", "")
	result["shop_day"] = str(shop_day)
	var shop_bought_src: Variant = parsed_dict.get("shop_bought", {})
	if shop_bought_src is Dictionary:
		for item_id in shop_bought_src:
			if Data.SHOP_ITEMS.has(StringName(str(item_id))):
				result["shop_bought"][str(item_id)] = true
	# —— v0.16：爬塔 / 签到 / 任务 / 新手 ——
	if parsed_dict.has("tower_highest"):
		result["tower_highest"] = maxi(int(parsed_dict["tower_highest"]), 0)
	if parsed_dict.has("tower_daily_count"):
		result["tower_daily_count"] = maxi(int(parsed_dict["tower_daily_count"]), 0)
	if parsed_dict.has("sign_days"):
		result["sign_days"] = maxi(int(parsed_dict["sign_days"]), 0)
	if parsed_dict.has("sign_last_day"):
		result["sign_last_day"] = str(parsed_dict["sign_last_day"])
	_deserialize_task(result["task_daily"], parsed_dict.get("task_daily", {}), Data.DAILY_TASKS)
	_deserialize_task(result["task_weekly"], parsed_dict.get("task_weekly", {}), Data.WEEKLY_TASKS)
	var novice_progress_src: Variant = parsed_dict.get("novice_progress", {})
	if novice_progress_src is Dictionary:
		for day in novice_progress_src:
			var day_map: Variant = novice_progress_src[day]
			if day_map is Dictionary:
				result["novice_progress"][str(day)] = {}
				for task_id in day_map:
					result["novice_progress"][str(day)][str(task_id)] = maxi(int(day_map[task_id]), 0)
	var novice_claimed_src: Variant = parsed_dict.get("novice_claimed", [])
	if novice_claimed_src is Array:
		for day in novice_claimed_src:
			var d := int(day)
			if d >= 1 and d <= 7:
				result["novice_claimed"].append(d)
	return result

## 反序列化任务存储（progress 只认任务表 key；claimed 只认该任务表档位）
func _deserialize_task(target: Dictionary, src: Variant, task_table: Dictionary, tier_table: Dictionary = {}) -> void:
	if src is Dictionary:
		var progress: Variant = src.get("progress", {})
		if progress is Dictionary:
			for task_id in progress:
				if task_table.has(StringName(str(task_id))):
					target["progress"][str(task_id)] = maxi(int(progress[task_id]), 0)
		var claimed: Variant = src.get("claimed", [])
		if claimed is Array:
			for tier in claimed:
				target["claimed"].append(int(tier))

## 序列化任务存储（progress 只认任务表 key，claimed 转 int 数组）
func _serialize_task(target: Dictionary, src: Dictionary, task_table: Dictionary) -> void:
	var progress: Variant = src.get("progress", {})
	if progress is Dictionary:
		for task_id in progress:
			if task_table.has(StringName(str(task_id))):
				target["progress"][str(task_id)] = maxi(int(progress[task_id]), 0)
	var claimed: Variant = src.get("claimed", [])
	if claimed is Array:
		for tier in claimed:
			target["claimed"].append(int(tier))

## 清空存档文件（供 Game.reset_save 使用：删除 user://save.json，下次读档回默认值）
func clear_save() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)

## 默认档数据（契约 §3.2，v0.10）：开局资源 = 金币 1000 + 钻石 300（仅新档，v0.18）、
## 机娘取 Data 初始配置（Lv1、个人经验 0、1 星）、拥有开局 2 位机娘、解锁关卡 1、
## first_cleared 为空、pity 0、新手福利默认、阵型空（Game 启动时按拥有自动生成）
func _default_data() -> Dictionary:
	var mechs := {}
	for mech_id in Data.START_MECHS:
		mechs[mech_id] = { "level": 1, "exp": 0, "star": 1 }
	var owned := {}
	for mech_id in Data.START_MECHS:
		owned[mech_id] = true
	return {
		"gold": Data.START_GOLD,
		"exp_balance": 0,
		"mechs": mechs,
		"unlocked_level": 1,
		"first_cleared": [],
		"idle_pending": 0,
		"idle_pending_exp": 0,
		"idle_last_time": int(Time.get_unix_time_from_system()),
		"diamond": Data.START_DIAMOND,
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
		# v0.13：体力满 100、上次结算=当前时间、当日购买 0、重置日=当天、
		#        秘境通关记录空、背包 50 格空物品、待开箱 0
		"stamina": Data.STAMINA_MAX,
		"stamina_last_time": int(Time.get_unix_time_from_system()),
		"stamina_buy_count": 0,
		"last_reset_day": Time.get_date_string_from_system(),
		"dungeon_cleared": {},
		"bag": { "items": {}, "capacity": Data.BAG_START_CAPACITY },
		"boxes": 0,
		# v0.14：装备 / 宝石（默认空）
		"equip_inventory": [],
		"equipped": {},
		"gem_stock": {},
		# v0.15：设置默认 / 商城（默认今日、未购）
		"settings": Data.SETTINGS_DEFAULTS.duplicate(),
		"shop_day": Time.get_date_string_from_system(),
		"shop_bought": {},
		# v0.16：爬塔 / 签到 / 任务 / 新手（默认空）
		"tower_highest": 0,
		"tower_daily_count": 0,
		"sign_days": 0,
		"sign_last_day": "",
		"task_daily": { "progress": {}, "claimed": [] },
		"task_weekly": { "progress": {}, "claimed": [] },
		"novice_progress": {},
		"novice_claimed": [],
	}
