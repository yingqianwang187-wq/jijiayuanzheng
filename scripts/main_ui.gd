# ==================================================================
# scripts/main_ui.gd —— 主界面脚本（挂在 scenes/Main.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.7 / §3.8 / §3.9 / §3.10 / §3.14（v0.17）、
#          scripts/contract.gd（只读）、docs/设计文档.md v0.21 §1.6 ①⑨
# 职责   ：主界面纯显示层。
#          - 连接信号：gold_changed / mech_girl_updated / level_cleared /
#            level_progress_changed / idle_rewards_updated / exp_balance_updated /
#            diamond_changed / fragments_updated / owned_mechs_updated / battle_star /
#            mech_star_updated / stamina_changed / box_count_changed / bag_updated /
#            box_opened / sign_changed / collection_changed
#          - 按钮只调入口（契约 §3.6）：收获 → Game.collect_idle()；挑战 → Game.start_battle(
#            Game.get_next_level())（v0.9 主线不可选关）+ 切 Battle.tscn；开箱 → Game.open_box()；
#            秘境/背包/装备/商城/设置/爬塔/任务/新手/抽卡/布阵 → 切对应场景；
#            签到 → Game.sign_in()；手动存档 → Save.save_game()
#          - 机娘列表（v0.17 §1.6 ⑨）：卡片式（头像色块 + 名 + 星级 + 战力），点击卡片 →
#            进 MechDetail.tscn（mech_id 经 static pending_mech_id 传递）；升级/升星按钮
#            迁移至详情页（§1.6 ⑨ 布局取舍，主界面保持纯卡片展示）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 首屏说明：本场景会从战斗场景切回（启动时那批初始信号已错过，Game 不重发），
#          故 _ready 对 Game 公开状态做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），
#          此后一切更新一律走信号。
# 右上角余额（契约 §3.7，v0.6）：金币余额 = 已入账金币 + 待收获金币；
#          经验余额 = 全局经验余额 + 待收获经验。随 gold_changed / idle_rewards_updated /
#          exp_balance_updated 与首屏快照刷新。
# 收集计数（v0.17 §3.14）：顶部"机娘收集 N/30"，数据源 Game.get_collection_info() 只读 +
#          collection_changed / owned_mechs_updated 信号。
# ==================================================================
extends Control

## 跨场景导航状态：机娘详情页当前要展示的机娘 id（UI 导航状态，非游戏数值）
static var pending_mech_id: StringName = &""

## ---- 节点引用（与 scenes/Main.tscn 结构一一对应）----
@onready var _gold_label: Label = $root_box/gold_label
@onready var _idle_rewards_label: Label = $root_box/idle_row/idle_rewards_label
@onready var _collect_button: Button = $root_box/idle_row/collect_button
@onready var _gold_balance_label: Label = $root_box/balance_row/gold_balance_label
@onready var _exp_balance_label: Label = $root_box/balance_row/exp_balance_label
@onready var _diamond_label: Label = $root_box/balance_row/diamond_label
@onready var _stamina_label: Label = $root_box/balance_row/stamina_label
@onready var _challenge_button: Button = $root_box/challenge_button
@onready var _mech_count_label: Label = $root_box/mech_count_label
@onready var _mech_box: ScrollContainer = $root_box/mech_box
@onready var _last_clear_label: Label = $root_box/last_clear_label
@onready var _message_label: Label = $root_box/message_label
@onready var _dungeon_button: Button = $root_box/feature_row/dungeon_button
@onready var _bag_button: Button = $root_box/feature_row/bag_button
@onready var _box_button: Button = $root_box/feature_row/box_button
@onready var _equipment_button: Button = $root_box/feature_row/equipment_button
@onready var _shop_button: Button = $root_box/feature_row/shop_button
@onready var _settings_button: Button = $root_box/feature_row/settings_button
@onready var _tower_button: Button = $root_box/feature_row2/tower_button
@onready var _task_button: Button = $root_box/feature_row2/task_button
@onready var _novice_button: Button = $root_box/feature_row2/novice_button
@onready var _sign_button: Button = $root_box/feature_row2/sign_button
@onready var _save_button: Button = $root_box/bottom_row/save_button
@onready var _gacha_button: Button = $root_box/bottom_row/gacha_button
@onready var _formation_button: Button = $root_box/bottom_row/formation_button
@onready var _collection_button: Button = $root_box/bottom_row/collection_button

## ---- UI 内部状态（仅卡片引用，不含任何游戏数值）----
var _mech_cards: Dictionary = {}      # StringName -> { name_label, info_label }


func _ready() -> void:
	Contract.gold_changed.connect(_on_gold_changed)
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
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
	Contract.sign_changed.connect(_on_sign_changed)
	Contract.collection_changed.connect(_on_collection_changed)
	_collect_button.pressed.connect(_on_collect_pressed)
	_challenge_button.pressed.connect(_on_enter_battle_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_gacha_button.pressed.connect(_on_gacha_pressed)
	_formation_button.pressed.connect(_on_formation_pressed)
	_collection_button.pressed.connect(_on_collection_pressed)
	_dungeon_button.pressed.connect(_on_dungeon_pressed)
	_bag_button.pressed.connect(_on_bag_pressed)
	_box_button.pressed.connect(_on_box_pressed)
	_equipment_button.pressed.connect(_on_equipment_pressed)
	_shop_button.pressed.connect(_on_shop_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_tower_button.pressed.connect(_on_tower_pressed)
	_task_button.pressed.connect(_on_task_pressed)
	_novice_button.pressed.connect(_on_novice_pressed)
	_sign_button.pressed.connect(_on_sign_pressed)
	_rebuild_mech_cards()
	_seed_initial_state()


## ------------------------------------------------------------------
## 信号处理（只刷新显示；余额随相关信号一并刷新）
## ------------------------------------------------------------------
func _on_gold_changed(value: int) -> void:
	_gold_label.text = "金币：%d" % value
	_refresh_balance()


func _on_idle_rewards_updated(gold: int, exp: int) -> void:
	# v0.6：待收获 = 金币 + 经验（挂机同产，参数以信号为准）
	_idle_rewards_label.text = "待收获：金币 +%d 经验 +%d" % [gold, exp]
	_refresh_balance()


func _on_mech_girl_updated(id: StringName, _hp: int, _atk: int, _level: int) -> void:
	# 机娘属性/战力变化 → 刷新卡片（战力读 Game.get_power 只读，信号到达时 Game 已更新）
	_render_mech_card(id)


func _on_exp_balance_updated(_balance: int) -> void:
	_refresh_balance()


func _on_diamond_changed(value: int) -> void:
	_diamond_label.text = "钻石：%d" % value


func _on_fragments_updated(_id: StringName, _count: int) -> void:
	# v0.7：碎片变化——刷新机娘列表（列表本身可能不变；升星入口已迁详情页）
	_rebuild_mech_cards()


func _on_owned_mechs_updated(_ids: Array) -> void:
	# v0.7：拥有列表变化（抽到新机娘）——重建机娘卡片 + 收集计数
	_rebuild_mech_cards()
	_refresh_mech_count()


func _on_mech_star_updated(id: StringName, _star: int, _level_cap: int) -> void:
	# v0.10：机娘升星——刷新卡片（星级/战力变化）
	_render_mech_card(id)


func _on_collection_changed(_count: int) -> void:
	# v0.17：图鉴收集进度变化
	_refresh_mech_count()


func _on_stamina_changed(value: int) -> void:
	_stamina_label.text = "体力 %d/%d" % [value, Data.STAMINA_MAX]


func _on_box_count_changed(count: int) -> void:
	_box_button.text = "开箱（%d）" % count
	_box_button.disabled = count <= 0


func _on_bag_updated(_items: Dictionary, _capacity: int) -> void:
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
	_message_label.text = "本关评价：%d 星！" % star


func _on_level_progress_changed(_level: int) -> void:
	_refresh_challenge()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_collect_pressed() -> void:
	Game.collect_idle()


func _on_enter_battle_pressed() -> void:
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
	get_tree().change_scene_to_file("res://scenes/Gacha.tscn")


func _on_formation_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Formation.tscn")


func _on_collection_pressed() -> void:
	# v0.17：进入图鉴界面
	get_tree().change_scene_to_file("res://scenes/Collection.tscn")


func _on_dungeon_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Dungeon.tscn")


func _on_bag_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Bag.tscn")


func _on_box_pressed() -> void:
	Game.open_box()


func _on_equipment_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Equipment.tscn")


func _on_shop_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Shop.tscn")


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Settings.tscn")


func _on_tower_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Tower.tscn")


func _on_task_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Task.tscn")


func _on_novice_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Novice.tscn")


func _on_sign_pressed() -> void:
	Game.sign_in()


func _on_sign_changed(days: int) -> void:
	if days % 7 == 0:
		_message_label.text = "签到成功！连续 %d 天，满 7 天额外奖励！" % days
	else:
		_message_label.text = "签到成功！连续 %d 天" % days
	_refresh_sign_button()


func _refresh_sign_button() -> void:
	var info: Dictionary = Game.get_sign_info()
	var days: int = int(info.get("days", 0))
	if bool(info.get("today_signed", false)):
		_sign_button.text = "已签到（连 %d 天）" % days
		_sign_button.disabled = true
	else:
		_sign_button.text = "签到（连 %d 天）" % days
		_sign_button.disabled = false


## ------------------------------------------------------------------
## 右上角余额（契约 §3.7，v0.6）：金币余额 = 已入账 + 待收获；经验余额 = 全局余额 + 待收获
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
## 机娘列表（v0.17 §1.6 ⑨ 卡片式）：头像色块 + 名字（★星级）+ 职业·稀有度 + 战力；
## 点击卡片 → MechDetail.tscn（mech_id 经 static pending_mech_id 传递）；
## 升级/升星按钮已迁移至详情页（本列表保持纯卡片展示）。
## 名单来自只读入口 Game.get_owned_mechs()（按 Data 顺序）；
## 重建时机：_ready 首屏 / owned_mechs_updated / fragments_updated
## ------------------------------------------------------------------
func _rebuild_mech_cards() -> void:
	for child in _mech_box.get_children():
		_mech_box.remove_child(child)
		child.queue_free()
	_mech_cards.clear()
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 6)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	for mech_id in Game.get_owned_mechs():
		grid.add_child(_make_mech_card(mech_id))
	inner.add_child(grid)
	_mech_box.add_child(inner)


func _make_mech_card(mech_id: StringName) -> Control:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var card := Panel.new()
	card.custom_minimum_size = Vector2(140, 92)
	# 头像色块（按稀有度着色）
	var avatar := ColorRect.new()
	avatar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	avatar.offset_bottom = 32.0
	avatar.color = _rarity_color(int(cfg.get("rarity", 0)))
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(avatar)
	# 名字（★N + 名字）
	var name_label := Label.new()
	name_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	name_label.offset_top = 36.0
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.text = "★%d %s" % [int(Game.mech_stars.get(mech_id, 1)), str(cfg.get("name", str(mech_id)))]
	card.add_child(name_label)
	# 信息（职业 · 稀有度 + 战力）
	var info_label := Label.new()
	info_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	info_label.offset_top = 54.0
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.add_theme_font_size_override("font_size", 11)
	info_label.text = "%s · %s\n战力 %s" % [_class_text(StringName(str(cfg.get("class", "")))), _rarity_text(int(cfg.get("rarity", 0))), _format_num(Game.get_power(mech_id))]
	card.add_child(info_label)
	# 点击层（进详情页）
	var click := Button.new()
	click.flat = true
	click.text = ""
	click.set_anchors_preset(Control.PRESET_FULL_RECT)
	click.pressed.connect(_on_mech_card_pressed.bind(mech_id))
	card.add_child(click)
	_mech_cards[mech_id] = { "name_label": name_label, "info_label": info_label }
	return card


## 刷新单张卡片（星级 / 战力；信号到达时 Game 已更新，只读重算）
func _render_mech_card(mech_id: StringName) -> void:
	var card: Dictionary = _mech_cards.get(mech_id, {})
	if card.is_empty():
		return
	var cfg: Dictionary = Data.MECH_GIRLS.get(mech_id, {})
	card.name_label.text = "★%d %s" % [int(Game.mech_stars.get(mech_id, 1)), str(cfg.get("name", str(mech_id)))]
	card.info_label.text = "%s · %s\n战力 %s" % [_class_text(StringName(str(cfg.get("class", "")))), _rarity_text(int(cfg.get("rarity", 0))), _format_num(Game.get_power(mech_id))]


func _on_mech_card_pressed(mech_id: StringName) -> void:
	# 经 static pending_mech_id 传递 mech_id 到详情页（UI 导航状态，非游戏数值）
	pending_mech_id = mech_id
	get_tree().change_scene_to_file("res://scenes/MechDetail.tscn")


## 收集计数（v0.17：Game.get_collection_info 只读 {count, total}）
func _refresh_mech_count() -> void:
	var info: Dictionary = Game.get_collection_info()
	_mech_count_label.text = "机娘收集 %d/%d" % [int(info.get("count", 0)), int(info.get("total", 0))]


## ------------------------------------------------------------------
## 首屏只读快照（契约 §3.1"首屏铺底例外"，见文件头"首屏说明"）
## ------------------------------------------------------------------
func _seed_initial_state() -> void:
	_gold_label.text = "金币：%d" % Game.gold
	_idle_rewards_label.text = "待收获：金币 +%d 经验 +%d" % [roundi(Game.idle_pending), roundi(Game.idle_pending_exp)]
	_diamond_label.text = "钻石：%d" % Game.diamond
	_stamina_label.text = "体力 %d/%d" % [Game.get_stamina(), Data.STAMINA_MAX]
	_on_box_count_changed(Game.get_box_count())
	_refresh_sign_button()
	_refresh_balance()
	_refresh_mech_count()
	_refresh_challenge()
	# 上次通关消息（v0.5：Game.last_clear 内存态、不入档；战斗胜利返回后重入显示）。
	# 展示在独立标签 last_clear_label，不占用 message_label（后者留给即时提示）。
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


## ------------------------------------------------------------------
## 文本工具（静态信息读 Data；动态值只来自信号 / 只读入口）
## ------------------------------------------------------------------
func _class_text(class_id: StringName) -> String:
	match class_id:
		&"tank": return "坦克"
		&"fighter": return "战士"
		&"assassin": return "刺客"
		&"archer": return "射手"
		&"mage": return "法师"
		&"support": return "辅助"
	return str(class_id)


func _rarity_text(r: int) -> String:
	match r:
		Data.Rarity.R:
			return "R"
		Data.Rarity.SR:
			return "SR"
		Data.Rarity.SSR:
			return "SSR"
	return "?"


func _rarity_color(rarity: int) -> Color:
	match rarity:
		Data.Rarity.SSR:
			return Color(1.0, 0.82, 0.35)
		Data.Rarity.SR:
			return Color(0.70, 0.52, 0.95)
	return Color(0.55, 0.68, 0.95)
