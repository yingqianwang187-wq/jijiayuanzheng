# ==================================================================
# scripts/spin_ui.gd —— 日常转盘界面脚本（挂在 scenes/Spin.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.18（v0.22）、scripts/contract.gd（只读，v0.22 新信号）、
#          scripts/game.gd（B 实际返回字段）
# 职责   ：日常转盘覆盖层的纯显示层 + 转盘入口。
#          - 连接信号：spin_changed(reward) / diamond_changed(value)
#          - 按钮只调入口（契约 §3.6）：转 1 次 → Game.spin_wheel()（B 内部处理每日免费/
#            钻石续转/权重随机/入账）；返回 → queue_free() 关闭覆盖层
#          - 只读入口：Game.get_spin_info()（B 实现返回 {day, free_used, free_limit, cost}）
#            → 按钮文本"免费/续转价"与禁用（免费已用且钻石 < cost 禁用）；
#            奖励表从 Data.SPIN_REWARDS 静态读（type/amount/quality）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 首屏说明：本场景从主界面覆盖层打开，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Spin.tscn 结构一一对应）----
@onready var _diamond_label: Label = $root_box/diamond_label
@onready var _spin_button: Button = $root_box/spin_button
@onready var _result_label: Label = $root_box/result_label
@onready var _reward_box: VBoxContainer = $root_box/reward_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.spin_changed.connect(_on_spin_changed)
	Contract.diamond_changed.connect(_on_diamond_changed)
	_spin_button.pressed.connect(_on_spin_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_diamond_label.text = "钻石：%d" % Game.diamond
	_build_reward_table()
	_refresh_spin_button()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_spin_changed(reward: Dictionary) -> void:
	# 转盘结果展示（入账已走既有货币信号）
	_result_label.text = "获得：%s" % _reward_text(reward)
	_message_label.text = "转盘结果已入账"
	_refresh_spin_button()


func _on_diamond_changed(value: int) -> void:
	_diamond_label.text = "钻石：%d" % value
	_refresh_spin_button()


## ------------------------------------------------------------------
## 转盘按钮状态（每日免费标记 / 续转钻石价；只读 Game.get_spin_info）
## ------------------------------------------------------------------
func _refresh_spin_button() -> void:
	var info: Dictionary = Game.get_spin_info()
	var free_used: bool = bool(info.get("free_used", false))
	var cost: int = int(info.get("cost", Data.SPIN_COST))
	if not free_used:
		_spin_button.text = "转 1 次（免费）"
		_spin_button.disabled = false
	else:
		_spin_button.text = "转 1 次（%d 钻石）" % cost
		_spin_button.disabled = int(Game.diamond) < cost


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_spin_pressed() -> void:
	# 结果由 spin_changed + 货币信号回发；钻石不足 Game 静默失败
	Game.spin_wheel()


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 奖励表预览（Data.SPIN_REWARDS 静态读）
## ------------------------------------------------------------------
func _build_reward_table() -> void:
	for child in _reward_box.get_children():
		_reward_box.remove_child(child)
		child.queue_free()
	for entry in Data.SPIN_REWARDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 12)
		var weight: int = int(entry.get("weight", 1))
		label.text = "%s　　概率 %d%%" % [_reward_text(entry), weight]
		row.add_child(label)
		_reward_box.add_child(row)


## ------------------------------------------------------------------
## 文本工具（Data 静态表，纯展示）
## ------------------------------------------------------------------
## 单条奖励文案（{type, amount, quality?}）
func _reward_text(reward: Dictionary) -> String:
	var amount: int = int(reward.get("amount", 0))
	match str(reward.get("type", "")):
		"gold":
			return "金币 ×%d" % amount
		"diamond":
			return "钻石 ×%d" % amount
		"ticket":
			return "召唤券 ×%d" % amount
		"gem":
			return "%s宝石 ×%d" % [_gem_quality_text(StringName(str(reward.get("quality", "white")))), amount]
	return "%s ×%d" % [str(reward.get("type", "?")), amount]


func _gem_quality_text(quality: StringName) -> String:
	match quality:
		&"white": return "白"
		&"green": return "绿"
		&"blue": return "蓝"
		&"purple": return "紫"
		&"gold": return "金"
		&"red": return "红"
	return str(quality)
