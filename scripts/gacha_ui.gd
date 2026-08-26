# ==================================================================
# scripts/gacha_ui.gd —— 抽卡界面脚本（挂在 scenes/Gacha.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.8（v0.7）、scripts/contract.gd（只读）
# 职责   ：抽卡界面的纯显示层。
#          - 连接信号：diamond_changed / gacha_result / owned_mechs_updated
#          - 按钮只调入口（契约 §3.6）：单抽/十连 → Game.summon(pool, times)（Game 内部
#            已支持"1 券 = 300 钻 = 1 抽、优先扣券"，UI 只判断可用性，不自行扣减）
#          - 只读入口：Game.summon_cost(pool, times) 显示所需钻石（含免费十连/新手半价）；
#                      Game.summon_pity_info(pool) 显示 SSR 保底进度；Game.diamond /
#                      Game.summon_ticket（召唤券，1 券 = Data.SUMMON_TICKET_VALUE 钻）
# 召唤券适配（用户反馈 #32）：按钮可用性 = 钻石 + 召唤券 × 单券价值 ≥ 成本；界面显示券数；
#          抽卡优先扣券由 Game.summon 处理（契约 §3.8）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 首屏说明：本场景从主界面切换而来，切换前的信号已错过；故 _ready 对 Game 公开状态
#          做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），此后一切走信号。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Gacha.tscn 结构一一对应）----
@onready var _diamond_label: Label = $root_box/diamond_label
@onready var _standard_button: Button = $root_box/pool_row/standard_button
@onready var _novice_button: Button = $root_box/pool_row/novice_button
@onready var _limited_button: Button = $root_box/pool_row/limited_button
@onready var _cost_label: Label = $root_box/cost_label
@onready var _pity_label: Label = $root_box/pity_label
@onready var _limited_info_label: Label = $root_box/limited_info_label
@onready var _single_button: Button = $root_box/summon_row/single_button
@onready var _ten_button: Button = $root_box/summon_row/ten_button
@onready var _result_box: VBoxContainer = $root_box/result_box
@onready var _owned_box: VBoxContainer = $root_box/owned_box
@onready var _back_button: Button = $root_box/back_button

## ---- UI 内部状态（仅当前选择的卡池，不含任何游戏数值）----
var _pool: StringName = &"standard"


func _ready() -> void:
	Contract.diamond_changed.connect(_on_diamond_changed)
	Contract.gacha_result.connect(_on_gacha_result)
	Contract.owned_mechs_updated.connect(_on_owned_mechs_updated)
	_standard_button.pressed.connect(_on_pool_pressed.bind(&"standard"))
	_novice_button.pressed.connect(_on_pool_pressed.bind(&"novice"))
	_limited_button.pressed.connect(_on_pool_pressed.bind(&"limited"))
	_single_button.pressed.connect(_on_summon_pressed.bind(1))
	_ten_button.pressed.connect(_on_summon_pressed.bind(10))
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（见文件头"首屏说明"）
	_refresh_pool_ui()
	_rebuild_owned_list()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_diamond_changed(_value: int) -> void:
	# 钻石/召唤券变化 → 刷新余额显示与按钮可用性（券数一并刷新，无需新信号）
	_refresh_pool_ui()


func _on_gacha_result(entries: Array) -> void:
	# 清空并重建结果区：只展示最近一次抽卡结果（契约 §3.5 gacha_result）
	for child in _result_box.get_children():
		_result_box.remove_child(child)
		child.queue_free()
	for entry in entries:
		_result_box.add_child(_make_result_row(entry))
	_refresh_pool_ui()  # 抽卡后 SSR 保底进度可能变化


func _on_owned_mechs_updated(_ids: Array) -> void:
	_rebuild_owned_list()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_pool_pressed(pool: StringName) -> void:
	_pool = pool
	_refresh_pool_ui()


func _on_summon_pressed(times: int) -> void:
	# 结果由 gacha_result / diamond_changed / owned_mechs_updated / fragments_updated 信号回发
	Game.summon(_pool, times)


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 池 UI 刷新（成本 / 按钮可用性 / 保底信息；只读 Game 入口）
## ------------------------------------------------------------------
func _refresh_pool_ui() -> void:
	_standard_button.button_pressed = (_pool == &"standard")
	_novice_button.button_pressed = (_pool == &"novice")
	_limited_button.button_pressed = (_pool == &"limited")
	var single_cost: int = Game.summon_cost(_pool, 1)
	var ten_cost: int = Game.summon_cost(_pool, 10)
	# 可用货币 = 钻石 + 召唤券 × 单券价值（契约 §3.8：1 券 = 300 钻 = 1 抽；
	# Game.summon 优先扣券，UI 只判断合计是否够）
	var afford: int = int(Game.diamond) + int(Game.summon_ticket) * Data.SUMMON_TICKET_VALUE
	_diamond_label.text = "钻石：%d（召唤券 ×%d）" % [int(Game.diamond), int(Game.summon_ticket)]
	_cost_label.text = "单抽 %d 钻 / 十连 %d 钻（召唤券 ×%d，1 券 = %d 钻，可用券抵扣）" % [single_cost, ten_cost, int(Game.summon_ticket), Data.SUMMON_TICKET_VALUE]
	_single_button.text = _button_text("单抽", single_cost)
	_ten_button.text = _button_text("十连", ten_cost)
	_single_button.disabled = afford < single_cost
	_ten_button.disabled = afford < ten_cost
	# 限定池 UP 信息（Data.SUMMON_POOLS.limited：up_id / up_rate；独立保底 limited_pity）
	if _pool == &"limited":
		var limited_cfg: Dictionary = Data.SUMMON_POOLS.get(&"limited", {})
		var up_id := StringName(str(limited_cfg.get("up_id", "")))
		var up_name: String = str(Data.MECH_GIRLS.get(up_id, {}).get("name", str(up_id)))
		var up_rate: float = float(limited_cfg.get("up_rate", 0.0))
		_limited_info_label.text = "限定UP：%s（SSR 中 %d%% 概率）｜独立保底" % [up_name, roundi(up_rate * 100.0)]
	else:
		_limited_info_label.text = ""
	var pity: Dictionary = Game.summon_pity_info(_pool)
	_pity_label.text = "SSR 保底进度：%d/%d（再 %d 抽必出）" % [
		int(pity.get("progress", 0)),
		Data.SUMMON_PITY_SSR_LIMIT,
		int(pity.get("remain", 0)),
	]


## 按钮文本：免费（cost<=0，如开局免费十连）标注"免费"，否则标注所需钻石
func _button_text(label: String, cost: int) -> String:
	if cost <= 0:
		return label + "（免费）"
	return label + "（%d 钻）" % cost


## ------------------------------------------------------------------
## 结果 / 拥有列表展示（静态信息读 Data；动态值只来自信号 / 只读入口）
## ------------------------------------------------------------------
func _make_result_row(entry: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var id := StringName(entry.get("id", &""))
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var rarity: int = int(entry.get("rarity", 0))
	var text: String = "%s（%s）" % [str(cfg.get("name", str(id))), _rarity_text(rarity)]
	if bool(entry.get("is_new", false)):
		text += " ★新机娘！"
	var frag: int = int(entry.get("fragments", 0))
	if frag > 0:
		text += " 碎片 +%d" % frag
	var label := Label.new()
	label.text = text
	row.add_child(label)
	return row


func _rebuild_owned_list() -> void:
	for child in _owned_box.get_children():
		_owned_box.remove_child(child)
		child.queue_free()
	for mech_id in Game.get_owned_mechs():
		var cfg: Dictionary = Data.MECH_GIRLS.get(mech_id, {})
		var label := Label.new()
		label.text = "%s（%s）" % [str(cfg.get("name", str(mech_id))), _rarity_text(int(cfg.get("rarity", 0)))]
		_owned_box.add_child(label)


## 稀有度枚举值 → 文本（Data.Rarity：R=0 / SR=1 / SSR=2）
func _rarity_text(r: int) -> String:
	match r:
		Data.Rarity.R:
			return "R"
		Data.Rarity.SR:
			return "SR"
		Data.Rarity.SSR:
			return "SSR"
	return "?"
