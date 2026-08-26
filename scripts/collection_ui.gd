# ==================================================================
# scripts/collection_ui.gd —— 图鉴界面脚本（挂在 scenes/Collection.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.14（v0.17）、docs/设计文档.md v0.21 §1.6 ⑩⑮、
#          scripts/contract.gd（只读，v0.17 新信号）、scripts/game.gd（B 实际返回字段）
# 职责   ：图鉴（机娘收集 / 成就 / 称号）纯显示层 + 领奖/佩戴入口。
#          - 连接信号：collection_changed(count) / achievement_changed(achievements) /
#            title_changed(unlocked, equipped)
#          - 按钮只调入口（契约 §3.6）：档位领奖 → Game.claim_collection_reward(tier)；
#            成就领奖 → Game.claim_achievement(id)；称号佩戴 → Game.equip_title(id)（空串卸下）；
#            已拥有机娘卡片点击 → 进 MechDetail.tscn（携带 mech_id，经 main_ui.pending_mech_id 传递）；
#            返回 → 切回 Main.tscn
#          - 只读入口：Game.get_collection_info()（B 实现返回 {count, total, claimed}）、
#            Game.get_achievement_info()（B 实现直接返回数组 [{id,name,desc,progress,target,done,claimed}]）、
#            Game.get_title_info()（{unlocked, equipped}）；奖励/条件等静态文案读 Data 表
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准；奖励内容/称号条件等是 Data 静态表展示，不参与数值。
# 首屏说明：本场景从主界面切换而来，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

const MainUI := preload("res://scripts/main_ui.gd")

## ---- 节点引用（与 scenes/Collection.tscn 结构一一对应）----
@onready var _progress_label: Label = $root_box/progress_label
@onready var _tier_box: HBoxContainer = $root_box/tier_box
@onready var _mech_tab_button: Button = $root_box/tab_row/mech_tab_button
@onready var _achievement_tab_button: Button = $root_box/tab_row/achievement_tab_button
@onready var _title_tab_button: Button = $root_box/tab_row/title_tab_button
@onready var _content_box: VBoxContainer = $root_box/scroll/content_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button

## ---- UI 内部状态（仅当前页签，不含任何游戏数值）----
var _tab: StringName = &"mech"   # &"mech" / &"achievement" / &"title"


func _ready() -> void:
	Contract.collection_changed.connect(_on_collection_changed)
	Contract.achievement_changed.connect(_on_achievement_changed)
	Contract.title_changed.connect(_on_title_changed)
	_mech_tab_button.pressed.connect(_on_tab_pressed.bind(&"mech"))
	_achievement_tab_button.pressed.connect(_on_tab_pressed.bind(&"achievement"))
	_title_tab_button.pressed.connect(_on_tab_pressed.bind(&"title"))
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_refresh_progress()
	_build_tier_row()
	_refresh_content()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_collection_changed(_count: int) -> void:
	_refresh_progress()
	_build_tier_row()
	if _tab == &"mech":
		_refresh_content()


func _on_achievement_changed(_achievements: Array) -> void:
	if _tab == &"achievement":
		_refresh_content()


func _on_title_changed(_unlocked: Array, _equipped: StringName) -> void:
	if _tab == &"title":
		_refresh_content()


## ------------------------------------------------------------------
## 页签切换（机娘 / 成就 / 称号）
## ------------------------------------------------------------------
func _on_tab_pressed(tab: StringName) -> void:
	_tab = tab
	_mech_tab_button.button_pressed = (tab == &"mech")
	_achievement_tab_button.button_pressed = (tab == &"achievement")
	_title_tab_button.button_pressed = (tab == &"title")
	_refresh_content()


func _refresh_content() -> void:
	_clear_content()
	match _tab:
		&"mech":
			_build_mech_tab()
		&"achievement":
			_build_achievement_tab()
		&"title":
			_build_title_tab()


func _clear_content() -> void:
	for child in _content_box.get_children():
		_content_box.remove_child(child)
		child.queue_free()


## ------------------------------------------------------------------
## 顶部：收集进度 + 档位奖励（契约 §3.14；B 实现 get_collection_info 返回 {count,total,claimed}）
## ------------------------------------------------------------------
func _refresh_progress() -> void:
	var info: Dictionary = Game.get_collection_info()
	_progress_label.text = "机娘收集：%d/%d" % [int(info.get("count", 0)), int(info.get("total", 0))]


func _build_tier_row() -> void:
	for child in _tier_box.get_children():
		_tier_box.remove_child(child)
		child.queue_free()
	var info: Dictionary = Game.get_collection_info()
	var count: int = int(info.get("count", 0))
	var claimed: Array = info.get("claimed", [])
	for tier in Data.COLLECTION_REWARDS:
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 2)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var rewards: Array = Data.COLLECTION_REWARDS[tier]
		var reward_label := Label.new()
		reward_label.text = "收集 %d 位：%s" % [int(tier), _reward_text(rewards)]
		reward_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		reward_label.add_theme_font_size_override("font_size", 12)
		var btn := Button.new()
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if claimed.has(tier):
			btn.text = "已领取"
			btn.disabled = true
		elif count >= int(tier):
			btn.text = "领取"
			btn.pressed.connect(_on_claim_tier_pressed.bind(int(tier)))
		else:
			btn.text = "未达成（%d/%d）" % [count, int(tier)]
			btn.disabled = true
		v.add_child(reward_label)
		v.add_child(btn)
		_tier_box.add_child(v)


func _on_claim_tier_pressed(tier: int) -> void:
	# 结果由 collection_changed + 货币信号回发
	Game.claim_collection_reward(tier)
	_message_label.text = "已领取收集 %d 位奖励" % tier


## ------------------------------------------------------------------
## 机娘页：30 位（已拥有彩色 + 名/职业/稀有度；未拥有灰影 + 获取方式）
## 已拥有卡片点击进 MechDetail（携带 mech_id）
## ------------------------------------------------------------------
func _build_mech_tab() -> void:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	for mech_id in Data.MECH_GIRLS:
		grid.add_child(_make_mech_card(StringName(mech_id)))
	_content_box.add_child(grid)


func _make_mech_card(mech_id: StringName) -> Control:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var owned: bool = Game.owned_mechs.has(mech_id)
	var card := Panel.new()
	card.custom_minimum_size = Vector2(140, 96)
	# 头像色块（顶部色块按稀有度着色；未拥有为灰影）
	var avatar := ColorRect.new()
	avatar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	avatar.offset_bottom = 34.0
	avatar.color = _rarity_color(mech_id, owned)
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(avatar)
	# 名字（★N + 名字）
	var name_label := Label.new()
	name_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	name_label.offset_top = 38.0
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 13)
	if owned:
		var star: int = int(Game.mech_stars.get(mech_id, 1))
		name_label.text = "★%d %s" % [star, str(cfg.get("name", str(mech_id)))]
		name_label.modulate = Color.WHITE
	else:
		name_label.text = "？？？"
		name_label.modulate = Color(0.55, 0.55, 0.6)
	card.add_child(name_label)
	# 信息（职业·稀有度 / 获取方式）
	var info_label := Label.new()
	info_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	info_label.offset_top = 56.0
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.add_theme_font_size_override("font_size", 11)
	if owned:
		info_label.text = "%s · %s\n战力 %s" % [_class_text(StringName(str(cfg.get("class", "")))), _rarity_text(int(cfg.get("rarity", 0))), _fmt_num(Game.get_power(mech_id))]
		info_label.modulate = Color.WHITE
	else:
		info_label.text = "获取方式：抽卡获得"
		info_label.modulate = Color(0.6, 0.6, 0.65)
	card.add_child(info_label)
	# 点击层（已拥有可进详情；未拥有不响应）
	var click := Button.new()
	click.flat = true
	click.text = ""
	click.set_anchors_preset(Control.PRESET_FULL_RECT)
	if owned:
		click.pressed.connect(_on_mech_card_pressed.bind(mech_id))
	else:
		click.disabled = true
	card.add_child(click)
	return card


func _on_mech_card_pressed(mech_id: StringName) -> void:
	# 经 main_ui.pending_mech_id 传递 mech_id 到详情页（UI 导航状态，非游戏数值）
	MainUI.pending_mech_id = mech_id
	get_tree().change_scene_to_file("res://scenes/MechDetail.tscn")


## ------------------------------------------------------------------
## 成就页：12 个（名称/目标/进度/达成标记/领奖）
## B 实现 get_achievement_info 直接返回数组；奖励从 Data.ACHIEVEMENTS 静态读
## ------------------------------------------------------------------
func _build_achievement_tab() -> void:
	var list: Array = Game.get_achievement_info()
	for item in list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var aid := StringName(str(item.get("id", "")))
		var cfg: Dictionary = Data.ACHIEVEMENTS.get(aid, {})
		var info := Label.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_font_size_override("font_size", 13)
		var progress: int = int(item.get("progress", 0))
		var target: int = int(item.get("target", 1))
		var done: bool = bool(item.get("done", false))
		var claimed: bool = bool(item.get("claimed", false))
		var mark: String = "✓ 达成" if done else "未达成"
		info.text = "%s：%s  [%d/%d] %s\n奖励：%s" % [
			str(item.get("name", str(aid))), str(item.get("desc", "")),
			progress, target, mark, _reward_text(cfg.get("rewards", []))]
		var btn := Button.new()
		if claimed:
			btn.text = "已领取"
			btn.disabled = true
		elif done:
			btn.text = "领取"
			btn.pressed.connect(_on_claim_achievement_pressed.bind(aid))
		else:
			btn.text = "未达成"
			btn.disabled = true
		row.add_child(info)
		row.add_child(btn)
		_content_box.add_child(row)


func _on_claim_achievement_pressed(achievement_id: StringName) -> void:
	# 结果由 achievement_changed + 货币信号回发
	Game.claim_achievement(achievement_id)
	_message_label.text = "已领取成就奖励"


## ------------------------------------------------------------------
## 称号页：解锁列表 + 佩戴（Game.get_title_info() -> {unlocked, equipped}）
## ------------------------------------------------------------------
func _build_title_tab() -> void:
	var info: Dictionary = Game.get_title_info()
	var unlocked: Array = info.get("unlocked", [])
	var equipped: StringName = StringName(str(info.get("equipped", "")))
	for tid in Data.TITLES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var is_unlocked: bool = unlocked.has(tid)
		var cfg: Dictionary = Data.TITLES[tid]
		var text_label := Label.new()
		text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_label.add_theme_font_size_override("font_size", 13)
		var state: String = "已解锁" if is_unlocked else "未解锁"
		var cond_text: String = _condition_text(cfg.get("condition", {}))
		var bonus_text: String = _bonus_text(cfg.get("bonus", {}))
		var equipped_mark: String = "  ← 当前佩戴" if StringName(str(tid)) == equipped else ""
		text_label.text = "%s（%s）%s\n条件：%s\n加成：%s" % [
			str(cfg.get("name", str(tid))), state, equipped_mark, cond_text, bonus_text]
		var btn := Button.new()
		if StringName(str(tid)) == equipped:
			btn.text = "卸下"
			btn.pressed.connect(_on_equip_title_pressed.bind(&""))
		elif is_unlocked:
			btn.text = "佩戴"
			btn.pressed.connect(_on_equip_title_pressed.bind(StringName(tid)))
		else:
			btn.text = "未解锁"
			btn.disabled = true
		row.add_child(text_label)
		row.add_child(btn)
		_content_box.add_child(row)


func _on_equip_title_pressed(title_id: StringName) -> void:
	# 结果由 title_changed 回发（属性变化随 mech_girl_updated）
	Game.equip_title(title_id)
	_message_label.text = "已卸下称号" if title_id == &"" else "已佩戴称号"


## ------------------------------------------------------------------
## 返回
## ------------------------------------------------------------------
func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


## ------------------------------------------------------------------
## 文本工具（静态信息读 Data；动态值只来自信号 / 只读入口）
## ------------------------------------------------------------------
## 奖励列表文案：如 [{type:diamond,amount:100},{type:ticket,amount:1}] → "钻石×100 + 召唤券×1"
func _reward_text(rewards: Array) -> String:
	if rewards.is_empty():
		return "—"
	var parts: Array = []
	for r in rewards:
		var amount: int = int(r.get("amount", 0))
		match str(r.get("type", "")):
			"gold":
				parts.append("金币×%d" % amount)
			"diamond":
				parts.append("钻石×%d" % amount)
			"ticket":
				parts.append("召唤券×%d" % amount)
			"gem":
				parts.append("%s宝石×%d" % [_gem_quality_text(StringName(str(r.get("quality", "white")))), amount])
			"equip":
				parts.append("装备×%d" % amount)
			_:
				parts.append(str(r.get("type", "?")) + "×%d" % amount)
	return " + ".join(parts)


## 称号解锁条件文案
func _condition_text(cond: Dictionary) -> String:
	match str(cond.get("type", "")):
		"story_cleared":
			return "通关主线 %d 关" % int(cond.get("target", 0))
		"tower":
			return "爬塔 %d 层" % int(cond.get("target", 0))
		"dungeon":
			return "通关地狱档秘境" if int(cond.get("target", 0)) >= 4 else "通关秘境档位 %d" % int(cond.get("target", 0))
		"collection":
			return "集齐 %d 位机娘" % int(cond.get("target", 0))
	return str(cond.get("type", ""))


## 称号加成文案（scope 字段预留；本轮 B 统一全队生效）
func _bonus_text(bonus: Dictionary) -> String:
	var stat: String = str(bonus.get("stat", ""))
	var value: float = float(bonus.get("value", 0.0))
	match stat:
		"atk_pct":
			return "攻击 +%d%%" % roundi(value * 100.0)
		"hp_pct":
			return "血量 +%d%%" % roundi(value * 100.0)
		"def_pct":
			return "防御 +%d%%" % roundi(value * 100.0)
		"spd":
			return "速度 +%d" % roundi(value)
	return stat


func _class_text(class_id: StringName) -> String:
	match class_id:
		&"tank": return "坦克"
		&"fighter": return "战士"
		&"assassin": return "刺客"
		&"archer": return "射手"
		&"mage": return "法师"
		&"support": return "辅助"
	return str(class_id)


func _rarity_text(r: int) -> String:
	match r:
		Data.Rarity.R:
			return "R"
		Data.Rarity.SR:
			return "SR"
		Data.Rarity.SSR:
			return "SSR"
	return "?"


func _rarity_color(mech_id: StringName, owned: bool) -> Color:
	if not owned:
		return Color(0.30, 0.32, 0.38)
	var rarity: int = int(Data.MECH_GIRLS.get(mech_id, {}).get("rarity", 0))
	match rarity:
		Data.Rarity.SSR:
			return Color(1.0, 0.82, 0.35)
		Data.Rarity.SR:
			return Color(0.70, 0.52, 0.95)
	return Color(0.55, 0.68, 0.95)


func _gem_quality_text(quality: StringName) -> String:
	match quality:
		&"white": return "白"
		&"green": return "绿"
		&"blue": return "蓝"
		&"purple": return "紫"
		&"gold": return "金"
		&"red": return "红"
	return str(quality)


## 千分位格式化（纯显示，不修改任何数值）
func _fmt_num(n: int) -> String:
	var s := str(abs(n))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	if n < 0:
		out = "-" + out
	return out
