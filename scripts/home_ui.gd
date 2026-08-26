# ==================================================================
# scripts/home_ui.gd —— 家园互动界面脚本（挂在 scenes/Home.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.17（v0.21）、scripts/contract.gd（只读，v0.21 新信号）、
#          scripts/game.gd（B 实际返回字段）
# 职责   ：家园互动覆盖层的纯显示层 + 互动入口。
#          - 连接信号：home_changed(id, count) / affinity_changed(id, value)
#          - 按钮只调入口（契约 §3.6）：互动 → Game.interact_home(mech_id)（每日次数限制，
#            好感 +1）；返回 → queue_free() 关闭覆盖层
#          - 只读入口：Game.get_home_info()（B 实现返回 {home_interact: {mech_id:
#            {day, count}}, limit}）；好感读 Game.get_affinity_info()
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 首屏说明：本场景从主界面覆盖层打开，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Home.tscn 结构一一对应）----
@onready var _home_box: VBoxContainer = $root_box/scroll/home_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.home_changed.connect(_on_home_changed)
	Contract.affinity_changed.connect(_on_affinity_changed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_refresh_list()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_home_changed(_id: StringName, _count: int) -> void:
	_refresh_list()


func _on_affinity_changed(_id: StringName, _value: int) -> void:
	_refresh_list()


## ------------------------------------------------------------------
## 机娘列表（占位色块 + 名 + 好感 + 互动次数/按钮）
## ------------------------------------------------------------------
func _refresh_list() -> void:
	for child in _home_box.get_children():
		_home_box.remove_child(child)
		child.queue_free()
	var home_info: Dictionary = Game.get_home_info()
	var interact_map: Dictionary = home_info.get("home_interact", {})
	var limit: int = int(home_info.get("limit", Data.HOME_INTERACT_LIMIT))
	var affinity_info: Dictionary = Game.get_affinity_info()
	var affinity_map: Dictionary = affinity_info.get("affinity", {})
	var max_aff: int = int(affinity_info.get("max", Data.AFFINITY_MAX))
	var today: String = Time.get_date_string_from_system()
	for mech_id in Game.get_owned_mechs():
		var cfg: Dictionary = Data.MECH_GIRLS.get(mech_id, {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		# 占位色块（稀有度色）
		var color_block := ColorRect.new()
		color_block.custom_minimum_size = Vector2(36, 28)
		color_block.color = _rarity_color(int(cfg.get("rarity", 0)))
		row.add_child(color_block)
		# 名称 + 好感
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var aff: int = int(affinity_map.get(mech_id, 0))
		label.text = "%s　好感 %d/%d" % [str(cfg.get("name", str(mech_id))), aff, max_aff]
		row.add_child(label)
		# 当日次数
		var entry: Dictionary = interact_map.get(mech_id, {})
		var count: int = 0
		if str(entry.get("day", "")) == today:
			count = int(entry.get("count", 0))
		var interact := Button.new()
		if count >= limit:
			interact.text = "今日已互动（%d/%d）" % [count, limit]
			interact.disabled = true
		else:
			interact.text = "互动（%d/%d）" % [count, limit]
			interact.pressed.connect(_on_interact_pressed.bind(mech_id))
		row.add_child(interact)
		_home_box.add_child(row)


func _on_interact_pressed(mech_id: StringName) -> void:
	# 结果由 home_changed + affinity_changed 信号回发
	Game.interact_home(mech_id)
	_message_label.text = "与 %s 互动 +1 好感" % str(Data.MECH_GIRLS.get(mech_id, {}).get("name", str(mech_id)))


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 文本工具
## ------------------------------------------------------------------
func _rarity_color(rarity: int) -> Color:
	match rarity:
		Data.Rarity.SSR:
			return Color(1.0, 0.82, 0.35)
		Data.Rarity.SR:
			return Color(0.70, 0.52, 0.95)
	return Color(0.55, 0.68, 0.95)
