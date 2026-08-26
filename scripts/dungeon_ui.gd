# ==================================================================
# scripts/dungeon_ui.gd —— 秘境界面脚本（挂在 scenes/Dungeon.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.10（v0.13）、scripts/contract.gd（只读）
# 职责   ：秘境页（4U 起作为主界面"秘境"主页面嵌入，无返回按钮）的纯显示层 + 挑战/扫荡入口。
#          - 连接信号：stamina_changed / dungeon_cleared_changed / dungeon_reward
#          - 按钮只调入口（契约 §3.6）：挑战 → Game.start_dungeon(kind, tier) 后打开战斗覆盖层
#            Battle.tscn；扫荡 → Game.sweep_dungeon(kind, tier)
#          - 只读入口：Game.dungeon_cost / get_dungeon_status / get_stamina / get_formation /
#            Game.get_power（上阵战力 = 阵型各机娘战力合计，与 Game._team_power 同源）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 列表   ：Data.DUNGEONS（5 副本 × 5 档）驱动，顶部页签切换副本（§1.6 ⑪）；
#          档位 tier 0~4 = 新手/简单/中等/困难/地狱；已通关档"已通关"、挑战禁用、扫荡可用。
# ==================================================================
extends Control

## 档位名称（tier 0~4，对应 Data.DUNGEONS tiers 顺序）
const _TIER_NAMES := ["新手", "简单", "中等", "困难", "地狱"]

## ---- 节点引用（与 scenes/Dungeon.tscn 结构一一对应）----
@onready var _stamina_label: Label = $root_box/stamina_label
@onready var _tab_row: HBoxContainer = $root_box/tab_row
@onready var _list_box: VBoxContainer = $root_box/list_box
@onready var _message_label: Label = $root_box/message_label

## ---- UI 内部状态（仅当前副本页签，不含任何游戏数值）----
var _active_kind: StringName = &"gold"
var _tab_buttons: Dictionary = {}   # kind -> Button


func _ready() -> void:
	Contract.stamina_changed.connect(_on_stamina_changed)
	Contract.dungeon_cleared_changed.connect(_on_dungeon_cleared_changed)
	Contract.dungeon_reward.connect(_on_dungeon_reward)
	_build_tabs()
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）
	_stamina_label.text = "体力：%d/%d" % [Game.get_stamina(), Data.STAMINA_MAX]
	_refresh_list()


## 副本页签（§1.6 ⑪：金币|经验|装备|宝石|碎片），动态构建
func _build_tabs() -> void:
	var kinds: Array = Data.DUNGEONS.keys()
	for kind in kinds:
		var kind_id := StringName(kind)
		var cfg: Dictionary = Data.DUNGEONS[kind_id]
		var btn := Button.new()
		btn.text = str(cfg.get("name", str(kind_id)))
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_tab_pressed.bind(kind_id))
		_tab_row.add_child(btn)
		_tab_buttons[kind_id] = btn
	_refresh_tab_states()


func _on_tab_pressed(kind: StringName) -> void:
	_active_kind = kind
	_refresh_tab_states()
	_refresh_list()


func _refresh_tab_states() -> void:
	for kind in _tab_buttons:
		_tab_buttons[kind].button_pressed = (kind == _active_kind)


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_stamina_changed(value: int) -> void:
	_stamina_label.text = "体力：%d/%d" % [value, Data.STAMINA_MAX]
	_refresh_list()


func _on_dungeon_cleared_changed(_status: Dictionary) -> void:
	# 通关记录变化（首通/扫荡后）——刷新解锁与扫荡可用状态
	_refresh_list()


func _on_dungeon_reward(kind: StringName, tier: int, rewards: Dictionary) -> void:
	var cfg: Dictionary = Data.DUNGEONS.get(kind, {})
	var tier_name: String = _tier_name(tier)
	var amount: int = int(rewards.get("amount", 0))
	_message_label.text = "%s %s通关：%s" % [str(cfg.get("name", str(kind))), tier_name, _reward_text(str(rewards.get("kind", "")), amount)]


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_challenge_pressed(kind: StringName, tier: int) -> void:
	var cost: Dictionary = Game.dungeon_cost(kind, tier)
	if bool(cost.get("cleared", false)):
		_message_label.text = "该档已通关，请使用扫荡"
		return
	var power_req: int = int(cost.get("power_req", 0))
	var power := _team_power()
	if power < power_req:
		_message_label.text = "战力不足：需 %s，当前 %s" % [_format_num(power_req), _format_num(power)]
		return
	if Game.get_stamina() < int(cost.get("stamina", 0)):
		_message_label.text = "体力不足"
		return
	Game.start_dungeon(kind, tier)
	var battle_ps: PackedScene = load("res://scenes/Battle.tscn")
	get_tree().root.add_child(battle_ps.instantiate())


func _on_sweep_pressed(kind: StringName, tier: int) -> void:
	# 结果由 dungeon_reward / stamina_changed 信号回发
	Game.sweep_dungeon(kind, tier)


## ------------------------------------------------------------------
## 秘境列表（§1.6 ⑪：当前页签副本 × 5 档行，动态构建）
## ------------------------------------------------------------------
func _refresh_list() -> void:
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	if not Data.DUNGEONS.has(_active_kind):
		return
	var cfg: Dictionary = Data.DUNGEONS[_active_kind]
	var title := Label.new()
	title.text = "—— %s ——（上阵战力 %s）" % [str(cfg.get("name", str(_active_kind))), _format_num(_team_power())]
	_list_box.add_child(title)
	var tiers: Array = cfg.tiers
	for i in tiers.size():
		_list_box.add_child(_make_tier_row(_active_kind, i, tiers[i]))


func _make_tier_row(kind: StringName, tier: int, tier_cfg: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var cost: Dictionary = Game.dungeon_cost(kind, tier)
	var cleared: bool = bool(cost.get("cleared", false))
	var info := Label.new()
	info.text = "%s | 门槛 %s | 体力 %d | 首通钻 %d%s" % [
		_tier_name(tier),
		_format_num(int(tier_cfg.get("power_req", 0))),
		int(cost.get("stamina", 0)),
		int(tier_cfg.get("first_clear_diamond", 0)),
		" | 已通关" if cleared else "",
	]
	info.custom_minimum_size = Vector2(400, 0)
	var challenge := Button.new()
	challenge.text = "挑战"
	challenge.disabled = cleared  # 挑战限未通关档
	challenge.pressed.connect(_on_challenge_pressed.bind(kind, tier))
	var sweep := Button.new()
	sweep.text = "扫荡"
	sweep.disabled = not cleared  # 扫荡仅限已通关档
	sweep.pressed.connect(_on_sweep_pressed.bind(kind, tier))
	row.add_child(info)
	row.add_child(challenge)
	row.add_child(sweep)
	return row


## ------------------------------------------------------------------
## 工具（静态信息读 Data；动态值只来自信号 / 只读入口）
## ------------------------------------------------------------------
func _tier_name(tier: int) -> String:
	if tier >= 0 and tier < _TIER_NAMES.size():
		return _TIER_NAMES[tier]
	return str(tier)


## 上阵战力 = 阵型各机娘战力合计（Game.get_formation + Game.get_power 只读入口组合，
## 与 Game._team_power 同公式同数据源）
func _team_power() -> int:
	var total := 0
	for slot in Game.get_formation():
		var mid := StringName(str(slot.get("id", "")))
		if mid != &"":
			total += Game.get_power(mid)
	return total


func _reward_text(kind: String, amount: int) -> String:
	match kind:
		"gold": return "金币 +%d" % amount
		"exp": return "经验 +%d（上阵机娘个人条）" % amount
		"material": return "升级材料 ×%d" % amount
		"fragment": return "机娘碎片 +%d" % amount
		"equipment": return "装备 ×%d" % amount
		"gem": return "宝石 ×%d" % amount
	return "%s ×%d" % [kind, amount]


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
