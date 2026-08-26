# ==================================================================
# scripts/mech_detail_ui.gd —— 机娘详情页脚本（挂在 scenes/MechDetail.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.14（v0.17）、docs/设计文档.md v0.21 §1.6 ⑰、
#          scripts/contract.gd（只读，v0.17 新信号）、scripts/game.gd（B 实际返回字段）
# 职责   ：机娘详情纯显示层（大立绘占位 / 属性 / 技能 / 装备 / 好感 / 羁绊）+ 养成入口。
#          - 当前机娘 id 由 main_ui.pending_mech_id 传入（UI 导航状态；空则取第一只已拥有）
#          - 连接信号：mech_girl_updated / exp_balance_updated / mech_star_updated /
#            affinity_changed / equipped_changed / gold_changed / fragments_updated
#          - 按钮只调入口（契约 §3.6）：升级 → Game.upgrade(id)；升星 → Game.upgrade_star(id)；
#            送礼 → Game.give_gift(id)；装备界面 → 切 Equipment.tscn；返回 → 切 Main.tscn
#          - 只读入口：Game.get_power(id) / get_level_cap(id) / upgrade_cost(id) /
#            upgrade_exp_cost(id) / star_cost(id) / get_affinity_info() /
#            get_equipped() / get_equip_inventory()
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 观察项（延续既有 main_ui 做法，非本轮新增）：防御/速度无信号参数，按 Data 静态公式
#          （等级 + 星级乘数，不含装备）换算展示，与 Game._mech_stats 同公式同数据源。
# 首屏说明：本场景从主界面/图鉴切换而来，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

const MainUI := preload("res://scripts/main_ui.gd")

## ---- 节点引用（与 scenes/MechDetail.tscn 结构一一对应）----
@onready var _back_button: Button = $root_box/top_row/back_button
@onready var _title_label: Label = $root_box/top_row/title_label
@onready var _portrait: ColorRect = $root_box/scroll/content_box/portrait
@onready var _name_label: Label = $root_box/scroll/content_box/name_label
@onready var _stats_label: Label = $root_box/scroll/content_box/stats_label
@onready var _skills_box: VBoxContainer = $root_box/scroll/content_box/skills_box
@onready var _equip_box: HBoxContainer = $root_box/scroll/content_box/equip_box
@onready var _equip_button: Button = $root_box/scroll/content_box/equip_button
@onready var _affinity_bar: ProgressBar = $root_box/scroll/content_box/affinity_row/affinity_bar
@onready var _affinity_value_label: Label = $root_box/scroll/content_box/affinity_row/affinity_value_label
@onready var _gift_button: Button = $root_box/scroll/content_box/gift_button
@onready var _bond_label: Label = $root_box/scroll/content_box/bond_label
@onready var _upgrade_button: Button = $root_box/scroll/content_box/upgrade_row/upgrade_button
@onready var _star_button: Button = $root_box/scroll/content_box/upgrade_row/star_button
@onready var _message_label: Label = $root_box/scroll/content_box/message_label

## ---- UI 内部状态（仅当前机娘 id，不含任何游戏数值）----
var _mech_id: StringName = &""


func _ready() -> void:
	_mech_id = MainUI.pending_mech_id
	if _mech_id == &"" or not Game.owned_mechs.has(_mech_id):
		var owned: Array = Game.get_owned_mechs()
		_mech_id = StringName(str(owned[0])) if not owned.is_empty() else &""
	if _mech_id == &"":
		_message_label.text = "尚未拥有任何机娘"
		_upgrade_button.disabled = true
		_star_button.disabled = true
		_gift_button.disabled = true
		return
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
	Contract.exp_balance_updated.connect(_on_exp_balance_updated)
	Contract.mech_star_updated.connect(_on_mech_star_updated)
	Contract.affinity_changed.connect(_on_affinity_changed)
	Contract.equipped_changed.connect(_on_equipped_changed)
	Contract.gold_changed.connect(_on_gold_changed)
	Contract.fragments_updated.connect(_on_fragments_updated)
	_back_button.pressed.connect(_on_back_pressed)
	_equip_button.pressed.connect(_on_equip_screen_pressed)
	_gift_button.pressed.connect(_on_gift_pressed)
	_upgrade_button.pressed.connect(_on_upgrade_pressed)
	_star_button.pressed.connect(_on_star_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_seed_initial_state()


## ------------------------------------------------------------------
## 首屏只读快照（属性/技能/装备/好感/羁绊/养成按钮状态）
## ------------------------------------------------------------------
func _seed_initial_state() -> void:
	var cfg: Dictionary = Data.MECH_GIRLS[_mech_id]
	_title_label.text = "机娘详情"
	_name_label.text = "%s（%s · %s）" % [str(cfg.get("name", str(_mech_id))), _rarity_text(int(cfg.get("rarity", 0))), _class_text(StringName(str(cfg.get("class", ""))))]
	_portrait.color = _rarity_color(int(cfg.get("rarity", 0)))
	_bond_label.text = "羁绊数据待接入（后续版本开放）"
	_render_stats()
	_build_skills()
	_build_equip_slots()
	_refresh_affinity()
	_refresh_upgrade_buttons()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_mech_girl_updated(id: StringName, _hp: int, _atk: int, _level: int) -> void:
	if id != _mech_id:
		return
	_render_stats()
	_refresh_upgrade_buttons()


func _on_exp_balance_updated(_balance: int) -> void:
	# v0.19：全局经验池变化 → 刷新升级按钮（经验统一扣池）
	_refresh_upgrade_buttons()


func _on_mech_star_updated(id: StringName, _star: int, _level_cap: int) -> void:
	if id != _mech_id:
		return
	_name_label.text = "%s（%s · %s）" % [str(Data.MECH_GIRLS[_mech_id].get("name", str(_mech_id))), _rarity_text(int(Data.MECH_GIRLS[_mech_id].get("rarity", 0))), _class_text(StringName(str(Data.MECH_GIRLS[_mech_id].get("class", ""))))]
	_render_stats()
	_refresh_upgrade_buttons()


func _on_affinity_changed(id: StringName, _value: int) -> void:
	if id != _mech_id:
		return
	_refresh_affinity()


func _on_equipped_changed(_equipped: Dictionary) -> void:
	_build_equip_slots()
	_render_stats()


func _on_gold_changed(_value: int) -> void:
	_refresh_upgrade_buttons()
	_refresh_affinity()


func _on_fragments_updated(id: StringName, _count: int) -> void:
	if id == _mech_id:
		_refresh_upgrade_buttons()


## ------------------------------------------------------------------
## 属性面板：攻/血来自信号参数（首屏快照用 Game 只读换算），防/速按 Data 公式换算（观察项）
## 战力 = Game.get_power(id) 只读入口
## ------------------------------------------------------------------
func _render_stats() -> void:
	var level: int = int(Game.mech_levels.get(_mech_id, 1))
	var star: int = int(Game.mech_stars.get(_mech_id, 1))
	var cap: int = Game.get_level_cap(_mech_id)
	var atk: int = _calc_atk(_mech_id, level)
	var hp: int = _calc_max_hp(_mech_id, level)
	var def: int = _calc_def(_mech_id, level)
	var spd: int = _calc_spd(_mech_id, level)
	var power: int = Game.get_power(_mech_id)
	_stats_label.text = "Lv.%d/%d  ★%d\n攻 %d  血 %d  防 %d  速 %d\n战力 %s" % [level, cap, star, atk, hp, def, spd, _fmt_num(power)]


## 星级属性乘数（与 Game._mech_stats 同公式：×(1+STAR_STAT_GAIN)^(star-1)）
func _star_mult() -> float:
	var star: int = int(Game.mech_stars.get(_mech_id, 1))
	return pow(1.0 + Data.STAR_STAT_GAIN, float(star - 1))


func _calc_atk(id: StringName, level: int) -> int:
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var base: int = int(cfg.get("base_atk", 0)) + (level - 1) * int(cfg.get("growth", {}).get("atk", 0))
	return int(round(float(base) * _star_mult()))


func _calc_max_hp(id: StringName, level: int) -> int:
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var base: int = int(cfg.get("base_hp", 0)) + (level - 1) * int(cfg.get("growth", {}).get("hp", 0))
	return int(round(float(base) * _star_mult()))


func _calc_def(id: StringName, level: int) -> int:
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var base: int = int(cfg.get("base_def", 0)) + (level - 1) * int(cfg.get("growth", {}).get("def", 0))
	return int(round(float(base) * _star_mult()))


func _calc_spd(id: StringName, level: int) -> int:
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var spd_gain: int = floori(float(level - 1) / float(cfg.get("growth", {}).get("spd_every", 5))) * int(cfg.get("growth", {}).get("spd_amount", 1))
	var base: int = int(cfg.get("base_spd", 0)) + spd_gain
	return int(round(float(base) * _star_mult()))


## ------------------------------------------------------------------
## 技能列表（Data 静态表：被动 / 2 小技 / 大招）
## ------------------------------------------------------------------
func _build_skills() -> void:
	for child in _skills_box.get_children():
		_skills_box.remove_child(child)
		child.queue_free()
	var cfg: Dictionary = Data.MECH_GIRLS[_mech_id]
	_skills_box.add_child(_make_skill_label("被动", cfg.get("passive", {})))
	var skills: Array = cfg.get("skills", [])
	for i in skills.size():
		_skills_box.add_child(_make_skill_label("小技能%d" % (i + 1), skills[i]))
	_skills_box.add_child(_make_skill_label("大招", cfg.get("ultimate", {})))


func _make_skill_label(prefix: String, skill: Dictionary) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	if skill.is_empty():
		label.text = "%s：—" % prefix
		return label
	if str(skill.get("kind", "")) == "passive":
		label.text = "%s：%s（%s）" % [prefix, str(skill.get("name", "")), _passive_effects_text(skill.get("effects", []))]
	else:
		label.text = "%s：%s（%s）" % [prefix, str(skill.get("name", "")), _skill_desc(skill)]
	return label


## 小技/大招参数摘要："CD3 · 单体伤害 180%"
func _skill_desc(s: Dictionary) -> String:
	var parts: Array = []
	if s.has("cd"):
		parts.append("CD%d" % int(s.cd))
	var effect_text: String = _effect_text(StringName(str(s.get("effect", ""))))
	var target_text: String = _target_text(StringName(str(s.get("target", ""))))
	var rate: float = float(s.get("rate", 0.0))
	var hits: int = int(s.get("hits", 1))
	var chance: float = float(s.get("chance", 0.0))
	if effect_text != "":
		parts.append(effect_text)
	if target_text != "":
		parts.append(target_text)
	if rate > 0.0:
		parts.append("%d%%" % roundi(rate * 100.0))
	if hits > 1:
		parts.append("%d 段" % hits)
	if chance > 0.0:
		parts.append("概率 %d%%" % roundi(chance * 100.0))
	return " · ".join(parts)


## 被动 effects 摘要
func _passive_effects_text(effects: Array) -> String:
	var parts: Array = []
	for eff in effects:
		var kind: String = str(eff.get("kind", ""))
		var text: String = _passive_kind_text(kind)
		if eff.has("value") and float(eff.value) < 1.0:
			text += " %d%%" % roundi(float(eff.value) * 100.0)
		elif eff.has("value"):
			text += " %d" % roundi(float(eff.value))
		if eff.has("chance"):
			text += "（%d%%）" % roundi(float(eff.chance) * 100.0)
		parts.append(text)
	return "；".join(parts) if not parts.is_empty() else "—"


func _passive_kind_text(kind: String) -> String:
	match kind:
		"kill_heal": return "击杀回血"
		"crit_rate": return "暴击率+"
		"shield_start": return "开局全队护盾"
		"counter": return "反击"
		"armor_break_on_hit": return "命中破甲"
		"enrage": return "残血加攻"
		"dodge": return "闪避+"
		"dodge_crit": return "闪避后必暴"
		"damage_reduce": return "受伤减免"
		"atk_high_hp": return "高血加攻"
		"atk_up": return "攻击+"
		"combo_chance": return "概率连击"
		"energy_on_hit": return "命中加能量"
		"energy_on_hit_taken": return "受击加能量"
		"heal_per_round": return "每轮回血"
		"ambush": return "开局偷袭"
		"stun_chance": return "概率控制"
		"reflect": return "反弹"
		"execute_bonus": return "斩杀加成"
		"atk_aura": return "全队攻光环"
		"ignore_def": return "无视防御"
	return kind


func _effect_text(effect: StringName) -> String:
	match effect:
		&"damage": return "伤害"
		&"heal": return "治疗"
		&"shield": return "护盾"
		&"buff": return "增益"
		&"debuff": return "减益"
		&"stun": return "眩晕"
		&"freeze": return "冰冻"
		&"burn": return "灼烧"
		&"poison": return "中毒"
		&"taunt": return "嘲讽"
		&"cleanse": return "净化"
	return str(effect)


func _target_text(target: StringName) -> String:
	match target:
		&"single": return "单体"
		&"front": return "前排"
		&"back": return "后排"
		&"all": return "全体"
		&"all_ally": return "全体友方"
		&"self": return "自身"
		&"lowest_hp": return "血量最低"
		&"lowest_hp_ally": return "血量最低友方"
	return str(target)


## ------------------------------------------------------------------
## 装备槽（4 部位：武器/装甲/护腿/战靴；显示穿戴，点击"前往装备界面"）
## ------------------------------------------------------------------
func _build_equip_slots() -> void:
	for child in _equip_box.get_children():
		_equip_box.remove_child(child)
		child.queue_free()
	var equipped: Dictionary = Game.get_equipped()
	var inventory: Array = Game.get_equip_inventory()
	var my_slots: Dictionary = equipped.get(_mech_id, {})
	for slot_name in Data.EQUIP_SLOTS:
		var slot_id := StringName(slot_name)
		var panel := Panel.new()
		panel.custom_minimum_size = Vector2(110, 52)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var label := Label.new()
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 12)
		var slot_name_text: String = str(Data.EQUIP_SLOTS[slot_id].get("name", str(slot_id)))
		if my_slots.has(slot_id):
			var uid := StringName(str(my_slots[slot_id]))
			var eq := _find_equip(inventory, uid)
			if not eq.is_empty():
				label.text = "%s\n%s ★%d" % [slot_name_text, str(Data.EQUIP_SLOTS[slot_id].get("name", str(slot_id))), int(eq.get("star", 1))]
			else:
				label.text = "%s\n（已穿戴）" % slot_name_text
		else:
			label.text = "%s\n空" % slot_name_text
		panel.add_child(label)
		_equip_box.add_child(panel)


func _find_equip(inventory: Array, uid: StringName) -> Dictionary:
	for eq in inventory:
		if StringName(str(eq.get("uid", ""))) == uid:
			return eq
	return {}


## ------------------------------------------------------------------
## 好感度条（Game.get_affinity_info 只读 + affinity_changed 信号）+ 送礼按钮
## ------------------------------------------------------------------
func _refresh_affinity() -> void:
	var info: Dictionary = Game.get_affinity_info()
	var value: int = int(info.get("affinity", {}).get(_mech_id, 0))
	var max_value: int = int(info.get("max", Data.AFFINITY_MAX))
	_affinity_bar.max_value = float(max_value)
	_affinity_bar.value = float(clampi(value, 0, max_value))
	_affinity_value_label.text = "%d/%d" % [value, max_value]
	var gold_now: int = int(Game.gold)
	_gift_button.text = "送礼（%d 金币，+%d）" % [Data.AFFINITY_GIFT_GOLD_COST, Data.AFFINITY_GIFT_VALUE]
	_gift_button.disabled = gold_now < Data.AFFINITY_GIFT_GOLD_COST or value >= max_value


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_upgrade_pressed() -> void:
	# 结果由 gold_changed / mech_girl_updated / exp_balance_updated 回发
	Game.upgrade(_mech_id)


func _on_star_pressed() -> void:
	# 结果由 mech_star_updated / fragments_updated 回发
	Game.upgrade_star(_mech_id)


func _on_gift_pressed() -> void:
	# 结果由 affinity_changed + gold_changed 回发
	Game.give_gift(_mech_id)


func _on_equip_screen_pressed() -> void:
	# 4U：装备界面 = 覆盖层（在详情页之上弹出）
	var equip_ps: PackedScene = load("res://scenes/Equipment.tscn")
	get_tree().root.add_child(equip_ps.instantiate())


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 升级/升星按钮状态（v0.19 经验简化）：升级用只读 Game.upgrade_cost / upgrade_exp_cost
## 判断，经验统一扣**全局经验池（Game.exp_balance）**（个人经验条已取消）；
## 升星用 Game.star_cost 判断（碎片/解锁等级）；不足置灰并提示原因
## ------------------------------------------------------------------
func _refresh_upgrade_buttons() -> void:
	if _mech_id == &"":
		return
	var level: int = int(Game.mech_levels.get(_mech_id, 1))
	var cap: int = Game.get_level_cap(_mech_id)
	var gold_now: int = int(Game.gold)
	var reason: String = ""
	# 升级
	if level >= cap:
		_upgrade_button.text = "已满级"
		_upgrade_button.disabled = true
	else:
		var gold_cost: int = Game.upgrade_cost(_mech_id)
		var exp_cost: int = Game.upgrade_exp_cost(_mech_id)
		var lack_gold: bool = gold_now < gold_cost
		var lack_exp: bool = int(Game.exp_balance) < exp_cost
		_upgrade_button.disabled = lack_gold or lack_exp
		if lack_gold and lack_exp:
			reason = "金币和经验都不足，无法升级"
		elif lack_gold:
			reason = "金币不足，无法升级"
		elif lack_exp:
			reason = "经验不足，无法升级"
	# 升星
	var star: int = int(Game.mech_stars.get(_mech_id, 1))
	if star >= Data.MAX_STAR:
		_star_button.text = "已满星"
		_star_button.disabled = true
	else:
		var cost: Dictionary = Game.star_cost(_mech_id)
		var frag_needed: int = int(cost.get("fragments", 0))
		var frag_have: int = int(Game.fragments.get(_mech_id, 0))
		var level_required: int = int(cost.get("level_required", 0))
		var star_disabled: bool = frag_have < frag_needed or (level_required > 0 and level < level_required)
		_star_button.disabled = star_disabled
		_star_button.text = "升星（%d 片）" % frag_needed
		if reason.is_empty() and star_disabled:
			if frag_have < frag_needed:
				reason = "%s 升星碎片不足：需 %d 片，现有 %d 片" % [str(Data.MECH_GIRLS[_mech_id].get("name", str(_mech_id))), frag_needed, frag_have]
			elif level < level_required:
				reason = "升星需先升到 %d 级" % level_required
	if reason != "":
		_message_label.text = reason
	else:
		_message_label.text = ""


## ------------------------------------------------------------------
## 文本工具
## ------------------------------------------------------------------
func _rarity_text(r: int) -> String:
	match r:
		Data.Rarity.R:
			return "R"
		Data.Rarity.SR:
			return "SR"
		Data.Rarity.SSR:
			return "SSR"
	return "?"


func _class_text(class_id: StringName) -> String:
	match class_id:
		&"tank": return "坦克"
		&"fighter": return "战士"
		&"assassin": return "刺客"
		&"archer": return "射手"
		&"mage": return "法师"
		&"support": return "辅助"
	return str(class_id)


func _rarity_color(rarity: int) -> Color:
	match rarity:
		Data.Rarity.SSR:
			return Color(1.0, 0.82, 0.35)
		Data.Rarity.SR:
			return Color(0.70, 0.52, 0.95)
	return Color(0.55, 0.68, 0.95)


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
