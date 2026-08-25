# ==================================================================
# scripts/battle_view.gd —— 战斗画面脚本 2.0（挂在 scenes/Battle.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.4 / §3.5 / §3.6 / §3.9（v0.8）、scripts/contract.gd（只读）
# 职责   ：战斗画面的纯显示层（契约 §3.4 / §3.9）：
#          - 连接信号（11 个）：battle_tick / mech_girl_updated / enemy_updated /
#            skill_cast / energy_changed / status_changed / wave_changed /
#            battle_prompt / battle_star / level_cleared / battle_failed
#          - 显示：双方 3x3 九宫格站位（血条/能量条/状态）、技能名、波次、分色提示、
#            星级、简版伤害统计；按钮只调入口（2x → Game.toggle_accelerate；
#            开始/重试 → Game.start_battle；返回 → Game.stop_battle + 切场景；
#            v0.9：主线无扫荡入口，扫荡仅限秘境、阶段 3 实装）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          无物理碰撞 / 位移运算、不自己扣血；一切更新值以 Game 信号参数为准。
# 布局快照说明：九宫格站位（row/col）与能量初值等信号不携带，故 _ready 与波次切换
#          （wave_changed）时对 Game.battle 做【只读快照】铺棋盘（契约 §3.1"首屏铺底例外"
#          同性质）；此后血量/能量/状态等一切更新一律走信号。
# 状态记录：status_changed 为"增/刷新(duration>0) 或 移除(0)"语义，UI 需按 id 累计
#          集合才能展示状态图标（显示层聚合，不修改任何数值）。
# 伤害统计：战斗结束时（battle_star / level_cleared / battle_failed）只读 Game.battle.mechs
#          的 dmg_dealt / heal_done 汇总展示（Game 累计，UI 只显示）。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Battle.tscn 结构一一对应）----
@onready var _title_label: Label = $root_box/title_label
@onready var _wave_label: Label = $root_box/info_row/wave_label
@onready var _tick_label: Label = $root_box/info_row/tick_label
@onready var _star_label: Label = $root_box/info_row/star_label
@onready var _my_grid: GridContainer = $root_box/boards_row/my_column/my_grid
@onready var _enemy_grid: GridContainer = $root_box/boards_row/enemy_column/enemy_grid
@onready var _prompt_box: VBoxContainer = $root_box/prompt_box
@onready var _stat_label: Label = $root_box/stat_label
@onready var _status_label: Label = $root_box/status_label
@onready var _accelerate_button: Button = $root_box/button_row/accelerate_button
@onready var _retry_button: Button = $root_box/button_row/retry_button
@onready var _back_button: Button = $root_box/button_row/back_button

## ---- 显示层状态（棋盘格引用 / 状态聚合，不含可写游戏数值）----
var _mech_cells: Array = []                 # 9 格（索引 = row*3+col）
var _enemy_cells: Array = []                # 9 格
var _mech_cells_by_id: Dictionary = {}      # id -> cell
var _enemy_cells_by_id: Dictionary = {}     # id -> cell
var _cell_statuses: Dictionary = {}         # id -> {status_id: duration}
var _unit_names: Dictionary = {}            # id -> 显示名（提示用）
var _battle_level: int = 1
var _retry_level: int = 1


func _ready() -> void:
	Contract.battle_tick.connect(_on_battle_tick)
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
	Contract.enemy_updated.connect(_on_enemy_updated)
	Contract.skill_cast.connect(_on_skill_cast)
	Contract.energy_changed.connect(_on_energy_changed)
	Contract.status_changed.connect(_on_status_changed)
	Contract.wave_changed.connect(_on_wave_changed)
	Contract.battle_prompt.connect(_on_battle_prompt)
	Contract.battle_star.connect(_on_battle_star)
	Contract.level_cleared.connect(_on_level_cleared)
	Contract.battle_failed.connect(_on_battle_failed)
	_accelerate_button.toggled.connect(_on_accelerate_toggled)
	_retry_button.pressed.connect(_on_retry_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	_mech_cells = _build_grid(_my_grid)
	_enemy_cells = _build_grid(_enemy_grid)
	_retry_button.visible = false
	_seed_initial_state()


## ------------------------------------------------------------------
## 首屏只读快照（见文件头"布局快照说明"）
## ------------------------------------------------------------------
func _seed_initial_state() -> void:
	if not Game.battle.active:
		_status_label.text = "未在战斗中，请点击开始战斗"
		return
	_battle_level = int(Game.battle.level)
	_title_label.text = "第 %d 关 · 战斗" % _battle_level
	_wave_label.text = "第 %d/%d 波" % [int(Game.battle.wave), int(Game.battle.total_waves)]
	_accelerate_button.button_pressed = bool(Game.battle.accelerate)
	_place_units(Game.battle.mechs, _mech_cells, _mech_cells_by_id, &"mech")
	_place_units(Game.battle.enemies, _enemy_cells, _enemy_cells_by_id, &"enemy")


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_battle_tick(tick: int) -> void:
	_tick_label.text = "第 %d 轮" % tick


func _on_mech_girl_updated(id: StringName, hp: int, atk: int, level: int) -> void:
	_apply_hp(_mech_cells_by_id.get(id, {}), id, hp)


func _on_enemy_updated(id: StringName, hp: int) -> void:
	_apply_hp(_enemy_cells_by_id.get(id, {}), id, hp)


func _apply_hp(cell: Dictionary, id: StringName, hp: int) -> void:
	if cell.is_empty():
		return
	cell.hp_bar.value = float(clampi(hp, 0, int(cell.max_hp)))
	if hp <= 0:
		cell.name_label.modulate = Color(0.5, 0.5, 0.5)  # 阵亡置灰
		cell.status_label.text = "阵亡"


func _on_skill_cast(side: StringName, unit_id: StringName, skill_id: StringName, value: int) -> void:
	var unit_name: String = str(_unit_names.get(unit_id, str(unit_id)))
	var skill_name: String = _skill_display_name(unit_id, skill_id)
	var line: String = "「%s」释放 %s" % [unit_name, skill_name]
	if value > 0:
		line += "（%d）" % value
	_add_prompt_line(line, Color(0.8, 0.6, 1.0))


func _on_energy_changed(side: StringName, unit_id: StringName, energy: int) -> void:
	var cell: Dictionary = _cell_for(side, unit_id)
	if cell.is_empty():
		return
	cell.energy_bar.value = float(clampi(energy, 0, Data.ENERGY_MAX))


func _on_status_changed(side: StringName, unit_id: StringName, status_id: StringName, duration: int) -> void:
	# 状态聚合：duration>0 增/刷新，0 移除（显示层聚合，见文件头"状态记录"）
	var statuses: Dictionary = _cell_statuses.get(unit_id, {})
	if duration > 0:
		statuses[status_id] = duration
	else:
		statuses.erase(status_id)
	_cell_statuses[unit_id] = statuses
	var cell: Dictionary = _cell_for(side, unit_id)
	if cell.is_empty():
		return
	var parts: Array = []
	for sid in statuses:
		parts.append("%s%d" % [_status_text(StringName(sid)), int(statuses[sid])])
	cell.status_label.text = " ".join(parts)


func _on_wave_changed(wave: int, total: int) -> void:
	_wave_label.text = "第 %d/%d 波" % [wave, total]
	# 波次切换：只读 Game.battle.enemies 重建敌方棋盘（信号不带布局数据，见文件头说明）
	_place_units(Game.battle.enemies, _enemy_cells, _enemy_cells_by_id, &"enemy")


func _on_battle_prompt(kind: StringName, text: String) -> void:
	_add_prompt_line(text, _prompt_color(kind))


func _on_battle_star(star: int) -> void:
	_star_label.text = _star_text(star)
	_show_battle_stats()
	_status_label.text = "通关！评价 %d 星" % star


func _on_level_cleared(_level: int, _first_clear: bool) -> void:
	_status_label.text = "通关！"
	_show_battle_stats()


func _on_battle_failed(level: int) -> void:
	_retry_level = level
	_status_label.text = "战斗失败！点击重试"
	_retry_button.visible = true
	_show_battle_stats()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_accelerate_toggled(on: bool) -> void:
	Game.toggle_accelerate(on)


func _on_retry_pressed() -> void:
	_reset_battle_ui()
	Game.start_battle(_retry_level)


func _on_back_pressed() -> void:
	Game.stop_battle()
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _reset_battle_ui() -> void:
	_retry_button.visible = false
	_status_label.text = "战斗中…"
	_star_label.text = ""
	_stat_label.text = "伤害统计：—"
	for child in _prompt_box.get_children():
		_prompt_box.remove_child(child)
		child.queue_free()
	_cell_statuses.clear()
	_unit_names.clear()


## ------------------------------------------------------------------
## 棋盘构建 / 摆放（只读 Game.battle 布局）
## ------------------------------------------------------------------
func _build_grid(grid: GridContainer) -> Array:
	var cells: Array = []
	for i in 9:
		var box := PanelContainer.new()
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 2)
		var name_label := Label.new()
		name_label.text = "—"
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var hp_bar := ProgressBar.new()
		hp_bar.name = Contract.TERM_HP_BAR
		hp_bar.max_value = 1.0
		hp_bar.value = 0.0
		hp_bar.show_percentage = false
		var energy_bar := ProgressBar.new()
		energy_bar.name = "energy_bar"
		energy_bar.max_value = float(Data.ENERGY_MAX)
		energy_bar.value = 0.0
		energy_bar.show_percentage = false
		energy_bar.custom_minimum_size = Vector2(0, 6)
		var status_label := Label.new()
		status_label.text = ""
		status_label.add_theme_font_size_override("font_size", 11)
		status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		inner.add_child(name_label)
		inner.add_child(hp_bar)
		inner.add_child(energy_bar)
		inner.add_child(status_label)
		box.add_child(inner)
		box.custom_minimum_size = Vector2(104, 118)
		grid.add_child(box)
		cells.append({
			"box": box, "name_label": name_label, "hp_bar": hp_bar,
			"energy_bar": energy_bar, "status_label": status_label, "max_hp": 1,
		})
	return cells


func _place_units(units: Array, cells: Array, cells_by_id: Dictionary, _side: StringName) -> void:
	_clear_cells(cells, cells_by_id)
	for u in units:
		var id := StringName(u.id)
		var idx: int = int(u.row) * 3 + int(u.col)
		if idx < 0 or idx > 8:
			continue
		var cell: Dictionary = cells[idx]
		cell.max_hp = int(u.max_hp)
		cell.name_label.text = "%s\n%s" % [str(u.name), _class_text(StringName(str(u.class)))]
		cell.name_label.modulate = Color.WHITE
		cell.hp_bar.max_value = float(int(u.max_hp))
		cell.hp_bar.value = float(int(u.hp))
		cell.energy_bar.max_value = float(Data.ENERGY_MAX)
		cell.energy_bar.value = float(int(u.energy))
		cell.status_label.text = ""
		cells_by_id[id] = cell
		_unit_names[id] = str(u.name)


func _clear_cells(cells: Array, cells_by_id: Dictionary) -> void:
	for cell in cells:
		cell.name_label.text = "—"
		cell.name_label.modulate = Color.WHITE
		cell.hp_bar.max_value = 1.0
		cell.hp_bar.value = 0.0
		cell.energy_bar.value = 0.0
		cell.status_label.text = ""
	cells_by_id.clear()
	_cell_statuses.clear()


func _cell_for(side: StringName, unit_id: StringName) -> Dictionary:
	if side == &"mech":
		return _mech_cells_by_id.get(unit_id, {})
	return _enemy_cells_by_id.get(unit_id, {})


## ------------------------------------------------------------------
## 文本工具（静态信息读 Data；动态值只来自信号）
## ------------------------------------------------------------------
func _class_text(class_id: StringName) -> String:
	match class_id:
		&"tank": return "坦克"
		&"fighter": return "战士"
		&"assassin": return "刺客"
		&"archer": return "射手"
		&"mage": return "法师"
		&"support": return "辅助"
	return str(class_id)


func _status_text(status_id: StringName) -> String:
	match status_id:
		&"stun": return "眩晕"
		&"freeze": return "冰冻"
		&"burn": return "灼烧"
		&"poison": return "中毒"
		&"atk": return "加攻"
		&"def": return "减防"
		&"spd": return "变速"
		&"dodge": return "闪避"
		&"damage_reduce": return "减伤"
		&"counter_rate": return "反击"
	return str(status_id)


func _skill_display_name(unit_id: StringName, skill_id: StringName) -> String:
	if Data.ENEMY_SKILLS.has(skill_id):
		return str(Data.ENEMY_SKILLS[skill_id].get("name", str(skill_id)))
	var cfg: Dictionary = Data.MECH_GIRLS.get(unit_id, {})
	var candidates: Array = [cfg.get("passive", {}), cfg.get("ultimate", {})]
	candidates.append_array(cfg.get("skills", []))
	for s in candidates:
		if s is Dictionary and StringName(str(s.get("id", &""))) == skill_id:
			return str(s.get("name", str(skill_id)))
	return str(skill_id)


## 战斗提示分色（契约 §3.9：命中/暴击/闪避/击杀/技能/治疗/护盾）
func _prompt_color(kind: StringName) -> Color:
	match kind:
		&"crit": return Color(1.0, 0.65, 0.25)   # 暴击：橙
		&"dodge": return Color(0.45, 0.75, 1.0)  # 闪避：蓝
		&"kill": return Color(1.0, 0.35, 0.35)   # 击杀：红
		&"skill": return Color(0.85, 0.6, 1.0)   # 技能：紫
		&"heal": return Color(0.4, 1.0, 0.5)     # 治疗：绿
		&"shield": return Color(0.4, 0.9, 0.9)   # 护盾：青
	return Color(0.92, 0.92, 0.92)               # 命中：白


func _add_prompt_line(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.modulate = color
	label.add_theme_font_size_override("font_size", 13)
	_prompt_box.add_child(label)
	_prompt_box.move_child(label, 0)
	while _prompt_box.get_child_count() > 8:
		var last := _prompt_box.get_child(_prompt_box.get_child_count() - 1)
		_prompt_box.remove_child(last)
		last.queue_free()


func _star_text(star: int) -> String:
	var s := ""
	for i in star:
		s += "★"
	for i in (3 - star):
		s += "☆"
	return s


## 简版伤害统计：战斗结束时只读 Game 累计（dmg_dealt / heal_done）
func _show_battle_stats() -> void:
	var total_dmg := 0
	var total_heal := 0
	for m in Game.battle.mechs:
		total_dmg += int(m.dmg_dealt)
		total_heal += int(m.heal_done)
	_stat_label.text = "我方统计：伤害 %d / 治疗 %d" % [total_dmg, total_heal]
