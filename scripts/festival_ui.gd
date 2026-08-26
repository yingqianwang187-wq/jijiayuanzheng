# ==================================================================
# scripts/festival_ui.gd —— 节日活动界面脚本（挂在 scenes/Festival.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.18（v0.22）、scripts/contract.gd（只读，v0.22 新信号）、
#          scripts/game.gd（B 实际返回字段）
# 职责   ：节日活动覆盖层的纯显示层 + 领奖入口。
#          - 连接信号：festival_changed(festivals)
#          - 按钮只调入口（契约 §3.6）：领奖 → Game.claim_festival_reward(id)；返回 →
#            queue_free() 关闭覆盖层
#          - 只读入口：Game.get_festival_info()（B 实现返回数组 [{id, name, month, day,
#            active, done, claimed}]）；目标与奖励从 Data.FESTIVALS 静态读（condition/reward）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 首屏说明：本场景从主界面覆盖层打开，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Festival.tscn 结构一一对应）----
@onready var _festival_box: VBoxContainer = $root_box/scroll/festival_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.festival_changed.connect(_on_festival_changed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_build_list()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_festival_changed(_festivals: Array) -> void:
	_build_list()


## ------------------------------------------------------------------
## 节日列表（名称/日期/目标/奖励/状态 active/done/claimed + 领奖）
## ------------------------------------------------------------------
func _build_list() -> void:
	for child in _festival_box.get_children():
		_festival_box.remove_child(child)
		child.queue_free()
	var list: Array = Game.get_festival_info()
	for item in list:
		var fid := StringName(str(item.get("id", "")))
		var cfg: Dictionary = Data.FESTIVALS.get(fid, {})
		var active: bool = bool(item.get("active", false))
		var done: bool = bool(item.get("done", false))
		var claimed: bool = bool(item.get("claimed", false))
		var panel := Panel.new()
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 3)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		var name_label := Label.new()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 14)
		var state: String = ""
		if claimed:
			state = "  [已领]"
		elif active and done:
			state = "  [可领]"
		elif active:
			state = "  [进行中]"
		else:
			state = "  [未开放]"
		name_label.text = "%s（%s）%s" % [str(item.get("name", str(fid))), _date_text(int(item.get("month", 0)), int(item.get("day", 0))), state]
		if not active:
			name_label.modulate = Color(0.6, 0.6, 0.65)
		var claim_btn := Button.new()
		if claimed:
			claim_btn.text = "已领取"
			claim_btn.disabled = true
		elif active and done:
			claim_btn.text = "领取"
			claim_btn.pressed.connect(_on_claim_pressed.bind(fid))
		else:
			claim_btn.text = "未达成" if active else "未开放"
			claim_btn.disabled = true
		head.add_child(name_label)
		head.add_child(claim_btn)
		v.add_child(head)
		var desc_label := Label.new()
		desc_label.add_theme_font_size_override("font_size", 12)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_label.text = "目标：%s\n奖励：%s" % [_condition_text(cfg.get("condition", {})), _reward_text(cfg.get("reward", []))]
		v.add_child(desc_label)
		panel.add_child(v)
		_festival_box.add_child(panel)


func _on_claim_pressed(festival_id: StringName) -> void:
	# 结果由 festival_changed + 货币信号回发
	Game.claim_festival_reward(festival_id)
	_message_label.text = "已领取节日奖励"


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 文本工具（Data 静态表，纯展示）
## ------------------------------------------------------------------
## 节日日期（month=0/day=0 = 常驻）
func _date_text(month: int, day: int) -> String:
	if month == 0 and day == 0:
		return "常驻"
	return "%d月%d日" % [month, day]


func _condition_text(cond: Dictionary) -> String:
	match str(cond.get("type", "")):
		"story_cleared":
			return "通关主线 %d 关" % int(cond.get("target", 0))
		"summon_count":
			return "累计抽卡 %d 次" % int(cond.get("target", 0))
		"tower":
			return "爬塔 %d 层" % int(cond.get("target", 0))
		"collection":
			return "集齐 %d 位机娘" % int(cond.get("target", 0))
		"power":
			return "上阵战力达 %d" % int(cond.get("target", 0))
	return str(cond.get("type", ""))


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
