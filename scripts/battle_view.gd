# ==================================================================
# scripts/battle_view.gd —— 战斗画面脚本（挂在 scenes/Battle.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.4 / §3.5 / §3.6（v0.5）、scripts/contract.gd（只读）
# 职责   ：战斗画面的纯显示层。契约 §3.4：连接信号 → 刷新血条 → 播放表现。
#          - 连接信号：battle_tick / mech_girl_updated / enemy_updated / battle_failed
#          - 按钮只调入口（契约 §3.6）：开始 / 重试 → Game.start_battle(level)；
#            返回 → Game.stop_battle()（v0.5：返回 = 中止本局战斗）后切回 Main.tscn
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          无物理碰撞 / 位移运算、不自己扣血；一切更新值以 Game 信号参数为准。
# 首屏说明：战斗由主界面"进入战斗"先调 Game.start_battle(level)、再切换场景而来，
#          初始状态信号在场景切换前已发出、本场景收不到；故 _ready 对 Game.battle
#          做一次【只读快照】铺首屏，此后一切更新一律走信号。
#          （若总指挥要求严格信号驱动，需契约新增"战斗状态重发"入口——变更申请。）
# 血条说明：满血上限来自首屏快照（战斗内血量只降不升，快照值即上限）；
#          当前血量一律来自 enemy_updated / mech_girl_updated 信号参数。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Battle.tscn 结构一一对应）----
@onready var _title_label: Label = $root_box/title_label
@onready var _tick_label: Label = $root_box/tick_label
@onready var _my_side_box: VBoxContainer = $root_box/my_side_box
@onready var _enemy_side_box: VBoxContainer = $root_box/enemy_side_box
@onready var _status_label: Label = $root_box/status_label
@onready var _start_button: Button = $root_box/button_row/start_button
@onready var _retry_button: Button = $root_box/button_row/retry_button
@onready var _back_button: Button = $root_box/button_row/back_button

## ---- 显示层内部状态（只存"已建的行"与"满血上限"，不存任何可变游戏数值）----
var _mech_rows: Dictionary = {}    # StringName -> { container, name_label, hp_bar, stats_label }
var _enemy_rows: Dictionary = {}   # StringName -> { container, name_label, hp_bar, stats_label }
var _mech_max_hp: Dictionary = {}  # StringName -> int（满血上限，首屏快照/首个信号）
var _enemy_max_hp: Dictionary = {} # StringName -> int（满血上限，首屏快照/首个信号）
var _battle_level: int = 1
var _retry_level: int = 1


func _ready() -> void:
	Contract.battle_tick.connect(_on_battle_tick)
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
	Contract.enemy_updated.connect(_on_enemy_updated)
	Contract.battle_failed.connect(_on_battle_failed)
	_start_button.pressed.connect(_on_start_pressed)
	_retry_button.pressed.connect(_on_retry_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	_retry_button.visible = false
	_seed_initial_state()


## 首屏只读快照（见文件头"首屏说明"）：只读 Game 公开战斗状态铺首屏，
## 之后所有更新一律以信号参数为准。
func _seed_initial_state() -> void:
	if not Game.battle.active:
		_status_label.text = "未在战斗中，请点击开始战斗"
		return
	_battle_level = int(Game.battle.level)
	_title_label.text = "第 %d 关 · 战斗" % _battle_level
	for m in Game.battle.mechs:
		var id := StringName(m.id)
		_ensure_mech_row(id)
		_mech_max_hp[id] = int(m.hp)
		_apply_mech_display(id, int(m.hp), int(m.atk), int(m.level))
	for e in Game.battle.enemies:
		var id := StringName(e.id)
		_ensure_enemy_row(id)
		_enemy_max_hp[id] = int(e.hp)
		_apply_enemy_display(id, int(e.hp))


## ------------------------------------------------------------------
## 信号处理（只刷新显示，不产生 / 不修改任何游戏数值）
## ------------------------------------------------------------------
func _on_battle_tick(tick: int) -> void:
	_tick_label.text = "第 %d 轮" % tick


func _on_mech_girl_updated(id: StringName, hp: int, atk: int, level: int) -> void:
	_ensure_mech_row(id)
	if not _mech_max_hp.has(id):
		_mech_max_hp[id] = hp  # 兜底：未快照时首个信号即满血（正常流程不会走到）
	_apply_mech_display(id, hp, atk, level)


func _on_enemy_updated(id: StringName, hp: int) -> void:
	_ensure_enemy_row(id)
	if not _enemy_max_hp.has(id):
		_enemy_max_hp[id] = hp  # 兜底同上
	_apply_enemy_display(id, hp)
	if hp <= 0:
		_status_label.text = "战斗胜利！"


func _on_battle_failed(level: int) -> void:
	_retry_level = level
	_status_label.text = "战斗失败！点击重试"
	_retry_button.visible = true


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_start_pressed() -> void:
	# 开始 / 重新开始当前关卡
	_reset_battle_ui()
	Game.start_battle(_battle_level)


func _on_retry_pressed() -> void:
	_reset_battle_ui()
	Game.start_battle(_retry_level)


func _on_back_pressed() -> void:
	# 契约 §3.6 v0.5：返回 = 中止本局战斗（战斗不再后台推进），再切回主界面
	Game.stop_battle()
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _reset_battle_ui() -> void:
	_retry_button.visible = false
	_status_label.text = "战斗中…"


## ------------------------------------------------------------------
## 显示行构建（静态信息读 Data；动态值只来自信号）
## ------------------------------------------------------------------
func _ensure_mech_row(id: StringName) -> void:
	if _mech_rows.has(id):
		return
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var row := _make_row()
	row.container.add_to_group(Contract.TERM_MECH_GIRL)  # 组名 mech_girl（契约 §2.3 / §⑤）
	row.name_label.text = "%s（%s）" % [str(cfg.get("name", str(id))), str(cfg.get("role", ""))]
	_my_side_box.add_child(row.container)
	_mech_rows[id] = row


func _ensure_enemy_row(id: StringName) -> void:
	if _enemy_rows.has(id):
		return
	var row := _make_row()
	row.container.add_to_group(&"enemy")  # 组名 enemy（契约 §2.3；术语表暂无 TERM_ENEMY 常量）
	row.name_label.text = _enemy_display_name(id)
	_enemy_side_box.add_child(row.container)
	_enemy_rows[id] = row


## 敌人显示名：从 Data.LEVELS 数值表按 id 查（契约 §3.3：名称属 Data）
func _enemy_display_name(id: StringName) -> String:
	for level in Data.LEVELS:
		for e in Data.LEVELS[level].enemies:
			if StringName(e.id) == id:
				return str(e.get("name", str(id)))
	return str(id)


## 一行 = 名字 + 血条（节点名 hp_bar，契约 §⑤）+ 数值文本
func _make_row() -> Dictionary:
	var container := HBoxContainer.new()
	container.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.custom_minimum_size = Vector2(150, 0)
	var hp_bar := ProgressBar.new()
	hp_bar.name = Contract.TERM_HP_BAR
	hp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp_bar.max_value = 1.0
	hp_bar.value = 0.0
	hp_bar.show_percentage = false
	var stats_label := Label.new()
	stats_label.custom_minimum_size = Vector2(180, 0)
	container.add_child(name_label)
	container.add_child(hp_bar)
	container.add_child(stats_label)
	return { "container": container, "name_label": name_label, "hp_bar": hp_bar, "stats_label": stats_label }


func _apply_mech_display(id: StringName, hp: int, atk: int, level: int) -> void:
	var row: Dictionary = _mech_rows.get(id, {})
	if row.is_empty():
		return
	var max_hp: int = int(_mech_max_hp.get(id, hp))
	row.hp_bar.max_value = float(max_hp)
	row.hp_bar.value = float(clampi(hp, 0, max_hp))
	# 文本显示钳到 >= 0（溢出伤害时信号 hp 可能为负；仅显示处理，不改数值）
	row.stats_label.text = "Lv.%d 攻%d 血 %d/%d" % [level, atk, maxi(hp, 0), max_hp]


func _apply_enemy_display(id: StringName, hp: int) -> void:
	var row: Dictionary = _enemy_rows.get(id, {})
	if row.is_empty():
		return
	var max_hp: int = int(_enemy_max_hp.get(id, hp))
	row.hp_bar.max_value = float(max_hp)
	row.hp_bar.value = float(clampi(hp, 0, max_hp))
	# 文本显示钳到 >= 0（同上）
	row.stats_label.text = "血 %d/%d" % [maxi(hp, 0), max_hp]
