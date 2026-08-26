# ==================================================================
# scripts/formation_ui.gd —— 布阵界面脚本（挂在 scenes/Formation.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.9（v0.8）、scripts/contract.gd（只读）
# 职责   ：布阵页（4U 起作为主界面"布阵"主页面嵌入，无返回按钮）的纯显示层 + 编辑草稿。
#          - 连接信号：formation_changed（阵型变化，以信号为准刷新显示）
#          - 按钮只调入口（契约 §3.6）：保存阵型 → Game.set_formation(draft)；
#            预设保存/载入 → Game.save_formation_preset(index, draft) /
#                          Game.load_formation_preset(index)；开始战斗 → Game.set_formation(draft)
#                          + Game.start_battle(get_next_level()) + 打开战斗覆盖层 Battle.tscn
#          - 只读入口：Game.get_formation()（首屏快照 / 信号到达后同步）；上阵战力 =
#            Game.get_formation + Game.get_power 只读组合（与 Game._team_power 同公式）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit；
#          草稿为 UI 编辑态，仅在"保存阵型"/"开始战斗"时提交给 Game，显示以信号为准。
# 交互   ：候选列表点选机娘 → 点九宫格放置/替换；不选机娘点已占格 = 移除。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Formation.tscn 结构一一对应）----
@onready var _grid: GridContainer = $root_box/grid
@onready var _candidate_box: VBoxContainer = $root_box/candidate_box
@onready var _preset_box: VBoxContainer = $root_box/preset_box
@onready var _save_button: Button = $root_box/save_button
@onready var _message_label: Label = $root_box/message_label
@onready var _power_label: Label = $root_box/bottom_row/power_label
@onready var _start_button: Button = $root_box/bottom_row/start_button

## ---- UI 编辑态（草稿，非 Game 数值；提交后以 formation_changed 为准）----
var _cells: Array = []                     # 9 个格子 Button（索引 = row*3+col）
var _draft: Array = []                     # [{id, row, col}] 编辑中的阵型
var _selected_mech: StringName = &""       # 候选列表中当前选中的机娘


func _ready() -> void:
	Contract.formation_changed.connect(_on_formation_changed)
	_save_button.pressed.connect(_on_save_pressed)
	_start_button.pressed.connect(_on_start_pressed)
	_build_grid()
	_build_presets()
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）：草稿 = 当前阵型
	_sync_from_game()
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理
## ------------------------------------------------------------------
func _on_formation_changed(_formation: Array) -> void:
	# 以信号为准：草稿同步为 Game 当前阵型并刷新显示
	_sync_from_game()
	_refresh_all()
	_message_label.text = "阵型已保存"


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_save_pressed() -> void:
	Game.set_formation(_draft)  # 成功经 formation_changed 回发，失败不发信号（草稿非法时）
	if _draft.size() < 2:
		_message_label.text = "至少放置 2 名机娘"
	elif _draft.size() > 5:
		_message_label.text = "最多放置 5 名机娘"


func _on_start_pressed() -> void:
	# 4U：先提交草稿（校验失败不发信号），再开始主线战斗并打开战斗覆盖层
	Game.set_formation(_draft)
	var level: int = Game.get_next_level()
	if level < 1 or level > Data.MAX_LEVEL:
		_message_label.text = "主线已全部通关"
		return
	Game.start_battle(level)
	var battle_ps: PackedScene = load("res://scenes/Battle.tscn")
	get_tree().root.add_child(battle_ps.instantiate())


## ------------------------------------------------------------------
## 九宫格（3x3，索引 = row*3+col）
## ------------------------------------------------------------------
func _build_grid() -> void:
	for i in 9:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(150, 70)
		btn.text = "空"
		btn.pressed.connect(_on_cell_pressed.bind(i))
		_grid.add_child(btn)
		_cells.append(btn)


func _on_cell_pressed(index: int) -> void:
	var row: int = index / 3
	var col: int = index % 3
	var cell_has: StringName = _draft_id_at(row, col)
	if _selected_mech != &"":
		# 放置/移动/替换：目标格已有其它机娘则被替换；同一机娘已占其它格则移动
		if cell_has != &"" and cell_has != _selected_mech:
			_draft.erase(_find_slot(row, col))
		_draft.erase(_find_slot_of(_selected_mech))
		if _draft.size() >= 5:
			_message_label.text = "最多放置 5 名机娘"
			_refresh_candidates()
			return
		_draft.append({ "id": _selected_mech, "row": row, "col": col })
	else:
		# 未选中机娘：点已占格 = 移除
		if cell_has != &"":
			_draft.erase(_find_slot(row, col))
	_refresh_all()


func _refresh_all() -> void:
	_refresh_grid()
	_refresh_candidates()
	_refresh_power()


## 上阵战力 = 草稿阵型各机娘战力合计（Game.get_power 只读入口组合，与 Game._team_power 同公式）
func _refresh_power() -> void:
	var total := 0
	for slot in _draft:
		var mid := StringName(str(slot.get("id", "")))
		if mid != &"":
			total += Game.get_power(mid)
	_power_label.text = "上阵战力：%s" % _fmt_num(total)


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


func _refresh_grid() -> void:
	for i in 9:
		var btn: Button = _cells[i]
		var id: StringName = _draft_id_at(i / 3, i % 3)
		if id != &"":
			var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
			btn.text = str(cfg.get("name", str(id)))
		else:
			btn.text = "空"


func _refresh_candidates() -> void:
	for child in _candidate_box.get_children():
		_candidate_box.remove_child(child)
		child.queue_free()
	for mech_id in Game.get_owned_mechs():
		var cfg: Dictionary = Data.MECH_GIRLS.get(mech_id, {})
		var btn := Button.new()
		var placed: bool = _find_slot_of(mech_id) != null
		btn.text = "%s（%s）%s" % [str(cfg.get("name", str(mech_id))), str(cfg.get("class", "")), "（已放置）" if placed else ""]
		btn.disabled = placed
		btn.button_pressed = (mech_id == _selected_mech)
		btn.pressed.connect(_on_candidate_pressed.bind(mech_id))
		_candidate_box.add_child(btn)


func _on_candidate_pressed(mech_id: StringName) -> void:
	_selected_mech = mech_id
	_refresh_candidates()
	_message_label.text = "已选择：%s，点击九宫格放置" % str(Data.MECH_GIRLS.get(mech_id, {}).get("name", str(mech_id)))


## ------------------------------------------------------------------
## 预设（2~3 套，index 0..2）
## ------------------------------------------------------------------
func _build_presets() -> void:
	for index in 3:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = "预设 %d" % (index + 1)
		label.custom_minimum_size = Vector2(80, 0)
		var save_btn := Button.new()
		save_btn.text = "保存"
		save_btn.pressed.connect(_on_save_preset_pressed.bind(index))
		var load_btn := Button.new()
		load_btn.text = "载入"
		load_btn.pressed.connect(_on_load_preset_pressed.bind(index))
		row.add_child(label)
		row.add_child(save_btn)
		row.add_child(load_btn)
		_preset_box.add_child(row)


func _on_save_preset_pressed(index: int) -> void:
	Game.save_formation_preset(index, _draft)
	_message_label.text = "已保存到预设 %d" % (index + 1)


func _on_load_preset_pressed(index: int) -> void:
	Game.load_formation_preset(index)  # 应用后经 formation_changed 回发


## ------------------------------------------------------------------
## 草稿工具
## ------------------------------------------------------------------
func _sync_from_game() -> void:
	_draft = []
	for slot in Game.get_formation():
		_draft.append({ "id": StringName(str(slot.get("id", ""))), "row": int(slot.get("row", 0)), "col": int(slot.get("col", 0)) })


func _draft_id_at(row: int, col: int) -> StringName:
	var slot: Variant = _find_slot(row, col)
	return StringName(str(slot.get("id", ""))) if slot != null else &""


func _find_slot(row: int, col: int):
	for slot in _draft:
		if int(slot.row) == row and int(slot.col) == col:
			return slot
	return null


func _find_slot_of(mech_id: StringName):
	for slot in _draft:
		if StringName(str(slot.id)) == mech_id:
			return slot
	return null
