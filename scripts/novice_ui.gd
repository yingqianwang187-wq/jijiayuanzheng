# ==================================================================
# scripts/novice_ui.gd —— 新手福利界面脚本（挂在 scenes/Novice.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.13（v0.16）、scripts/contract.gd（只读）
# 职责   ：新手 7 日任务界面的纯显示层 + 领奖入口。
#          - 连接信号：novice_changed（进度/已领变化后刷新）
#          - 按钮只调入口（契约 §3.6）：领第 N 天奖励 → Game.claim_novice_reward(day)；
#            返回 → 切回 Main.tscn
#          - 只读入口：Game.get_novice_info()（{day, progress, claimed}）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 列表   ：Data.NOVICE_TASKS（7 天，每天 2 目标 + 奖励）驱动；当天全部达标且未领 → 可领高亮。
# ==================================================================
extends Control

## 新手任务 id → 中文名（Data.NOVICE_TASKS 目标 id）
const _TASK_NAMES := {
	"upgrade_count": "升级机娘",
	"story_count": "通关主线",
	"summon_count": "抽卡",
	"power": "上阵战力达标",
	"tower_count": "爬塔",
	"dungeon_count": "挑战秘境",
	"enchant_count": "强化装备",
}

## ---- 节点引用（与 scenes/Novice.tscn 结构一一对应）----
@onready var _day_label: Label = $root_box/day_label
@onready var _list_box: VBoxContainer = $root_box/list_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.novice_changed.connect(_on_novice_changed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_novice_changed(_day: int, _progress: Dictionary, _claimed: Array) -> void:
	_refresh_all()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_claim_pressed(day: int) -> void:
	Game.claim_novice_reward(day)  # 结果由 novice_changed / 货币信号回发


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


## ------------------------------------------------------------------
## 渲染
## ------------------------------------------------------------------
func _refresh_all() -> void:
	var info: Dictionary = Game.get_novice_info()
	var progress: Dictionary = info.get("progress", {})
	var claimed: Array = info.get("claimed", [])
	var current_day: int = int(info.get("day", 1))
	if current_day > 7:
		_day_label.text = "新手福利 · 全部完成！"
	else:
		_day_label.text = "新手福利 · 当前进度：第 %d 天（共 7 天）" % current_day
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	for day in range(1, 8):
		var cfg: Dictionary = Data.NOVICE_TASKS.get(day, {})
		var is_claimed: bool = claimed.has(day)
		var done: bool = true
		for t in cfg.get("tasks", []):
			if int(progress.get(str(day), {}).get(str(t.id), 0)) < int(t.get("target", 0)):
				done = false
		var section := VBoxContainer.new()
		section.add_theme_constant_override("separation", 2)
		var title := Label.new()
		title.text = "第 %d 天%s" % [day, "（已领）" if is_claimed else ""]
		section.add_child(title)
		for t in cfg.get("tasks", []):
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			var name_label := Label.new()
			name_label.text = "  %s" % str(_TASK_NAMES.get(str(t.id), str(t.id)))
			name_label.custom_minimum_size = Vector2(160, 0)
			var progress_label := Label.new()
			progress_label.text = "%d/%d" % [int(progress.get(str(day), {}).get(str(t.id), 0)), int(t.get("target", 0))]
			row.add_child(name_label)
			row.add_child(progress_label)
			section.add_child(row)
		var reward_row := HBoxContainer.new()
		reward_row.add_theme_constant_override("separation", 8)
		var reward_label := Label.new()
		reward_label.text = "  奖励：%s" % _rewards_text(cfg.get("reward", []))
		reward_label.custom_minimum_size = Vector2(320, 0)
		var btn := Button.new()
		if is_claimed:
			btn.text = "已领"
			btn.disabled = true
		elif done:
			btn.text = "领取"
			btn.modulate = Color(1.0, 0.9, 0.4)  # 达标可领高亮
			btn.pressed.connect(_on_claim_pressed.bind(day))
		else:
			btn.text = "未完成"
			btn.disabled = true
		reward_row.add_child(reward_label)
		reward_row.add_child(btn)
		section.add_child(reward_row)
		_list_box.add_child(section)


## 奖励文本（{type, amount, quality?} 列表 → "金币500 钻石20"）
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
			_: parts.append("%s%d" % [type, amount])
	return " ".join(parts) if not parts.is_empty() else "—"
