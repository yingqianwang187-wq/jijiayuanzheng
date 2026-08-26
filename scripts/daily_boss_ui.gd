# ==================================================================
# scripts/daily_boss_ui.gd —— 每日BOSS 界面脚本（挂在 scenes/DailyBoss.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.16（v0.20）、scripts/contract.gd（只读，v0.20 新信号）、
#          scripts/game.gd（B 实际返回字段）
# 职责   ：每日BOSS 覆盖层的纯显示层 + 挑战/领奖入口。
#          - 连接信号：daily_boss_changed(damage, day)
#          - 按钮只调入口（契约 §3.6）：挑战 → Game.start_daily_boss() + 打开战斗覆盖层
#            Battle.tscn（battle.mode="boss"，伤害结算）；领奖 → Game.claim_daily_boss_reward()
#            （B 实现：一次领取最高可达且未领的档位）；返回 → queue_free() 关闭覆盖层
#          - 只读入口：Game.get_daily_boss_info()（B 实现返回 {day, damage, reward_claimed,
#            today_done}）；Game.get_rank_info()（{boss_damage} 本地伤害榜）；今日 BOSS 名/
#            档位门槛与奖励从 Data.DAILY_BOSSES / DAILY_BOSS_REWARD_TIERS 静态读
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 首屏说明：本场景从主界面覆盖层打开，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/DailyBoss.tscn 结构一一对应）----
@onready var _boss_name_label: Label = $root_box/boss_name_label
@onready var _damage_label: Label = $root_box/damage_label
@onready var _challenge_button: Button = $root_box/challenge_button
@onready var _reward_box: VBoxContainer = $root_box/reward_box
@onready var _claim_button: Button = $root_box/claim_button
@onready var _rank_label: Label = $root_box/rank_label
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.daily_boss_changed.connect(_on_daily_boss_changed)
	_challenge_button.pressed.connect(_on_challenge_pressed)
	_claim_button.pressed.connect(_on_claim_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_daily_boss_changed(_damage: int, _day: String) -> void:
	_refresh_all()


## ------------------------------------------------------------------
## 刷新全部显示（BOSS 名/伤害/挑战按钮/档位/伤害榜/领奖按钮）
## ------------------------------------------------------------------
func _refresh_all() -> void:
	var info: Dictionary = Game.get_daily_boss_info()
	var damage: int = int(info.get("damage", 0))
	var claimed: int = int(info.get("reward_claimed", -1))
	var today_done: bool = bool(info.get("today_done", false))
	# 今日 BOSS（Data.DAILY_BOSSES 按星期几轮换）
	var weekday: int = int(Time.get_date_dict_from_system()["weekday"])
	var boss_cfg: Dictionary = Data.DAILY_BOSSES[weekday]
	_boss_name_label.text = "今日BOSS：%s" % str(boss_cfg.get("name", "?"))
	_damage_label.text = "今日最高伤害：%s" % _format_num(damage)
	if today_done:
		_challenge_button.text = "今日已挑战"
		_challenge_button.disabled = true
	else:
		_challenge_button.text = "挑战今日BOSS"
		_challenge_button.disabled = false
	# 伤害档位列表
	_build_rewards(damage, claimed)
	# 领奖按钮：伤害达到最低档且未领最高可达档
	var best_tier: int = _best_tier(damage)
	_claim_button.disabled = not (best_tier >= 0 and best_tier > claimed)
	_claim_button.text = "领取当前档位奖励" if _claim_button.disabled == false else "暂无可领奖励"
	# 本地伤害榜（get_rank_info 的 boss 榜）
	var rank: Dictionary = Game.get_rank_info()
	_rank_label.text = "本地伤害榜：最高 %s" % _format_num(int(rank.get("boss_damage", 0)))


## 伤害达标档位（返回最高档 index，-1 = 未达标）
func _best_tier(damage: int) -> int:
	var best: int = -1
	var tiers: Array = Data.DAILY_BOSS_REWARD_TIERS
	for i in tiers.size():
		if damage >= int(tiers[i].get("damage", 0)):
			best = i
	return best


## 伤害档位列表（门槛 + 奖励 + 状态）
func _build_rewards(damage: int, claimed: int) -> void:
	for child in _reward_box.get_children():
		_reward_box.remove_child(child)
		child.queue_free()
	var tiers: Array = Data.DAILY_BOSS_REWARD_TIERS
	var best_tier: int = _best_tier(damage)
	for i in tiers.size():
		var tier_cfg: Dictionary = tiers[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var info := Label.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_font_size_override("font_size", 13)
		var state: String = ""
		if i <= claimed:
			state = "  [已领]"
		elif i <= best_tier:
			state = "  [可领]"
		else:
			state = "  [未达成]"
		info.text = "伤害 ≥ %s：%s%s" % [_format_num(int(tier_cfg.get("damage", 0))), _reward_text(tier_cfg.get("reward", [])), state]
		if i > best_tier:
			info.modulate = Color(0.6, 0.6, 0.65)
		row.add_child(info)
		_reward_box.add_child(row)


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_challenge_pressed() -> void:
	# 结果由 daily_boss_changed 信号回发（战斗按伤害结算）
	Game.start_daily_boss()
	var battle_ps: PackedScene = load("res://scenes/Battle.tscn")
	get_tree().root.add_child(battle_ps.instantiate())


func _on_claim_pressed() -> void:
	# 结果由 daily_boss_changed + 货币信号回发
	Game.claim_daily_boss_reward()
	_message_label.text = "已领取伤害档位奖励"


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


## 千分位格式化（纯显示，不修改任何数值）
func _format_num(n: int) -> String:
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
