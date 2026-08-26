# ==================================================================
# scripts/task_ui.gd —— 任务界面脚本（挂在 scenes/Task.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.13（v0.16）、scripts/contract.gd（只读）
# 职责   ：任务界面的纯显示层 + 领奖入口（每日 / 每周页签）。
#          - 连接信号：task_changed（日/周进度与已领变化后刷新）
#          - 按钮只调入口（契约 §3.6）：领档位奖励 → Game.claim_task_reward(scope, tier)；
#            返回 → 切回 Main.tscn
#          - 只读入口：Game.get_task_info()（{daily: {progress, claimed}, weekly: {...}}）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 活跃度 ：达标任务的活跃度之和（Data 任务表 target/active + 只读 progress 计算，
#          与 Game._task_active 同一公式、同一数据源）；档位达标可领（高亮），已领置灰。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Task.tscn 结构一一对应）----
@onready var _daily_tab: Button = $root_box/tab_row/daily_tab
@onready var _weekly_tab: Button = $root_box/tab_row/weekly_tab
@onready var _active_label: Label = $root_box/active_label
@onready var _task_box: VBoxContainer = $root_box/task_box
@onready var _tier_box: VBoxContainer = $root_box/tier_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button

## 当前页签（"daily" / "weekly"）
var _scope: String = "daily"


func _ready() -> void:
	Contract.task_changed.connect(_on_task_changed)
	_daily_tab.pressed.connect(_on_tab_pressed.bind("daily"))
	_weekly_tab.pressed.connect(_on_tab_pressed.bind("weekly"))
	_back_button.pressed.connect(_on_back_pressed)
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_task_changed(_daily: Dictionary, _weekly: Dictionary) -> void:
	_refresh_all()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_tab_pressed(scope: String) -> void:
	_scope = scope
	_daily_tab.button_pressed = (scope == "daily")
	_weekly_tab.button_pressed = (scope == "weekly")
	_refresh_all()


func _on_claim_pressed(scope: String, tier: int) -> void:
	Game.claim_task_reward(scope, tier)  # 结果由 task_changed / 货币信号回发


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 渲染
## ------------------------------------------------------------------
func _refresh_all() -> void:
	var info: Dictionary = Game.get_task_info()
	var store: Dictionary = info.get(_scope, {})
	var tasks: Dictionary = Data.DAILY_TASKS if _scope == "daily" else Data.WEEKLY_TASKS
	var tiers: Dictionary = Data.DAILY_TASK_TIERS if _scope == "daily" else Data.WEEKLY_TASK_TIERS
	var active := _active(store, tasks)
	var scope_name: String = "每日" if _scope == "daily" else "每周"
	# 页签高亮
	_daily_tab.button_pressed = (_scope == "daily")
	_weekly_tab.button_pressed = (_scope == "weekly")
	# 活跃度
	var tier_keys: Array = tiers.keys()
	tier_keys.sort()
	var max_tier: int = int(tier_keys[tier_keys.size() - 1]) if not tier_keys.is_empty() else 0
	_active_label.text = "%s活跃度：%d/%d" % [scope_name, active, max_tier]
	# 任务列表
	for child in _task_box.get_children():
		_task_box.remove_child(child)
		child.queue_free()
	for task_id in tasks:
		var cfg: Dictionary = tasks[task_id]
		var progress: int = int(store.get("progress", {}).get(str(task_id), 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_label := Label.new()
		name_label.text = str(cfg.get("name", str(task_id)))
		name_label.custom_minimum_size = Vector2(200, 0)
		var progress_label := Label.new()
		progress_label.text = "%d/%d" % [progress, int(cfg.get("target", 0))]
		progress_label.custom_minimum_size = Vector2(80, 0)
		var active_label := Label.new()
		active_label.text = "+%d 活跃度" % int(cfg.get("active", 0))
		row.add_child(name_label)
		row.add_child(progress_label)
		row.add_child(active_label)
		_task_box.add_child(row)
	# 档位奖励行
	for child in _tier_box.get_children():
		_tier_box.remove_child(child)
		child.queue_free()
	var claimed: Array = store.get("claimed", [])
	for tier in tier_keys:
		var reached: bool = active >= int(tier)
		var is_claimed: bool = claimed.has(int(tier))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.text = "活跃度 %d：%s" % [int(tier), _rewards_text(tiers[tier])]
		label.custom_minimum_size = Vector2(380, 0)
		var btn := Button.new()
		if is_claimed:
			btn.text = "已领"
			btn.disabled = true
		elif reached:
			btn.text = "领取"
			btn.modulate = Color(1.0, 0.9, 0.4)  # 达标可领高亮
			btn.pressed.connect(_on_claim_pressed.bind(_scope, int(tier)))
		else:
			btn.text = "未达标"
			btn.disabled = true
		row.add_child(label)
		row.add_child(btn)
		_tier_box.add_child(row)


## 活跃度：达标任务活跃度之和（与 Game._task_active 同一公式、同一数据源）
func _active(store: Dictionary, tasks: Dictionary) -> int:
	var total := 0
	for task_id in tasks:
		if int(store.get("progress", {}).get(str(task_id), 0)) >= int(tasks[task_id].get("target", 0)):
			total += int(tasks[task_id].get("active", 0))
	return total


## 档位奖励文本（{type, amount, quality?} 列表 → "金币500 钻石20"）
func _rewards_text(rewards: Array) -> String:
	var parts: Array = []
	for r in rewards:
		var type: String = str(r.get("type", ""))
		var amount: int = int(r.get("amount", 0))
		match type:
			"gold": parts.append("金币%d" % amount)
			"diamond": parts.append("钻石%d" % amount)
			"ticket": parts.append("召唤券%d" % amount)
			"gem": parts.append("宝石(%s)%d" % [str(r.get("quality", "white")), amount])
			"equip": parts.append("装备%d" % amount)
			_: parts.append("%s%d" % [type, amount])
	return " ".join(parts) if not parts.is_empty() else "—"
