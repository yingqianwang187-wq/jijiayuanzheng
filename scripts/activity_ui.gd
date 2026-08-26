# ==================================================================
# scripts/activity_ui.gd —— 活动界面脚本（挂在 scenes/Activity.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.5 / §3.6 / §3.15（v0.18）、scripts/contract.gd（只读，v0.18 新信号）、
#          scripts/game.gd（B 实际返回字段）
# 职责   ：活动（本地限时任务）纯显示层 + 领奖入口 + 指挥官等级展示。
#          - 连接信号：activity_changed(activities) / commander_changed(level, exp)
#          - 按钮只调入口（契约 §3.6）：领奖 → Game.claim_activity(id)；返回 → 切回 Main.tscn
#          - 只读入口：Game.get_activity_info()（B 实现返回数组 [{id,name,desc,done,claimed}]，
#            无 progress 字段，故进度以"目标 + 完成状态"呈现，奖励/目标从 Data.ACTIVITIES 静态读）、
#            Game.get_commander_info()（{level, exp, exp_next}）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准。
# 首屏说明：本场景从主界面切换而来，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Activity.tscn 结构一一对应）----
@onready var _commander_label: Label = $root_box/commander_label
@onready var _content_box: VBoxContainer = $root_box/scroll/content_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.activity_changed.connect(_on_activity_changed)
	Contract.commander_changed.connect(_on_commander_changed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_refresh_commander()
	_build_list()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_activity_changed(_activities: Array) -> void:
	_build_list()


func _on_commander_changed(_level: int, _exp: int) -> void:
	_refresh_commander()


## ------------------------------------------------------------------
## 指挥官等级（v0.18：Game.get_commander_info 只读）
## ------------------------------------------------------------------
func _refresh_commander() -> void:
	var info: Dictionary = Game.get_commander_info()
	_commander_label.text = "指挥官 Lv.%d 经验 %d/%d" % [int(info.get("level", 1)), int(info.get("exp", 0)), int(info.get("exp_next", 100))]


## ------------------------------------------------------------------
## 活动列表（B 实现 get_activity_info 返回 [{id,name,desc,done,claimed}]；
## 目标/奖励从 Data.ACTIVITIES 静态读；达成且未领可领奖）
## ------------------------------------------------------------------
func _build_list() -> void:
	for child in _content_box.get_children():
		_content_box.remove_child(child)
		child.queue_free()
	var list: Array = Game.get_activity_info()
	for item in list:
		var aid := StringName(str(item.get("id", "")))
		var cfg: Dictionary = Data.ACTIVITIES.get(aid, {})
		var done: bool = bool(item.get("done", false))
		var claimed: bool = bool(item.get("claimed", false))
		# v0.19 修复：Panel → PanelContainer（自动适配子内容尺寸，避免文字重叠）
		var panel := PanelContainer.new()
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		var name_label := Label.new()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_font_size_override("font_size", 14)
		var state_text: String = "✓ 已达成" if done else "未达成"
		name_label.text = "%s（%s）" % [str(item.get("name", str(aid))), state_text]
		var claim_btn := Button.new()
		if claimed:
			claim_btn.text = "已领取"
			claim_btn.disabled = true
		elif done:
			claim_btn.text = "领取"
			claim_btn.pressed.connect(_on_claim_pressed.bind(aid))
		else:
			claim_btn.text = "未达成"
			claim_btn.disabled = true
		head.add_child(name_label)
		head.add_child(claim_btn)
		v.add_child(head)
		var desc_label := Label.new()
		desc_label.add_theme_font_size_override("font_size", 12)
		desc_label.text = "目标：%s\n奖励：%s" % [_condition_text(cfg.get("condition", {})), _reward_text(cfg.get("reward", []))]
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(desc_label)
		panel.add_child(v)
		_content_box.add_child(panel)


func _on_claim_pressed(activity_id: StringName) -> void:
	# 结果由 activity_changed + 货币信号回发
	Game.claim_activity(activity_id)
	_message_label.text = "已领取活动奖励"


## ------------------------------------------------------------------
## 返回
## ------------------------------------------------------------------
func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 文本工具（Data 静态表，纯展示）
## ------------------------------------------------------------------
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
		"dungeon":
			return "通关地狱档秘境" if int(cond.get("target", 0)) >= 4 else "通关秘境档位 %d" % int(cond.get("target", 0))
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
