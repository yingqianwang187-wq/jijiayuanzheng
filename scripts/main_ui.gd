# ==================================================================
# scripts/main_ui.gd —— 主界面脚本（挂在 scenes/Main.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6（v0.5）、scripts/contract.gd（只读）
# 职责   ：主界面纯显示层。
#          - 连接信号：gold_changed / mech_girl_updated / mech_exp_updated /
#            level_cleared / level_progress_changed / idle_rewards_updated
#          - 按钮只调入口（契约 §3.6）：升级 → Game.upgrade(id)；
#            收获 → Game.collect_idle()；进入战斗 → Game.start_battle(level) + 切到 Battle.tscn；
#            手动存档 → Save.save_game()
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 首屏说明：本场景会从战斗场景切回（启动时那批初始信号已错过，Game 不重发），
#          故 _ready 对 Game 公开状态做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），
#          此后一切更新一律走信号。
# 机娘显示：主界面无战斗概念，机娘始终按满血显示；等级 / 攻击以信号参数为准，
#          满血值由 Data 静态表按等级换算（与 Game._mech_stats 同一公式、同一数据源）。
# 经验显示：exp / exp_next 以 mech_exp_updated 信号参数为准；首屏快照时 exp 读
#          Game.mech_exp，exp_next 用只读入口 Game.upgrade_exp_cost(id)（契约 §3.6 v0.5）。
# 升级禁用：v0.5 起用只读入口 Game.upgrade_cost(id) / Game.upgrade_exp_cost(id) 判断
#          金币/经验是否足够（不再自行换算费用），不足时按钮置灰并在 message_label 提示原因；
#          在 gold_changed / mech_exp_updated / mech_girl_updated 信号到达时刷新全部按钮。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Main.tscn 结构一一对应）----
@onready var _gold_label: Label = $root_box/gold_label
@onready var _idle_rewards_label: Label = $root_box/idle_row/idle_rewards_label
@onready var _collect_button: Button = $root_box/idle_row/collect_button
@onready var _level_box: HBoxContainer = $root_box/level_box
@onready var _mech_box: VBoxContainer = $root_box/mech_box
@onready var _last_clear_label: Label = $root_box/last_clear_label
@onready var _message_label: Label = $root_box/message_label
@onready var _enter_battle_button: Button = $root_box/bottom_row/enter_battle_button
@onready var _save_button: Button = $root_box/bottom_row/save_button

## ---- UI 内部状态（仅关卡选择与行引用，不含任何游戏数值）----
var _selected_level: int = 1
var _unlocked_level: int = 1
var _level_buttons: Dictionary = {}  # int -> Button
var _mech_rows: Dictionary = {}      # StringName -> { stats_label, exp_label, upgrade_button }


func _ready() -> void:
	Contract.gold_changed.connect(_on_gold_changed)
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
	Contract.mech_exp_updated.connect(_on_mech_exp_updated)
	Contract.level_cleared.connect(_on_level_cleared)
	Contract.level_progress_changed.connect(_on_level_progress_changed)
	Contract.idle_rewards_updated.connect(_on_idle_rewards_updated)
	_collect_button.pressed.connect(_on_collect_pressed)
	_enter_battle_button.pressed.connect(_on_enter_battle_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_build_level_buttons()
	_build_mech_rows()
	_seed_initial_state()


## ------------------------------------------------------------------
## 信号处理（只刷新显示；gold/经验/机娘 信号同时刷新升级按钮状态）
## ------------------------------------------------------------------
func _on_gold_changed(value: int) -> void:
	_gold_label.text = "金币：%d" % value
	_refresh_upgrade_buttons()


func _on_idle_rewards_updated(amount: int) -> void:
	_idle_rewards_label.text = "待收获：%d 金币" % amount


func _on_mech_girl_updated(id: StringName, _hp: int, atk: int, level: int) -> void:
	# 主界面无战斗概念，机娘始终按满血显示；等级 / 攻击以信号为准（见文件头说明）
	_render_mech_row(id, level, atk)
	_refresh_upgrade_buttons()


func _on_mech_exp_updated(id: StringName, exp: int, exp_next: int) -> void:
	_render_mech_exp(id, exp, exp_next)
	_refresh_upgrade_buttons()


func _on_level_cleared(level: int, first_clear: bool) -> void:
	if first_clear:
		var reward: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward", 0))
		_message_label.text = "第 %d 关首通！获得 %d 金币" % [level, reward]
	else:
		_message_label.text = "第 %d 关已通关" % level


func _on_level_progress_changed(level: int) -> void:
	_unlocked_level = clampi(level, 1, Data.MAX_LEVEL)
	if _selected_level < _unlocked_level:
		_selected_level = _unlocked_level  # 新关解锁后自动选中，方便连续推关
	_refresh_level_buttons()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_collect_pressed() -> void:
	# 结果由 gold_changed / idle_rewards_updated 信号回发，不依赖返回值
	Game.collect_idle()


func _on_enter_battle_pressed() -> void:
	var level: int = _selected_level
	if level < 1 or level > _unlocked_level:
		_message_label.text = "该关卡尚未解锁"
		return
	Game.start_battle(level)
	get_tree().change_scene_to_file("res://scenes/Battle.tscn")


func _on_save_pressed() -> void:
	Save.save_game()
	_message_label.text = "已保存"


## ------------------------------------------------------------------
## 关卡选择（数量与锁定状态来自 Data / Game 信号）
## ------------------------------------------------------------------
func _build_level_buttons() -> void:
	for level in range(1, Data.MAX_LEVEL + 1):
		var btn := Button.new()
		btn.text = "第 %d 关" % level
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_level_button_pressed.bind(level))
		_level_box.add_child(btn)
		_level_buttons[level] = btn


func _on_level_button_pressed(level: int) -> void:
	_selected_level = level
	_refresh_level_buttons()


func _refresh_level_buttons() -> void:
	for level in _level_buttons:
		var btn: Button = _level_buttons[level]
		var locked: bool = level > _unlocked_level
		btn.disabled = locked
		btn.button_pressed = (level == _selected_level) and not locked
		if locked:
			btn.text = "第 %d 关（未解锁）" % level
		else:
			btn.text = "第 %d 关" % level


## ------------------------------------------------------------------
## 机娘列表（名单来自 Data.MECH_GIRLS，动态创建，不硬编码）
## 一行 = 名字 + 状态（Lv/攻/血）+ 经验（exp/exp_next）+ 升级按钮
## ------------------------------------------------------------------
func _build_mech_rows() -> void:
	for id in Data.MECH_GIRLS:
		var cfg: Dictionary = Data.MECH_GIRLS[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_label := Label.new()
		name_label.text = "%s（%s）" % [str(cfg.get("name", str(id))), str(cfg.get("role", ""))]
		name_label.custom_minimum_size = Vector2(150, 0)
		var stats_label := Label.new()
		stats_label.text = "Lv.- 攻- 血 -/-"
		stats_label.custom_minimum_size = Vector2(210, 0)
		var exp_label := Label.new()
		exp_label.text = "经验 -/-"
		exp_label.custom_minimum_size = Vector2(140, 0)
		var upgrade_button := Button.new()
		upgrade_button.text = "升级"
		upgrade_button.pressed.connect(_on_upgrade_pressed.bind(id))
		row.add_child(name_label)
		row.add_child(stats_label)
		row.add_child(exp_label)
		row.add_child(upgrade_button)
		_mech_box.add_child(row)
		_mech_rows[id] = { "stats_label": stats_label, "exp_label": exp_label, "upgrade_button": upgrade_button }


func _on_upgrade_pressed(mech_id: StringName) -> void:
	# 结果由 gold_changed / mech_girl_updated / mech_exp_updated 信号回发，不依赖返回值
	Game.upgrade(mech_id)


## 渲染一行机娘：等级 / 攻击来自信号（或首屏快照换算），满血值由 Data 静态表换算
func _render_mech_row(id: StringName, level: int, atk: int) -> void:
	var row: Dictionary = _mech_rows.get(id, {})
	if row.is_empty():
		return
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var max_hp: int = int(cfg.get("base_hp", 0)) + (level - 1) * int(cfg.get("growth", {}).get("hp", 0))
	row.stats_label.text = "Lv.%d 攻%d 血 %d/%d" % [level, atk, max_hp, max_hp]


## 渲染一行机娘经验：exp / exp_next 以信号参数为准（v0.4）
func _render_mech_exp(id: StringName, exp: int, exp_next: int) -> void:
	var row: Dictionary = _mech_rows.get(id, {})
	if row.is_empty():
		return
	row.exp_label.text = "经验 %d/%d" % [exp, exp_next]


## ------------------------------------------------------------------
## 升级按钮状态（契约 §3.6 v0.5）：用只读入口判断金币/经验是否足够，
## 不足则置灰并在 message_label 提示原因；够则恢复可用并清空原因提示。
## 判断所需当前金币/经验只读 Game 公开状态（不修改任何数值）。
## ------------------------------------------------------------------
func _refresh_upgrade_buttons() -> void:
	var gold_now: int = int(Game.gold)
	var first_reason: String = ""
	var any_disabled := false
	for id in _mech_rows:
		var row: Dictionary = _mech_rows[id]
		var gold_cost: int = Game.upgrade_cost(id)
		var exp_cost: int = Game.upgrade_exp_cost(id)
		var exp_now: int = int(Game.mech_exp.get(id, 0))
		var lack_gold: bool = gold_now < gold_cost
		var lack_exp: bool = exp_now < exp_cost
		row.upgrade_button.disabled = lack_gold or lack_exp
		if lack_gold or lack_exp:
			any_disabled = true
			if first_reason.is_empty():
				if lack_gold and lack_exp:
					first_reason = "金币和经验都不足，无法升级"
				elif lack_gold:
					first_reason = "金币不足，无法升级"
				else:
					first_reason = "经验不足，无法升级"
	if any_disabled:
		_message_label.text = first_reason
	else:
		_message_label.text = ""


## ------------------------------------------------------------------
## 首屏只读快照（契约 §3.1"首屏铺底例外"，见文件头"首屏说明"）：
## 金币 / 待收获 / 解锁进度 / 机娘等级与经验 / 上次通关消息均来自 Game 公开状态
## ------------------------------------------------------------------
func _seed_initial_state() -> void:
	_unlocked_level = clampi(int(Game.unlocked_level), 1, Data.MAX_LEVEL)
	_selected_level = _unlocked_level
	_gold_label.text = "金币：%d" % Game.gold
	_idle_rewards_label.text = "待收获：%d 金币" % roundi(Game.idle_pending)
	for id in _mech_rows:
		var level: int = int(Game.mech_levels.get(id, 1))
		var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
		var atk: int = int(cfg.get("base_atk", 0)) + (level - 1) * int(cfg.get("growth", {}).get("atk", 0))
		_render_mech_row(id, level, atk)
		var exp: int = int(Game.mech_exp.get(id, 0))
		_render_mech_exp(id, exp, Game.upgrade_exp_cost(id))
	_refresh_level_buttons()
	_refresh_upgrade_buttons()
	# 上次通关消息（v0.5：Game.last_clear 内存态、不入档；战斗胜利返回后重入显示）。
	# 展示在独立标签 last_clear_label，不占用 message_label（后者留给即时提示）。
	# 文案：仅首通显示"奖励 +X 金币"；重复通关无金币奖励，不显示奖励部分。
	if not Game.last_clear.is_empty():
		var lc: Dictionary = Game.last_clear
		if bool(lc.get("first_clear", false)):
			_last_clear_label.text = "上次通关：第 %d 关（首通）奖励 +%d 金币" % [int(lc.get("level", 0)), int(lc.get("reward", 0))]
		else:
			_last_clear_label.text = "上次通关：第 %d 关（重复通关）" % int(lc.get("level", 0))
