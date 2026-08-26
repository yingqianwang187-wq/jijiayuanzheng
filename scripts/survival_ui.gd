# ==================================================================
# scripts/survival_ui.gd —— 生存模式界面脚本（挂在 scenes/Survival.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.17（v0.21）、scripts/contract.gd（只读，v0.21 新信号）、
#          scripts/game.gd（B 实际返回字段）
# 职责   ：生存模式覆盖层的纯显示层 + 挑战/领奖入口。
#          - 连接信号：survival_changed(day, best_waves)
#          - 按钮只调入口（契约 §3.6）：挑战 → Game.start_survival() + 打开战斗覆盖层
#            Battle.tscn（battle.mode="survival"，无限波次、我方全灭结算）；领奖 →
#            Game.claim_survival_reward()（B 实现：一次领取最高可达且未领档位）；
#            返回 → queue_free() 关闭覆盖层
#          - 只读入口：Game.get_survival_info()（B 实现返回 {day, best_waves, fought,
#            reward_claimed}）；波数档位与奖励从 Data.SURVIVAL_REWARD_TIERS 静态读
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 首屏说明：本场景从主界面覆盖层打开，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Survival.tscn 结构一一对应）----
@onready var _best_label: Label = $root_box/best_label
@onready var _challenge_button: Button = $root_box/challenge_button
@onready var _reward_box: VBoxContainer = $root_box/reward_box
@onready var _claim_button: Button = $root_box/claim_button
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.survival_changed.connect(_on_survival_changed)
	_challenge_button.pressed.connect(_on_challenge_pressed)
	_claim_button.pressed.connect(_on_claim_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_survival_changed(_day: String, _best_waves: int) -> void:
	_refresh_all()


## ------------------------------------------------------------------
## 刷新全部（最佳波数 / 挑战按钮 / 波数档位 / 领奖按钮）
## ------------------------------------------------------------------
func _refresh_all() -> void:
	var info: Dictionary = Game.get_survival_info()
	var best: int = int(info.get("best_waves", 0))
	var claimed: int = int(info.get("reward_claimed", -1))
	var fought: bool = bool(info.get("fought", false))
	_best_label.text = "最佳波数：%d" % best
	if fought:
		_challenge_button.text = "今日已挑战"
		_challenge_button.disabled = true
	else:
		_challenge_button.text = "挑战生存模式"
		_challenge_button.disabled = false
	# 波数档位列表
	var best_tier: int = _best_tier(best)
	for child in _reward_box.get_children():
		_reward_box.remove_child(child)
		child.queue_free()
	var tiers: Array = Data.SURVIVAL_REWARD_TIERS
	for i in tiers.size():
		var tier_cfg: Dictionary = tiers[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 12)
		var state: String = ""
		if i <= claimed:
			state = "  [已领]"
		elif i <= best_tier:
			state = "  [可领]"
		else:
			state = "  [未达成]"
		label.text = "达 %d 波：%s%s" % [int(tier_cfg.get("waves", 0)), _reward_text(tier_cfg.get("reward", [])), state]
		if i > best_tier:
			label.modulate = Color(0.6, 0.6, 0.65)
		row.add_child(label)
		_reward_box.add_child(row)
	# 领奖按钮
	_claim_button.disabled = not (best_tier >= 0 and best_tier > claimed)
	_claim_button.text = "领取当前档位奖励" if not _claim_button.disabled else "暂无可领奖励"


## 波数达标档位（返回最高档 index，-1 = 未达标）
func _best_tier(best_waves: int) -> int:
	var best: int = -1
	var tiers: Array = Data.SURVIVAL_REWARD_TIERS
	for i in tiers.size():
		if best_waves >= int(tiers[i].get("waves", 0)):
			best = i
	return best


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_challenge_pressed() -> void:
	# 结果由 survival_changed 信号回发（战斗按波数结算）
	Game.start_survival()
	var battle_ps: PackedScene = load("res://scenes/Battle.tscn")
	get_tree().root.add_child(battle_ps.instantiate())


func _on_claim_pressed() -> void:
	# 结果由 survival_changed + 货币信号回发
	Game.claim_survival_reward()
	_message_label.text = "已领取波数档位奖励"


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 文本工具（Data 静态表，纯展示）
## ------------------------------------------------------------------
func _reward_text(rewards: Array) -> String:
	if rewards.is_empty():
		return "—"
	var parts: Array = []
	for r in rewards:
		var amount: int = int(r.get("amount", 0))
		match str(r.get("type", "")):
			"gold":
				parts.append("金币×%d" % amount)
			"diamond":
				parts.append("钻石×%d" % amount)
			"ticket":
				parts.append("召唤券×%d" % amount)
			"gem":
				parts.append("%s宝石×%d" % [_gem_quality_text(StringName(str(r.get("quality", "white")))), amount])
			"equip":
				parts.append("装备×%d" % amount)
			_:
				parts.append(str(r.get("type", "?")) + "×%d" % amount)
	return " + ".join(parts)


func _gem_quality_text(quality: StringName) -> String:
	match quality:
		&"white": return "白"
		&"green": return "绿"
		&"blue": return "蓝"
		&"purple": return "紫"
		&"gold": return "金"
		&"red": return "红"
	return str(quality)
