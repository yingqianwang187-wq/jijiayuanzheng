# ==================================================================
# scripts/tower_ui.gd —— 爬塔界面脚本（挂在 scenes/Tower.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.13（v0.16）、scripts/contract.gd（只读）
# 职责   ：爬塔界面的纯显示层 + 挑战入口。
#          - 连接信号：tower_changed（通关推进 / 每日层数变化后刷新）
#          - 按钮只调入口（契约 §3.6）：挑战 → Game.start_tower() 后切 Battle.tscn；
#            返回 → 切回 Main.tscn
#          - 只读入口：Game.get_tower_info()（{highest, daily_count, daily_limit}）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 说明   ：当前挑战层 = 最高层 + 1；每日 30 层上限（Data.TOWER_DAILY_LIMIT）达上限时
#          挑战禁用并提示（start_tower 校验静默返回，UI 前置判断）。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Tower.tscn 结构一一对应）----
@onready var _info_label: Label = $root_box/info_label
@onready var _challenge_button: Button = $root_box/challenge_button
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.tower_changed.connect(_on_tower_changed)
	_challenge_button.pressed.connect(_on_challenge_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）
	_refresh(Game.get_tower_info())


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_tower_changed(level: int, daily_count: int) -> void:
	_refresh({ "highest": level, "daily_count": daily_count, "daily_limit": Data.TOWER_DAILY_LIMIT })


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_challenge_pressed() -> void:
	var info: Dictionary = Game.get_tower_info()
	if int(info.get("daily_count", 0)) >= int(info.get("daily_limit", Data.TOWER_DAILY_LIMIT)):
		_message_label.text = "今日爬塔已达上限"
		return
	Game.start_tower()
	var battle_ps: PackedScene = load("res://scenes/Battle.tscn")
	get_tree().root.add_child(battle_ps.instantiate())


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 渲染（信息来自只读入口或信号参数）
## ------------------------------------------------------------------
func _refresh(info: Dictionary) -> void:
	var highest: int = int(info.get("highest", 0))
	var daily: int = int(info.get("daily_count", 0))
	var limit: int = int(info.get("daily_limit", Data.TOWER_DAILY_LIMIT))
	_info_label.text = "当前挑战层：第 %d 层\n今日已爬：%d/%d\n每 10 层大奖：钻石 + 召唤券（第 20 层起附赠宝石）" % [highest + 1, daily, limit]
	_challenge_button.text = "挑战第 %d 层" % (highest + 1)
	_challenge_button.disabled = daily >= limit
