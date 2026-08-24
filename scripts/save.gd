# ==================================================================
# scripts/save.gd —— 本地存档（Save，存档唯一负责方）
# 作者   ：B（数值 + 玩法 + 存档）
# 依据   ：docs/契约.md §3.2 / §3.6、scripts/data.gd、scripts/contract.gd（只读）
# 职责   ：存档读写（user://save.json，FileAccess + JSON）。
#          只有本文件知道存档文件路径与格式；其他脚本不得直接读写存档文件。
# 铁律   ：load 失败（缺失 / 损坏 / 版本不符）必须返回默认值并继续运行，不允许报错崩溃。
# 自动加载：本文件注册为名为 Save 的 autoload（注册顺序 Contract → Data → Save → Game）。
# 依赖   ：Contract（版本号）、Data（默认机娘配置）。
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
## 存档形状：{ gold, mechs{level, exp}, unlocked_level, first_cleared,
##            idle_pending, idle_last_time }（契约 §3.2，v0.4）
func save_game() -> void:
	var snapshot: Dictionary = Game.get_save_snapshot()
	var save_dict := {
		"version": Contract.CONTRACT_VERSION,
		"gold": int(snapshot.get("gold", 0)),
		"unlocked_level": int(snapshot.get("unlocked_level", 1)),
		"mechs": {},
		"first_cleared": [],
		"idle_pending": maxi(int(snapshot.get("idle_pending", 0)), 0),
		"idle_last_time": int(snapshot.get("idle_last_time", 0)),
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
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Save.save_game: 无法打开存档文件写入：" + SAVE_PATH)
		return
	file.store_string(JSON.stringify(save_dict))
	file.close()

## 读档：返回 { gold: int, mechs: Dictionary, unlocked_level: int, first_cleared: Array,
##            idle_pending: int, idle_last_time: int }（契约 §3.2，v0.4 存档形状）
## 失败（文件缺失 / 损坏 / 版本不符 / 字段非法）一律返回默认值并继续运行，不报错崩溃。
## 钳制：exp ≥ 0、idle_pending ≥ 0、idle_last_time 非法（非正数/非数字）取当前时间。
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
	# 版本不符 → 默认值（契约 §3.2）
	if parsed_dict.get("version", "") != Contract.CONTRACT_VERSION:
		return _default_data()
	if (not parsed_dict.has("gold") or not parsed_dict.has("mechs") or not parsed_dict.has("unlocked_level")
			or not parsed_dict.has("first_cleared") or not parsed_dict.has("idle_pending") or not parsed_dict.has("idle_last_time")):
		return _default_data()
	var result := _default_data()
	result["gold"] = int(parsed_dict["gold"])
	result["unlocked_level"] = int(parsed_dict["unlocked_level"])
	var mechs: Variant = parsed_dict["mechs"]
	if mechs is Dictionary:
		for key in mechs:
			var entry: Variant = mechs[key]
			var mech_id := StringName(str(key))
			# 只认 Data 中存在的机娘；等级钳到 >= 1、经验钳到 >= 0
			if entry is Dictionary and Data.MECH_GIRLS.has(mech_id):
				result["mechs"][mech_id] = {
					"level": maxi(int(entry.get("level", 1)), 1),
					"exp": maxi(int(entry.get("exp", 0)), 0),
				}
	var first_cleared: Variant = parsed_dict["first_cleared"]
	if first_cleared is Array:
		for l in first_cleared:
			var level := int(l)
			# 只认 1..MAX_LEVEL 的关卡
			if level >= 1 and level <= Data.MAX_LEVEL:
				result["first_cleared"].append(level)
	# 待收获金币：钳到 >= 0
	result["idle_pending"] = maxi(int(parsed_dict["idle_pending"]), 0)
	# 上次结算时间戳：非法（非正数）取当前时间
	var idle_last_time: Variant = parsed_dict["idle_last_time"]
	if (idle_last_time is float or idle_last_time is int) and int(idle_last_time) > 0:
		result["idle_last_time"] = int(idle_last_time)
	return result

## 默认档数据（契约 §3.2）：金币 0、机娘取 Data 初始配置（Lv1、经验 0）、解锁关卡 1、
## first_cleared 为空、idle_pending 为 0、idle_last_time 取当前时间
func _default_data() -> Dictionary:
	var mechs := {}
	for mech_id in Data.MECH_GIRLS:
		mechs[mech_id] = { "level": 1, "exp": 0 }
	return {
		"gold": 0,
		"mechs": mechs,
		"unlocked_level": 1,
		"first_cleared": [],
		"idle_pending": 0,
		"idle_last_time": int(Time.get_unix_time_from_system()),
	}
