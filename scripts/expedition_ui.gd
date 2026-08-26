# ==================================================================
# scripts/expedition_ui.gd —— 远征/派遣界面脚本（挂在 scenes/Expedition.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.17（v0.21）、scripts/contract.gd（只读，v0.21 新信号）、
#          scripts/game.gd（B 实际返回字段）
# 职责   ：远征覆盖层的纯显示层 + 派遣/领取入口。
#          - 连接信号：expedition_changed(expedition)
#          - 按钮只调入口（契约 §3.6）：派遣 → Game.start_expedition(mech_id, task_id)；
#            领取 → Game.collect_expedition(mech_id)；返回 → queue_free() 关闭覆盖层
#          - 只读入口：Game.get_expedition_info()（B 实现返回 {expedition: {mech_id:
#            {task_id, end_time, done}}, tasks: [{id,name,hours,gold,exp,material}]}）；
#            闲置机娘 = 已拥有 − 上阵（Game.get_formation）− 已派遣
#          - 倒计时：UI 内部 Timer 每秒刷新剩余时间显示（读 end_time 计算，不修改任何游戏数值）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 首屏说明：本场景从主界面覆盖层打开，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Expedition.tscn 结构一一对应）----
@onready var _ongoing_box: VBoxContainer = $root_box/ongoing_box
@onready var _task_box: VBoxContainer = $root_box/task_box
@onready var _mech_box: VBoxContainer = $root_box/mech_box
@onready var _dispatch_button: Button = $root_box/dispatch_button
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button

## ---- UI 编辑态（选中项，非游戏数值）----
var _selected_mech: StringName = &""
var _selected_task: StringName = &""
var _timer: Timer


func _ready() -> void:
	Contract.expedition_changed.connect(_on_expedition_changed)
	_dispatch_button.pressed.connect(_on_dispatch_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# 倒计时刷新（UI 内部计时，每秒重算显示）
	_timer = Timer.new()
	_timer.wait_time = 1.0
	_timer.autostart = true
	_timer.timeout.connect(_refresh_ongoing)
	add_child(_timer)
	# 首屏只读快照（见文件头"首屏说明"）
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_expedition_changed(_expedition: Dictionary) -> void:
	_refresh_all()


## ------------------------------------------------------------------
## 刷新全部（进行中 / 任务列表 / 闲置机娘列表 / 派遣按钮）
## ------------------------------------------------------------------
func _refresh_all() -> void:
	var info: Dictionary = Game.get_expedition_info()
	_refresh_ongoing()
	_build_task_list(info.get("tasks", []))
	_build_mech_list(info.get("expedition", {}))
	_dispatch_button.disabled = _selected_mech == &"" or _selected_task == &""


## 进行中列表（倒计时 / 到期领取）
func _refresh_ongoing() -> void:
	for child in _ongoing_box.get_children():
		_ongoing_box.remove_child(child)
		child.queue_free()
	var info: Dictionary = Game.get_expedition_info()
	var exp_map: Dictionary = info.get("expedition", {})
	if exp_map.is_empty():
		var empty := Label.new()
		empty.text = "暂无远征中的机娘"
		empty.add_theme_font_size_override("font_size", 12)
		_ongoing_box.add_child(empty)
		return
	var now: int = int(Time.get_unix_time_from_system())
	for mech_id in exp_map:
		var entry: Dictionary = exp_map[mech_id]
		var task_cfg: Dictionary = Data.EXPEDITION_TASKS.get(StringName(str(entry.get("task_id", ""))), {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 12)
		var mech_name: String = str(Data.MECH_GIRLS.get(mech_id, {}).get("name", str(mech_id)))
		var task_name: String = str(task_cfg.get("name", "?"))
		var done: bool = bool(entry.get("done", false))
		var remain: String = _format_remain(int(entry.get("end_time", 0)) - now)
		label.text = "%s：%s　%s" % [mech_name, task_name, ("已到期" if done else "剩余 " + remain)]
		var collect := Button.new()
		if done:
			collect.text = "领取"
			collect.pressed.connect(_on_collect_pressed.bind(StringName(mech_id)))
		else:
			collect.text = "…"
			collect.disabled = true
		row.add_child(label)
		row.add_child(collect)
		_ongoing_box.add_child(row)


## 任务列表（时长/奖励；点选）
func _build_task_list(tasks: Array) -> void:
	for child in _task_box.get_children():
		_task_box.remove_child(child)
		child.queue_free()
	for task in tasks:
		var task_id := StringName(str(task.get("id", "")))
		var btn := Button.new()
		btn.text = "%s（%d 小时） 金币%d 经验%d 材料%d" % [
			str(task.get("name", str(task_id))),
			int(task.get("hours", 0)),
			int(task.get("gold", 0)),
			int(task.get("exp", 0)),
			int(task.get("material", 0)),
		]
		btn.toggle_mode = true
		btn.button_pressed = (task_id == _selected_task)
		btn.pressed.connect(_on_task_pressed.bind(task_id))
		_task_box.add_child(btn)


func _on_task_pressed(task_id: StringName) -> void:
	_selected_task = task_id
	_build_task_list(Game.get_expedition_info().get("tasks", []))
	_refresh_dispatch_state()


## 闲置机娘列表（已拥有 − 上阵 − 已派遣；点选）
func _build_mech_list(exp_map: Dictionary) -> void:
	for child in _mech_box.get_children():
		_mech_box.remove_child(child)
		child.queue_free()
	var formation_ids := {}
	for slot in Game.get_formation():
		formation_ids[StringName(str(slot.get("id", "")))] = true
	for mech_id in Game.get_owned_mechs():
		if formation_ids.has(mech_id) or exp_map.has(mech_id):
			continue  # 上阵/已派遣 = 非闲置
		var cfg: Dictionary = Data.MECH_GIRLS.get(mech_id, {})
		var btn := Button.new()
		btn.text = "%s（闲置）" % str(cfg.get("name", str(mech_id)))
		btn.toggle_mode = true
		btn.button_pressed = (mech_id == _selected_mech)
		btn.pressed.connect(_on_mech_pressed.bind(mech_id))
		_mech_box.add_child(btn)


func _on_mech_pressed(mech_id: StringName) -> void:
	_selected_mech = mech_id
	_build_mech_list(Game.get_expedition_info().get("expedition", {}))
	_refresh_dispatch_state()


func _refresh_dispatch_state() -> void:
	_dispatch_button.disabled = _selected_mech == &"" or _selected_task == &""


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_dispatch_pressed() -> void:
	if _selected_mech == &"" or _selected_task == &"":
		return
	# 结果由 expedition_changed 信号回发
	Game.start_expedition(_selected_mech, _selected_task)
	_message_label.text = "已派遣 %s" % str(Data.MECH_GIRLS.get(_selected_mech, {}).get("name", str(_selected_mech)))


func _on_collect_pressed(mech_id: StringName) -> void:
	# 结果由 expedition_changed + 货币信号回发
	Game.collect_expedition(mech_id)


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 文本工具
## ------------------------------------------------------------------
## 剩余时间（秒 → HH:MM:SS；纯显示）
func _format_remain(seconds: int) -> String:
	var s: int = maxi(seconds, 0)
	var h: int = s / 3600
	var m: int = (s % 3600) / 60
	var sec: int = s % 60
	return "%02d:%02d:%02d" % [h, m, sec]
