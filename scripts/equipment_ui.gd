# ==================================================================
# scripts/equipment_ui.gd —— 装备界面脚本（挂在 scenes/Equipment.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.11（v0.14）、scripts/contract.gd（只读）
# 职责   ：装备界面的纯显示层 + 操作入口。
#          - 连接信号：equip_inventory_changed / equipped_changed / gem_stock_changed /
#            mech_girl_updated（穿卸后机娘属性变化）
#          - 按钮只调入口（契约 §3.6）：穿/卸 → Game.equip / Game.unequip；
#            强化 → Game.upgrade_equip；合成 → Game.combine_equip(3 同星)；
#            镶嵌/拆卸 → Game.socket_gem / Game.unsocket_gem；宝石合成 → Game.combine_gems；
#            返回 → 切回 Main.tscn
#          - 只读入口：get_equip_inventory / get_equipped / get_equip_stats /
#            upgrade_equip_cost / get_gem_stock / get_power / get_owned_mechs
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 交互   ：选择机娘 → 装备库点"穿/卸"；"选"勾选 ≤3 件同星后"合成"；
#          装备行空孔点"镶"选目标 → 宝石区选品质镶嵌；孔"拆"免费拆卸。
# ==================================================================
extends Control

## 宝石品质显示名（Data.GEM_QUALITIES 顺序：白<绿<蓝<紫<金<红）
const _GEM_NAMES := ["白", "绿", "蓝", "紫", "金", "红"]

## 装备属性显示名（get_equip_stats 返回键）
const _STAT_NAMES := {
	"atk": "攻", "hp": "血", "def": "防", "spd": "速",
	"atk_pct": "攻%", "hp_pct": "血%", "def_pct": "防%",
	"crit_rate": "暴击率", "crit_dmg": "暴伤", "dodge": "闪避",
}

## ---- 节点引用（与 scenes/Equipment.tscn 结构一一对应）----
@onready var _mech_select_box: HBoxContainer = $root_box/mech_select_box
@onready var _equipped_label: Label = $root_box/equipped_label
@onready var _equip_list: VBoxContainer = $root_box/equip_list
@onready var _combine_button: Button = $root_box/combine_button
@onready var _gem_box: VBoxContainer = $root_box/gem_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button

## ---- UI 交互态（不含任何游戏数值）----
var _selected_mech: StringName = &""          # 当前选中的机娘
var _selected_uids: Array = []                # 合成候选（≤3 件同星未穿戴）
var _socket_target: StringName = &""          # 镶嵌目标装备 uid


func _ready() -> void:
	Contract.equip_inventory_changed.connect(_on_equip_inventory_changed)
	Contract.equipped_changed.connect(_on_equipped_changed)
	Contract.gem_stock_changed.connect(_on_gem_stock_changed)
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
	_combine_button.pressed.connect(_on_combine_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）
	var owned: Array = Game.get_owned_mechs()
	if not owned.is_empty():
		_selected_mech = StringName(str(owned[0]))
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理（全量刷新显示；候选/目标跨操作保留）
## ------------------------------------------------------------------
func _on_equip_inventory_changed(_inventory: Array) -> void:
	_refresh_all()


func _on_equipped_changed(_equipped: Dictionary) -> void:
	_refresh_all()


func _on_gem_stock_changed(_stock: Dictionary) -> void:
	_refresh_all()


func _on_mech_girl_updated(_id: StringName, _hp: int, _atk: int, _level: int) -> void:
	# 穿卸/强化/镶嵌后机娘属性变化——刷新穿戴区战力显示
	_refresh_equipped_label()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_combine_pressed() -> void:
	if _selected_uids.size() == 3:
		Game.combine_equip(_selected_uids)  # 结果由 equip_inventory_changed / gem_stock_changed 回发
		_selected_uids = []
		_socket_target = &""


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 机娘选择
## ------------------------------------------------------------------
func _refresh_mech_select() -> void:
	for child in _mech_select_box.get_children():
		_mech_select_box.remove_child(child)
		child.queue_free()
	for mech_id in Game.get_owned_mechs():
		var btn := Button.new()
		btn.text = str(Data.MECH_GIRLS.get(mech_id, {}).get("name", str(mech_id)))
		btn.toggle_mode = true
		btn.button_pressed = (mech_id == _selected_mech)
		btn.pressed.connect(_on_mech_pressed.bind(mech_id))
		_mech_select_box.add_child(btn)


func _on_mech_pressed(mech_id: StringName) -> void:
	_selected_mech = mech_id
	_socket_target = &""
	_refresh_all()


## ------------------------------------------------------------------
## 穿戴显示（选中机娘：四部位 + 战力）
## ------------------------------------------------------------------
func _refresh_equipped_label() -> void:
	if _selected_mech == &"":
		_equipped_label.text = "未选择机娘"
		return
	var equipped: Dictionary = Game.get_equipped()
	var slots: Dictionary = equipped.get(_selected_mech, {})
	var parts: Array = []
	for slot in Data.EQUIP_SLOTS:
		var uid: StringName = StringName(str(slots.get(slot, &"")))
		if uid != &"":
			var eq := _find_equip(uid)
			parts.append("%s %s★%d" % [str(Data.EQUIP_SLOTS[slot].get("name", str(slot))), _slot_name(slot), int(eq.get("star", 1))])
		else:
			parts.append("%s 无" % str(Data.EQUIP_SLOTS[slot].get("name", str(slot))))
	var power: int = Game.get_power(_selected_mech)
	_equipped_label.text = "%s | 战力 %d | %s" % [
		str(Data.MECH_GIRLS.get(_selected_mech, {}).get("name", str(_selected_mech))),
		power, " | ".join(parts)]


func _find_equip(uid: StringName) -> Dictionary:
	for eq in Game.get_equip_inventory():
		if StringName(str(eq.get("uid", &""))) == uid:
			return eq
	return {}


## ------------------------------------------------------------------
## 装备库列表
## ------------------------------------------------------------------
func _refresh_equip_list() -> void:
	for child in _equip_list.get_children():
		_equip_list.remove_child(child)
		child.queue_free()
	var inventory: Array = Game.get_equip_inventory()
	if inventory.is_empty():
		var empty := Label.new()
		empty.text = "装备库为空（秘境装备/宝石副本掉落）"
		_equip_list.add_child(empty)
		return
	for eq in inventory:
		_equip_list.add_child(_make_equip_row(eq))


func _make_equip_row(eq: Dictionary) -> VBoxContainer:
	var uid := StringName(str(eq.get("uid", &"")))
	var slot := StringName(str(eq.get("slot", &"")))
	var star: int = int(eq.get("star", 1))
	var level: int = int(eq.get("level", 0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	# 信息行
	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 6)
	var info := Label.new()
	var sockets: int = int(Data.GEM_SOCKETS.get(star, 1))
	info.text = "%s ★%d +%d | %s | 宝石 %d/%d" % [
		_slot_name(slot), star, level, _stats_text(uid), int(eq.get("gems", []).size()), sockets]
	info.custom_minimum_size = Vector2(360, 0)
	var equip_btn := Button.new()
	equip_btn.text = _equip_button_text(uid, slot)
	equip_btn.pressed.connect(_on_equip_pressed.bind(uid, slot))
	var upgrade_btn := Button.new()
	var cost: Dictionary = Game.upgrade_equip_cost(uid)
	if int(cost.get("gold", 0)) <= 0:
		upgrade_btn.text = "已满级"
		upgrade_btn.disabled = true
	else:
		upgrade_btn.text = "强化(%d金+%d材)" % [int(cost.get("gold", 0)), int(cost.get("material", 0))]
	upgrade_btn.pressed.connect(_on_upgrade_pressed.bind(uid))
	var select_btn := Button.new()
	select_btn.text = "选"
	select_btn.toggle_mode = true
	select_btn.button_pressed = _selected_uids.has(uid)
	select_btn.pressed.connect(_on_select_pressed.bind(uid))
	info_row.add_child(info)
	info_row.add_child(equip_btn)
	info_row.add_child(upgrade_btn)
	info_row.add_child(select_btn)
	box.add_child(info_row)
	# 宝石孔行（每孔：品质词条 + 拆；空孔：镶）
	var gems: Array = eq.get("gems", [])
	for idx in sockets:
		var socket_row := HBoxContainer.new()
		socket_row.add_theme_constant_override("separation", 6)
		var label := Label.new()
		label.custom_minimum_size = Vector2(300, 0)
		if idx < gems.size():
			var g: Dictionary = gems[idx]
			var q_name: String = _gem_name(StringName(str(g.get("quality", &""))))
			label.text = "  孔%d：%s %s" % [idx + 1, q_name, _affixes_text(g.get("affixes", []))]
			var unsocket_btn := Button.new()
			unsocket_btn.text = "拆"
			unsocket_btn.pressed.connect(_on_unsocket_pressed.bind(uid, idx))
			socket_row.add_child(label)
			socket_row.add_child(unsocket_btn)
		else:
			label.text = "  孔%d：空" % (idx + 1)
			var socket_btn := Button.new()
			socket_btn.text = "镶"
			socket_btn.pressed.connect(_on_socket_pressed.bind(uid))
			socket_row.add_child(label)
			socket_row.add_child(socket_btn)
		box.add_child(socket_row)
	return box


func _equip_button_text(uid: StringName, slot: StringName) -> String:
	var equipped: Dictionary = Game.get_equipped()
	var wearer := &""
	for mech_id in equipped:
		if StringName(str(equipped[mech_id].get(slot, &""))) == uid:
			wearer = StringName(mech_id)
			break
	if wearer != &"":
		return "卸"
	return "穿"


func _on_equip_pressed(uid: StringName, slot: StringName) -> void:
	if _equip_button_text(uid, slot) == "卸":
		# 找到穿戴者卸下
		var equipped: Dictionary = Game.get_equipped()
		for mech_id in equipped:
			if StringName(str(equipped[mech_id].get(slot, &""))) == uid:
				Game.unequip(StringName(mech_id), slot)
				return
	if _selected_mech == &"":
		_message_label.text = "请先选择机娘"
		return
	Game.equip(_selected_mech, uid)


func _on_upgrade_pressed(uid: StringName) -> void:
	Game.upgrade_equip(uid)  # 结果由 equip_inventory_changed / gold_changed / bag_updated 回发


func _on_select_pressed(uid: StringName) -> void:
	if _selected_uids.has(uid):
		_selected_uids.erase(uid)
		_refresh_all()
		return
	# 校验同星、未穿戴、数量
	var eq := _find_equip(uid)
	if eq.is_empty() or _is_equipped_anywhere(uid):
		return
	if _selected_uids.is_empty():
		_selected_uids.append(uid)
	elif int(_find_equip(StringName(str(_selected_uids[0]))).get("star", 0)) == int(eq.get("star", 0)) and _selected_uids.size() < 3:
		_selected_uids.append(uid)
	else:
		_message_label.text = "合成需选择 3 件同星且未穿戴的装备"
	_refresh_all()


func _is_equipped_anywhere(uid: StringName) -> bool:
	var equipped: Dictionary = Game.get_equipped()
	for mech_id in equipped:
		for slot in equipped[mech_id]:
			if StringName(str(equipped[mech_id][slot])) == uid:
				return true
	return false


## ------------------------------------------------------------------
## 宝石区
## ------------------------------------------------------------------
func _refresh_gem_box() -> void:
	for child in _gem_box.get_children():
		_gem_box.remove_child(child)
		child.queue_free()
	var stock: Dictionary = Game.get_gem_stock()
	for i in Data.GEM_QUALITIES.size():
		var quality := StringName(str(Data.GEM_QUALITIES[i]))
		var count: int = int(stock.get(quality, 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = "%s宝石 ×%d" % [_GEM_NAMES[i], count]
		label.custom_minimum_size = Vector2(200, 0)
		var socket_btn := Button.new()
		socket_btn.text = "镶"
		socket_btn.disabled = (_socket_target == &"" or count <= 0)
		socket_btn.pressed.connect(_on_gem_socket_pressed.bind(quality))
		var combine_btn := Button.new()
		combine_btn.text = "合"
		combine_btn.disabled = (count < 3 or i >= Data.GEM_QUALITIES.size() - 1)
		combine_btn.pressed.connect(_on_gem_combine_pressed.bind(quality))
		row.add_child(label)
		row.add_child(socket_btn)
		row.add_child(combine_btn)
		_gem_box.add_child(row)


func _on_socket_pressed(uid: StringName) -> void:
	_socket_target = uid
	_message_label.text = "已选择镶嵌目标，请在宝石区选择品质"
	_refresh_all()


func _on_gem_socket_pressed(quality: StringName) -> void:
	if _socket_target == &"":
		_message_label.text = "请先点击装备空孔的'镶'选择目标"
		return
	Game.socket_gem(_socket_target, quality)
	_socket_target = &""


func _on_unsocket_pressed(uid: StringName, idx: int) -> void:
	Game.unsocket_gem(uid, idx)


func _on_gem_combine_pressed(quality: StringName) -> void:
	Game.combine_gems(quality)


## ------------------------------------------------------------------
## 刷新
## ------------------------------------------------------------------
func _refresh_all() -> void:
	_refresh_mech_select()
	_refresh_equipped_label()
	_refresh_equip_list()
	_refresh_combine_button()
	_refresh_gem_box()


func _refresh_combine_button() -> void:
	if _selected_uids.size() == 3:
		var eq := _find_equip(StringName(str(_selected_uids[0])))
		_combine_button.text = "合成（%d★ → %d★）" % [int(eq.get("star", 0)), int(eq.get("star", 0)) + 1]
		_combine_button.disabled = false
	else:
		_combine_button.text = "合成（选 3 件同星，已选 %d）" % _selected_uids.size()
		_combine_button.disabled = true


## ------------------------------------------------------------------
## 文本工具（静态信息读 Data；动态值只来自只读入口）
## ------------------------------------------------------------------
func _slot_name(slot: StringName) -> String:
	return str(Data.EQUIP_SLOTS.get(slot, {}).get("name", str(slot)))


func _gem_name(quality: StringName) -> String:
	var idx: int = Data.GEM_QUALITIES.find(quality)
	if idx >= 0 and idx < _GEM_NAMES.size():
		return _GEM_NAMES[idx] + "宝石"
	return str(quality)


## 装备属性摘要（get_equip_stats 只读入口，非零项）
func _stats_text(uid: StringName) -> String:
	var stats: Dictionary = Game.get_equip_stats(uid)
	var parts: Array = []
	for key in _STAT_NAMES:
		var v: float = float(stats.get(key, 0.0))
		if absf(v) < 0.0001:
			continue
		if str(key).ends_with("_pct") or key == "crit_rate" or key == "crit_dmg" or key == "dodge":
			parts.append("%s%.0f%%" % [str(_STAT_NAMES[key]), v * 100.0])
		else:
			parts.append("%s%.0f" % [str(_STAT_NAMES[key]), v])
	return " ".join(parts) if not parts.is_empty() else "无属性"


func _affixes_text(affixes: Array) -> String:
	var parts: Array = []
	for a in affixes:
		var stat: String = str(a.get("stat", ""))
		var value: float = float(a.get("value", 0.0))
		var name: String = str(_STAT_NAMES.get(stat, stat))
		if stat.ends_with("_pct") or stat == "crit_rate" or stat == "crit_dmg" or stat == "dodge":
			parts.append("%s%.0f%%" % [name, value * 100.0])
		else:
			parts.append("%s%.1f" % [name, value])
	return " ".join(parts) if not parts.is_empty() else "无词条"
