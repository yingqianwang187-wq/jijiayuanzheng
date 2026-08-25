# ==================================================================
# scripts/main_ui.gd —— 主界面脚本（挂在 scenes/Main.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.7 / §3.8 / §3.9 / §3.10（v0.13）、scripts/contract.gd（只读）
# 职责   ：主界面纯显示层。
#          - 连接信号：gold_changed / mech_girl_updated / mech_exp_updated /
#            level_cleared / level_progress_changed / idle_rewards_updated /
#            exp_balance_updated / diamond_changed / fragments_updated / owned_mechs_updated /
#            battle_star / mech_star_updated / stamina_changed / box_count_changed /
#            bag_updated / box_opened
#          - 按钮只调入口（契约 §3.6）：升级 → Game.upgrade(id)；升星 → Game.upgrade_star(id)；
#            收获 → Game.collect_idle()；挑战 → Game.start_battle(Game.get_next_level())（v0.9 主线
#            不可选关）+ 切到 Battle.tscn；开箱 → Game.open_box()（结果经 box_opened 显示）；
#            秘境/背包/抽卡/布阵 → 切到 Dungeon.tscn / Bag.tscn / Gacha.tscn / Formation.tscn；
#            手动存档 → Save.save_game()
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 星级/升星（v0.10）：机娘行显示 ★N（Game.mech_stars 只读）与等级上限（Game.get_level_cap）；
#          升星按钮显示所需碎片（Game.star_cost 只读：fragments 所需 / level_required 解锁等级），
#          碎片不足 / 未满级解锁则置灰并在 message_label 提示；点按调 Game.upgrade_star(id)，
#          结果经 mech_star_updated / fragments_updated 信号回发刷新。
# 主线（v0.9）：只显示并挑战"当前最高未通关的下一关"（Game.get_next_level() 只读入口），
#          无选关列表、无扫荡入口；首通奖励 = 金币 + 钻石 + 小钰碎片（普通 1 片 / BOSS 3 片，
#          Data.XIAOYU_FRAGMENT_*，走 fragments_updated 信号），通关后随 last_clear 快照展示。
# 机娘列表：只显示已拥有的机娘（契约 §3.8 v0.7：上阵/养成 = 拥有的机娘），
#          名单来自只读入口 Game.get_owned_mechs()（按 Data 顺序）；
#          owned_mechs_updated / fragments_updated 到达时重建列表。
# 首屏说明：本场景会从战斗场景切回（启动时那批初始信号已错过，Game 不重发），
#          故 _ready 对 Game 公开状态做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），
#          此后一切更新一律走信号。
# 右上角余额（契约 §3.7，v0.6）：金币余额 = 已入账金币 + 待收获金币；
#          经验余额 = 全局经验余额 + 待收获经验。随 gold_changed / idle_rewards_updated /
#          exp_balance_updated 与首屏快照刷新；刷新时只读 Game 公开状态（信号到达时
#          Game 数值已更新完毕，读值与信号参数一致）。
# 机娘显示：主界面无战斗概念，机娘始终按满血显示；等级 / 攻击以信号参数为准，
#          满血值由 Data 静态表按等级换算（与 Game._mech_stats 同一公式、同一数据源）。
# 经验显示：exp / exp_next 以 mech_exp_updated 信号参数为准；首屏快照时 exp 读
#          Game.mech_exp，exp_next 用只读入口 Game.upgrade_exp_cost(id)（契约 §3.6 v0.5）。
# 升级禁用：v0.5 起用只读入口 Game.upgrade_cost(id) / Game.upgrade_exp_cost(id) 判断
#          金币/经验是否足够（不再自行换算费用）；v0.6 经验判定 = 个人经验条 + 全局经验
#          余额合计（与 Game.upgrade 一致）；不足时按钮置灰并在 message_label 提示原因；
#          在 gold_changed / mech_exp_updated / mech_girl_updated / exp_balance_updated
#          信号到达时刷新全部按钮。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Main.tscn 结构一一对应）----
@onready var _gold_label: Label = $root_box/gold_label
@onready var _idle_rewards_label: Label = $root_box/idle_row/idle_rewards_label
@onready var _collect_button: Button = $root_box/idle_row/collect_button
@onready var _gold_balance_label: Label = $root_box/balance_row/gold_balance_label
@onready var _exp_balance_label: Label = $root_box/balance_row/exp_balance_label
@onready var _diamond_label: Label = $root_box/balance_row/diamond_label
@onready var _stamina_label: Label = $root_box/balance_row/stamina_label
@onready var _challenge_button: Button = $root_box/challenge_button
@onready var _mech_box: VBoxContainer = $root_box/mech_box
@onready var _last_clear_label: Label = $root_box/last_clear_label
@onready var _message_label: Label = $root_box/message_label
@onready var _dungeon_button: Button = $root_box/feature_row/dungeon_button
@onready var _bag_button: Button = $root_box/feature_row/bag_button
@onready var _box_button: Button = $root_box/feature_row/box_button
@onready var _save_button: Button = $root_box/bottom_row/save_button
@onready var _gacha_button: Button = $root_box/bottom_row/gacha_button
@onready var _formation_button: Button = $root_box/bottom_row/formation_button

## ---- UI 内部状态（仅行引用，不含任何游戏数值）----
var _mech_rows: Dictionary = {}      # StringName -> { stats_label, exp_label, upgrade_button }


func _ready() -> void:
	Contract.gold_changed.connect(_on_gold_changed)
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
	Contract.mech_exp_updated.connect(_on_mech_exp_updated)
	Contract.level_cleared.connect(_on_level_cleared)
	Contract.level_progress_changed.connect(_on_level_progress_changed)
	Contract.idle_rewards_updated.connect(_on_idle_rewards_updated)
	Contract.exp_balance_updated.connect(_on_exp_balance_updated)
	Contract.diamond_changed.connect(_on_diamond_changed)
	Contract.fragments_updated.connect(_on_fragments_updated)
	Contract.owned_mechs_updated.connect(_on_owned_mechs_updated)
	Contract.battle_star.connect(_on_battle_star)
	Contract.mech_star_updated.connect(_on_mech_star_updated)
	Contract.stamina_changed.connect(_on_stamina_changed)
	Contract.box_count_changed.connect(_on_box_count_changed)
	Contract.bag_updated.connect(_on_bag_updated)
	Contract.box_opened.connect(_on_box_opened)
	_collect_button.pressed.connect(_on_collect_pressed)
	_challenge_button.pressed.connect(_on_enter_battle_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_gacha_button.pressed.connect(_on_gacha_pressed)
	_formation_button.pressed.connect(_on_formation_pressed)
	_dungeon_button.pressed.connect(_on_dungeon_pressed)
	_bag_button.pressed.connect(_on_bag_pressed)
	_box_button.pressed.connect(_on_box_pressed)
	_rebuild_mech_rows()
	_seed_initial_state()


## ------------------------------------------------------------------
## 信号处理（只刷新显示；余额 / 升级按钮随相关信号一并刷新）
## ------------------------------------------------------------------
func _on_gold_changed(value: int) -> void:
	_gold_label.text = "金币：%d" % value
	_refresh_balance()
	_refresh_upgrade_buttons()


func _on_idle_rewards_updated(gold: int, exp: int) -> void:
	# v0.6：待收获 = 金币 + 经验（挂机同产，参数以信号为准）
	_idle_rewards_label.text = "待收获：金币 +%d 经验 +%d" % [gold, exp]
	_refresh_balance()


func _on_mech_girl_updated(id: StringName, _hp: int, atk: int, level: int) -> void:
	# 主界面无战斗概念，机娘始终按满血显示；等级 / 攻击以信号为准（见文件头说明）
	_render_mech_row(id, level, atk)
	_refresh_upgrade_buttons()


func _on_mech_exp_updated(id: StringName, exp: int, exp_next: int) -> void:
	_render_mech_exp(id, exp, exp_next)
	_refresh_upgrade_buttons()


func _on_exp_balance_updated(_balance: int) -> void:
	# v0.6：全局经验余额变化（挂机收获入账 / 升级补足扣减）
	_refresh_balance()
	_refresh_upgrade_buttons()


func _on_diamond_changed(value: int) -> void:
	# v0.7：钻石变化（首通奖励 / 抽卡消耗）
	_diamond_label.text = "钻石：%d" % value


func _on_fragments_updated(_id: StringName, _count: int) -> void:
	# v0.7：碎片变化（抽到重复机娘转化）——刷新机娘列表（只读；列表本身可能不变）
	_rebuild_mech_rows()


func _on_owned_mechs_updated(_ids: Array) -> void:
	# v0.7：拥有列表变化（抽到新机娘）——重建机娘列表（新机娘入列）
	_rebuild_mech_rows()


func _on_mech_star_updated(id: StringName, _star: int, _level_cap: int) -> void:
	# v0.10：机娘升星——刷新星级、等级上限/属性、升星按钮与提示
	_render_star(id)
	var level: int = int(Game.mech_levels.get(id, 1))
	_render_mech_row(id, level, _calc_atk(id, level))
	_refresh_upgrade_buttons()


func _on_stamina_changed(value: int) -> void:
	# v0.13：体力变化（恢复结算/秘境消耗/买体力）
	_stamina_label.text = "体力 %d/%d" % [value, Data.STAMINA_MAX]


func _on_box_count_changed(count: int) -> void:
	# v0.13：待开箱数变化
	_box_button.text = "开箱（%d）" % count
	_box_button.disabled = count <= 0


func _on_bag_updated(_items: Dictionary, _capacity: int) -> void:
	# v0.13：背包变化（主界面无背包展示，预留；背包详情在 Bag 场景）
	pass


func _on_box_opened(reward: Dictionary) -> void:
	# v0.13：开箱结果展示（实际入账走 gold_changed / bag_updated / fragments_updated）
	var type: String = str(reward.get("type", ""))
	var amount: int = int(reward.get("amount", 0))
	match type:
		"gold":
			_message_label.text = "开箱获得 %d 金币！" % amount
		"material":
			_message_label.text = "开箱获得 升级材料 ×%d！" % amount
		"fragment":
			var mid := StringName(str(reward.get("mech_id", "")))
			var cfg: Dictionary = Data.MECH_GIRLS.get(mid, {})
			_message_label.text = "开箱获得 %s碎片 ×%d！" % [str(cfg.get("name", str(mid))), amount]


func _on_level_cleared(level: int, first_clear: bool) -> void:
	# v0.9：首通奖励 = 金币 + 钻石 + 小钰碎片（普通 1 片 / 章节 BOSS 3 片）
	if first_clear:
		var reward: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward", 0))
		var diamond: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward_diamond", 0))
		_message_label.text = "首通奖励：金币 +%d 钻石 +%d 小钰碎片 ×%d" % [reward, diamond, _first_clear_frag(level)]
	else:
		_message_label.text = "第 %d 关已通关" % level


func _on_battle_star(star: int) -> void:
	# v0.8：星级评价（战斗场景发出的信号主界面通常收不到，重入时由快照 last_clear 展示）
	_message_label.text = "本关评价：%d 星！" % star


func _on_level_progress_changed(_level: int) -> void:
	# v0.9：主线不可选关——刷新"挑战第 N 关"按钮
	_refresh_challenge()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_collect_pressed() -> void:
	# 结果由 gold_changed / exp_balance_updated / idle_rewards_updated 信号回发，不依赖返回值
	Game.collect_idle()


func _on_enter_battle_pressed() -> void:
	# v0.9：主线只挑战"当前最高未通关的下一关"（Game 校验，不可选关）
	var level: int = Game.get_next_level()
	if level < 1 or level > Data.MAX_LEVEL:
		_message_label.text = "主线已全部通关"
		return
	Game.start_battle(level)
	get_tree().change_scene_to_file("res://scenes/Battle.tscn")


func _on_save_pressed() -> void:
	Save.save_game()
	_message_label.text = "已保存"


func _on_gacha_pressed() -> void:
	# v0.7：进入抽卡界面（阶段 1）
	get_tree().change_scene_to_file("res://scenes/Gacha.tscn")


func _on_formation_pressed() -> void:
	# v0.8：进入布阵界面（战斗 2.0）
	get_tree().change_scene_to_file("res://scenes/Formation.tscn")


func _on_dungeon_pressed() -> void:
	# v0.13：进入秘境界面
	get_tree().change_scene_to_file("res://scenes/Dungeon.tscn")


func _on_bag_pressed() -> void:
	# v0.13：进入背包界面
	get_tree().change_scene_to_file("res://scenes/Bag.tscn")


func _on_box_pressed() -> void:
	# v0.13：开 1 个宝箱（结果由 box_opened 信号回发显示到 message_label）
	Game.open_box()


## ------------------------------------------------------------------
## 右上角余额（契约 §3.7，v0.6）：金币余额 = 已入账 + 待收获；经验余额 = 全局余额 + 待收获
## 刷新时机：gold_changed / idle_rewards_updated / exp_balance_updated / 首屏快照
## ------------------------------------------------------------------
func _refresh_balance() -> void:
	_gold_balance_label.text = "金币 %s (+%d)" % [_format_num(int(Game.gold)), roundi(Game.idle_pending)]
	_exp_balance_label.text = "经验 %s (+%d)" % [_format_num(int(Game.exp_balance)), roundi(Game.idle_pending_exp)]


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


## ------------------------------------------------------------------
## 主线挑战（v0.9：不可选关，只显示并挑战"当前最高未通关的下一关"）
## ------------------------------------------------------------------
func _refresh_challenge() -> void:
	var next: int = Game.get_next_level()
	if next > Data.MAX_LEVEL:
		_challenge_button.text = "主线已全部通关"
		_challenge_button.disabled = true
	else:
		_challenge_button.text = "挑战第 %d 关" % next
		_challenge_button.disabled = false


## ------------------------------------------------------------------
## 机娘列表（只显示已拥有的机娘；名单来自只读入口 Game.get_owned_mechs()，
## 按 Data 顺序；v0.7 上阵/养成 = 拥有的机娘）
## 一行 = 星级+名字 + 状态（Lv/上限/攻/血）+ 经验（exp/exp_next）+ 升级 + 升星按钮
## 重建时机：_ready 首屏 / owned_mechs_updated / fragments_updated
## ------------------------------------------------------------------
func _rebuild_mech_rows() -> void:
	for child in _mech_box.get_children():
		_mech_box.remove_child(child)
		child.queue_free()
	_mech_rows.clear()
	for id in Game.get_owned_mechs():
		var cfg: Dictionary = Data.MECH_GIRLS[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_label := Label.new()
		name_label.text = str(cfg.get("name", str(id)))
		name_label.custom_minimum_size = Vector2(120, 0)
		var stats_label := Label.new()
		stats_label.text = "Lv.-/- 攻- 血 -/-"
		stats_label.custom_minimum_size = Vector2(200, 0)
		var exp_label := Label.new()
		exp_label.text = "经验 -/-"
		exp_label.custom_minimum_size = Vector2(120, 0)
		var upgrade_button := Button.new()
		upgrade_button.text = "升级"
		upgrade_button.pressed.connect(_on_upgrade_pressed.bind(id))
		var star_button := Button.new()
		star_button.text = "升星"
		star_button.pressed.connect(_on_star_pressed.bind(id))
		row.add_child(name_label)
		row.add_child(stats_label)
		row.add_child(exp_label)
		row.add_child(upgrade_button)
		row.add_child(star_button)
		_mech_box.add_child(row)
		_mech_rows[id] = { "name_label": name_label, "stats_label": stats_label, "exp_label": exp_label, "upgrade_button": upgrade_button, "star_button": star_button, "star_reason": "" }
	# 重建后补渲染全部行（星级/属性/经验），避免初始信号（owned_mechs_updated 等）重建后显示占位
	_render_all_rows()
	_refresh_upgrade_buttons()


## 渲染全部机娘行：星级 / 属性 / 经验（读 Game 公开状态与只读入口）
func _render_all_rows() -> void:
	for id in _mech_rows:
		_render_star(id)
		var level: int = int(Game.mech_levels.get(id, 1))
		_render_mech_row(id, level, _calc_atk(id, level))
		var exp: int = int(Game.mech_exp.get(id, 0))
		_render_mech_exp(id, exp, Game.upgrade_exp_cost(id))


func _on_upgrade_pressed(mech_id: StringName) -> void:
	# 结果由 gold_changed / mech_girl_updated / mech_exp_updated / exp_balance_updated 信号回发
	Game.upgrade(mech_id)


func _on_star_pressed(mech_id: StringName) -> void:
	# v0.10：升星（结果由 mech_star_updated / fragments_updated 信号回发）
	Game.upgrade_star(mech_id)


## 渲染一行机娘：等级 / 攻击来自信号（或首屏快照换算），满血值与等级上限由
## Data 静态表 + 星级换算（与 Game._mech_stats / Game.get_level_cap 同一公式、同一数据源）
func _render_mech_row(id: StringName, level: int, atk: int) -> void:
	var row: Dictionary = _mech_rows.get(id, {})
	if row.is_empty():
		return
	var max_hp: int = _calc_max_hp(id, level)
	var cap: int = Game.get_level_cap(id)
	row.stats_label.text = "Lv.%d/%d 攻%d 血 %d/%d" % [level, cap, atk, max_hp, max_hp]


## 渲染一行机娘星级（v0.10）：名字前加 ★N（Game.mech_stars 只读）
func _render_star(id: StringName) -> void:
	var row: Dictionary = _mech_rows.get(id, {})
	if row.is_empty():
		return
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var star: int = int(Game.mech_stars.get(id, 1))
	row.name_label.text = "★%d %s（%s）" % [star, str(cfg.get("name", str(id))), str(cfg.get("role", ""))]


## 星级属性乘数（与 Game._mech_stats 同公式：×(1+STAR_STAT_GAIN)^(star-1)）
func _calc_star_mult(id: StringName) -> float:
	var star: int = int(Game.mech_stars.get(id, 1))
	return pow(1.0 + Data.STAR_STAT_GAIN, float(star - 1))


func _calc_atk(id: StringName, level: int) -> int:
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var base: int = int(cfg.get("base_atk", 0)) + (level - 1) * int(cfg.get("growth", {}).get("atk", 0))
	return int(round(float(base) * _calc_star_mult(id)))


func _calc_max_hp(id: StringName, level: int) -> int:
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var base: int = int(cfg.get("base_hp", 0)) + (level - 1) * int(cfg.get("growth", {}).get("hp", 0))
	return int(round(float(base) * _calc_star_mult(id)))


## 渲染一行机娘经验：exp / exp_next 以信号参数为准（v0.4）
func _render_mech_exp(id: StringName, exp: int, exp_next: int) -> void:
	var row: Dictionary = _mech_rows.get(id, {})
	if row.is_empty():
		return
	row.exp_label.text = "经验 %d/%d" % [exp, exp_next]


## ------------------------------------------------------------------
## 升星按钮状态（契约 §3.6 v0.10）：Game.star_cost(id) 只读入口给出所需碎片与解锁等级，
## 不足/未解锁则置灰并记录原因（由 _refresh_upgrade_buttons 合并展示到 message_label）。
## ------------------------------------------------------------------
func _refresh_star_button(id: StringName) -> void:
	var row: Dictionary = _mech_rows.get(id, {})
	if row.is_empty():
		return
	var cfg: Dictionary = Data.MECH_GIRLS.get(id, {})
	var star: int = int(Game.mech_stars.get(id, 1))
	var cost: Dictionary = Game.star_cost(id)
	var frag_needed: int = int(cost.get("fragments", 0))
	var frag_have: int = int(Game.fragments.get(id, 0))
	var level_required: int = int(cost.get("level_required", 0))
	var level: int = int(Game.mech_levels.get(id, 1))
	var reason: String = ""
	if star >= Data.MAX_STAR:
		row.star_button.text = "已满星"
		row.star_button.disabled = true
		row.star_reason = ""
		return
	elif frag_have < frag_needed:
		reason = "%s 升星碎片不足：需 %d 片，现有 %d 片" % [str(cfg.get("name", str(id))), frag_needed, frag_have]
	elif level_required > 0 and level < level_required:
		reason = "%s 升星需先升到 %d 级" % [str(cfg.get("name", str(id))), level_required]
	row.star_button.text = "升星（%d 片）" % frag_needed
	row.star_button.disabled = reason != ""
	row.star_reason = reason


## ------------------------------------------------------------------
## 升级/升星按钮状态（契约 §3.6 v0.5 / v0.6 / v0.10）：升级用只读入口判断金币/经验，
## 升星用 Game.star_cost(id) 判断碎片/解锁等级；不足则置灰并在 message_label 提示原因；
## 够则恢复可用并清空原因提示。判断所需当前数值只读 Game 公开状态（不修改任何数值）。
## ------------------------------------------------------------------
func _refresh_upgrade_buttons() -> void:
	var gold_now: int = int(Game.gold)
	var first_reason: String = ""
	var any_disabled := false
	for id in _mech_rows:
		var row: Dictionary = _mech_rows[id]
		# 升星按钮状态（顺带收集升星原因）
		_refresh_star_button(id)
		# 升级条件
		var gold_cost: int = Game.upgrade_cost(id)
		var exp_cost: int = Game.upgrade_exp_cost(id)
		var exp_now: int = int(Game.mech_exp.get(id, 0)) + int(Game.exp_balance)
		var lack_gold: bool = gold_now < gold_cost
		var lack_exp: bool = exp_now < exp_cost
		row.upgrade_button.disabled = lack_gold or lack_exp
		if lack_gold or lack_exp:
			any_disabled = true
			if first_reason.is_empty():
				if lack_gold and lack_exp:
					first_reason = "金币和经验都不足，无法升级"
				elif lack_gold:
					first_reason = "金币不足，无法升级"
				else:
					first_reason = "经验不足，无法升级"
		# 升星原因（无升级原因时展示）
		if first_reason.is_empty() and row.star_reason != "":
			first_reason = str(row.star_reason)
			any_disabled = true
	if any_disabled:
		_message_label.text = first_reason
	else:
		_message_label.text = ""


## ------------------------------------------------------------------
## 首屏只读快照（契约 §3.1"首屏铺底例外"，见文件头"首屏说明"）：
## 金币 / 待收获（金币+经验）/ 余额 / 解锁进度 / 机娘等级与经验 / 上次通关消息
## 均来自 Game 公开状态
## ------------------------------------------------------------------
func _seed_initial_state() -> void:
	_gold_label.text = "金币：%d" % Game.gold
	_idle_rewards_label.text = "待收获：金币 +%d 经验 +%d" % [roundi(Game.idle_pending), roundi(Game.idle_pending_exp)]
	_diamond_label.text = "钻石：%d" % Game.diamond
	_stamina_label.text = "体力 %d/%d" % [Game.get_stamina(), Data.STAMINA_MAX]
	_on_box_count_changed(Game.get_box_count())
	_refresh_balance()
	_render_all_rows()
	_refresh_challenge()
	_refresh_upgrade_buttons()
	# 上次通关消息（v0.5：Game.last_clear 内存态、不入档；战斗胜利返回后重入显示）。
	# 展示在独立标签 last_clear_label，不占用 message_label（后者留给即时提示）。
	# v0.8：追加该关星级；v0.9：首通奖励明细含小钰碎片。
	if not Game.last_clear.is_empty():
		var lc: Dictionary = Game.last_clear
		var level: int = int(lc.get("level", 0))
		var star: int = int(Game.level_stars.get(level, 0))
		if bool(lc.get("first_clear", false)):
			var reward: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward", 0))
			var diamond: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward_diamond", 0))
			_last_clear_label.text = "上次通关：第 %d 关（首通）★%d\n首通奖励：金币 +%d 钻石 +%d 小钰碎片 ×%d" % [level, star, reward, diamond, _first_clear_frag(level)]
		else:
			_last_clear_label.text = "上次通关：第 %d 关（重复通关）★%d" % [level, star]
	# v0.8：章节星数宝箱提示（Game.chapter_chest_claimed 内存态；开启时随快照提示一次）
	if Game.chapter_chest_claimed:
		_message_label.text = "章节星数宝箱已开启！获得 %d 金币 + %d 钻石" % [Data.CHAPTER_CHEST_GOLD, Data.CHAPTER_CHEST_DIAMOND]


## 首通小钰碎片数（普通关 1 片 / 章节 BOSS 关 3 片；Data 常量，只读）
func _first_clear_frag(level: int) -> int:
	if int(Data.CHAPTERS.get(1, {}).get("boss_level", 0)) == level:
		return Data.XIAOYU_FRAGMENT_BOSS
	return Data.XIAOYU_FRAGMENT_FIRST_CLEAR
