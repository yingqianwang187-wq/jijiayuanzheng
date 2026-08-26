# ==================================================================
# scripts/main_ui.gd —— 主界面外壳脚本（挂在 scenes/Main.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.7 / §3.8 / §3.9 / §3.10 / §3.14 / §3.15（v0.19）、
#          docs/设计文档.md v0.23 §1.4 页面切换机制 / §1.5 深蓝青科技风 / §1.6 ①③⑨⑩⑪⑱、
#          scripts/contract.gd（只读）
# 职责   ：主界面外壳（4U 架构）：
#          - 右上角常驻余额区（金币/经验/钻石/体力/指挥官，所有页面显示）
#          - 底部导航 6 图标（主城/布阵/主线/秘境/机娘/图鉴，主线居中）→ 整页切换
#          - 页面容器：6 主页面（主城/布阵/主线/秘境/机娘/图鉴）同屏一页不堆叠
#          - 二级界面（抽卡/商城/装备/背包/爬塔/任务/设置/活动/机娘详情）与战斗 = 覆盖层
#            （get_tree().root.add_child 实例化，叠加在当前页之上，返回 queue_free 关闭回原页）
#          - 新手引导层（遮罩+高亮+气泡），6 步自动切到目标页面并高亮目标按钮
#          - 连接信号：gold_changed / idle_rewards_updated / exp_balance_updated /
#            diamond_changed / stamina_changed / commander_changed / mech_girl_updated /
#            mech_star_updated / owned_mechs_updated / fragments_updated / collection_changed /
#            level_cleared / level_progress_changed / battle_star / box_count_changed /
#            bag_updated / box_opened / sign_changed / guide_changed
#          - 按钮只调入口（契约 §3.6）：收获 → Game.collect_idle()；开箱 → Game.open_box()；
#            签到 → Game.sign_in()；存档 → Save.save_game()；挑战 → Game.start_battle(
#            Game.get_next_level()) + 打开战斗覆盖层；其余入口 → 打开覆盖层/整页切换
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 首屏说明：本场景会从战斗/覆盖层返回（启动时那批初始信号已错过，Game 不重发），
#          故 _ready 对 Game 公开状态做一次【只读快照】铺首屏（契约 §3.1"首屏铺底例外"），
#          此后一切更新一律走信号。
# ==================================================================
extends Control

## 跨场景导航状态：机娘详情页当前要展示的机娘 id（UI 导航状态，非游戏数值）
static var pending_mech_id: StringName = &""

## 页面索引：0 主城 / 1 布阵 / 2 主线 / 3 秘境 / 4 机娘 / 5 图鉴
const PAGE_CITY := 0
const PAGE_FORMATION := 1
const PAGE_STORY := 2
const PAGE_DUNGEON := 3
const PAGE_MECH := 4
const PAGE_COLLECTION := 5

## ---- 节点引用（与 scenes/Main.tscn 结构一一对应）----
@onready var _gold_balance_label: Label = $shell_box/top_bar/top_row/gold_balance_label
@onready var _exp_balance_label: Label = $shell_box/top_bar/top_row/exp_balance_label
@onready var _diamond_label: Label = $shell_box/top_bar/top_row/diamond_label
@onready var _stamina_label: Label = $shell_box/top_bar/top_row/stamina_label
@onready var _commander_label: Label = $shell_box/top_bar/top_row/commander_label
@onready var _page_container: Control = $shell_box/page_container
@onready var _city_page: Control = $shell_box/page_container/city_page
@onready var _formation_page: Control = $shell_box/page_container/formation_page
@onready var _story_page: Control = $shell_box/page_container/story_page
@onready var _dungeon_page: Control = $shell_box/page_container/dungeon_page
@onready var _mech_page: Control = $shell_box/page_container/mech_page
@onready var _collection_page: Control = $shell_box/page_container/collection_page
# 主城页
@onready var _novice_button: Button = $shell_box/page_container/city_page/city_box/activity_row/novice_button
@onready var _task_button: Button = $shell_box/page_container/city_page/city_box/activity_row/task_button
@onready var _sign_button: Button = $shell_box/page_container/city_page/city_box/activity_row/sign_button
@onready var _activity_button: Button = $shell_box/page_container/city_page/city_box/activity_row/activity_button
@onready var _gacha_button: Button = $shell_box/page_container/city_page/city_box/building_grid/gacha_button
@onready var _shop_button: Button = $shell_box/page_container/city_page/city_box/building_grid/shop_button
@onready var _craft_button: Button = $shell_box/page_container/city_page/city_box/building_grid/craft_button
@onready var _tower_button: Button = $shell_box/page_container/city_page/city_box/building_grid/tower_button
# 右上角常驻（所有页面可点）
@onready var _settings_button: Button = $shell_box/top_bar/top_row/settings_button
@onready var _save_button: Button = $shell_box/top_bar/top_row/save_button
# 主线页（收获/开箱与挑战同页）
@onready var _idle_rewards_label: Label = $shell_box/page_container/story_page/story_box/idle_rewards_label
@onready var _collect_button: Button = $shell_box/page_container/story_page/story_box/story_action_row/collect_button
@onready var _box_button: Button = $shell_box/page_container/story_page/story_box/story_action_row/box_button
@onready var _challenge_button: Button = $shell_box/page_container/story_page/story_box/challenge_button
@onready var _story_progress_label: Label = $shell_box/page_container/story_page/story_box/story_progress_label
@onready var _story_last_clear_label: Label = $shell_box/page_container/story_page/story_box/story_last_clear_label
# 全局消息（壳层，所有页面可见）
@onready var _message_label: Label = $shell_box/message_label
# 机娘页
@onready var _mech_count_label: Label = $shell_box/page_container/mech_page/mech_box_panel/mech_count_label
@onready var _filter_all_button: Button = $shell_box/page_container/mech_page/mech_box_panel/filter_row/filter_all_button
@onready var _filter_r_button: Button = $shell_box/page_container/mech_page/mech_box_panel/filter_row/filter_r_button
@onready var _filter_sr_button: Button = $shell_box/page_container/mech_page/mech_box_panel/filter_row/filter_sr_button
@onready var _filter_ssr_button: Button = $shell_box/page_container/mech_page/mech_box_panel/filter_row/filter_ssr_button
@onready var _mech_box: ScrollContainer = $shell_box/page_container/mech_page/mech_box_panel/mech_box
# 底部导航
@onready var _nav_buttons: Array[Button] = [
	$shell_box/nav_bar/nav_row/nav_city_button,
	$shell_box/nav_bar/nav_row/nav_formation_button,
	$shell_box/nav_bar/nav_row/nav_story_button,
	$shell_box/nav_bar/nav_row/nav_dungeon_button,
	$shell_box/nav_bar/nav_row/nav_mech_button,
	$shell_box/nav_bar/nav_row/nav_collection_button,
]
# 引导层
@onready var _guide_layer: Control = $guide_layer
@onready var _guide_highlight: Panel = $guide_layer/guide_highlight
@onready var _guide_step_label: Label = $guide_layer/guide_bubble/bubble_box/guide_step_label
@onready var _guide_desc_label: Label = $guide_layer/guide_bubble/bubble_box/guide_desc_label
@onready var _guide_skip_button: Button = $guide_layer/guide_bubble/bubble_box/guide_button_row/guide_skip_button
@onready var _guide_next_button: Button = $guide_layer/guide_bubble/bubble_box/guide_button_row/guide_next_button
# 嵌入子页面内部节点（引导高亮用）
@onready var _formation_grid: GridContainer = $shell_box/page_container/formation_page/root_box/grid
@onready var _dungeon_list: VBoxContainer = $shell_box/page_container/dungeon_page/root_box/list_box

## ---- UI 内部状态（仅卡片/筛选/页签引用，不含任何游戏数值）----
var _mech_cards: Dictionary = {}      # StringName -> { card, name_label, info_label }
var _filter_rarity: int = -1          # -1 全部 / 0 R / 1 SR / 2 SSR


func _ready() -> void:
	Contract.gold_changed.connect(_on_gold_changed)
	Contract.idle_rewards_updated.connect(_on_idle_rewards_updated)
	Contract.exp_balance_updated.connect(_on_exp_balance_updated)
	Contract.diamond_changed.connect(_on_diamond_changed)
	Contract.stamina_changed.connect(_on_stamina_changed)
	Contract.commander_changed.connect(_on_commander_changed)
	Contract.mech_girl_updated.connect(_on_mech_girl_updated)
	Contract.mech_star_updated.connect(_on_mech_star_updated)
	Contract.owned_mechs_updated.connect(_on_owned_mechs_updated)
	Contract.fragments_updated.connect(_on_fragments_updated)
	Contract.collection_changed.connect(_on_collection_changed)
	Contract.level_cleared.connect(_on_level_cleared)
	Contract.level_progress_changed.connect(_on_level_progress_changed)
	Contract.battle_star.connect(_on_battle_star)
	Contract.box_count_changed.connect(_on_box_count_changed)
	Contract.bag_updated.connect(_on_bag_updated)
	Contract.box_opened.connect(_on_box_opened)
	Contract.sign_changed.connect(_on_sign_changed)
	Contract.guide_changed.connect(_on_guide_changed)
	# 导航
	for i in _nav_buttons.size():
		_nav_buttons[i].pressed.connect(_on_nav_pressed.bind(i))
	# 主城页
	_collect_button.pressed.connect(_on_collect_pressed)
	_box_button.pressed.connect(_on_box_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_novice_button.pressed.connect(_on_novice_pressed)
	_task_button.pressed.connect(_on_task_pressed)
	_sign_button.pressed.connect(_on_sign_pressed)
	_activity_button.pressed.connect(_on_activity_pressed)
	_gacha_button.pressed.connect(_on_gacha_pressed)
	_shop_button.pressed.connect(_on_shop_pressed)
	_craft_button.pressed.connect(_on_craft_pressed)
	_tower_button.pressed.connect(_on_tower_pressed)
	# 主线页
	_challenge_button.pressed.connect(_on_enter_battle_pressed)
	# 机娘页筛选
	_filter_all_button.pressed.connect(_on_filter_pressed.bind(-1))
	_filter_r_button.pressed.connect(_on_filter_pressed.bind(0))
	_filter_sr_button.pressed.connect(_on_filter_pressed.bind(1))
	_filter_ssr_button.pressed.connect(_on_filter_pressed.bind(2))
	# 引导层
	_guide_next_button.pressed.connect(_on_guide_next_pressed)
	_guide_skip_button.pressed.connect(_on_guide_skip_pressed)
	_apply_theme()
	_rebuild_mech_cards()
	_seed_initial_state()


## ------------------------------------------------------------------
## 深蓝 + 青科技风主题（§1.5：深蓝青主色、金黄副色；纯 UI 样式，非游戏数值）
## ------------------------------------------------------------------
func _apply_theme() -> void:
	# 顶栏 / 底栏底色
	var bar_style := StyleBoxFlat.new()
	bar_style.bg_color = Color(0.10, 0.16, 0.22)
	bar_style.border_color = Color(0.20, 0.55, 0.62)
	bar_style.set_border_width_all(1)
	$shell_box/top_bar.add_theme_stylebox_override("panel", bar_style)
	var nav_style := StyleBoxFlat.new()
	nav_style.bg_color = Color(0.08, 0.12, 0.17)
	nav_style.border_color = Color(0.20, 0.55, 0.62)
	nav_style.set_border_width_all(1)
	$shell_box/nav_bar.add_theme_stylebox_override("panel", nav_style)
	# 导航按钮：选中态青色
	var nav_on := StyleBoxFlat.new()
	nav_on.bg_color = Color(0.16, 0.42, 0.48)
	nav_on.set_corner_radius_all(4)
	var nav_hover := StyleBoxFlat.new()
	nav_hover.bg_color = Color(0.13, 0.30, 0.36)
	nav_hover.set_corner_radius_all(4)
	for btn in _nav_buttons:
		btn.add_theme_stylebox_override("normal", nav_hover)
		btn.add_theme_stylebox_override("hover", nav_hover)
		btn.add_theme_stylebox_override("pressed", nav_on)
		btn.add_theme_stylebox_override("hover_pressed", nav_on)
	# 主城建筑按钮：青色边框
	var building_style := StyleBoxFlat.new()
	building_style.bg_color = Color(0.10, 0.16, 0.22)
	building_style.border_color = Color(0.20, 0.55, 0.62)
	building_style.set_border_width_all(1)
	building_style.set_corner_radius_all(6)
	var building_hover := StyleBoxFlat.new()
	building_hover.bg_color = Color(0.14, 0.28, 0.34)
	building_hover.border_color = Color(0.35, 0.75, 0.82)
	building_hover.set_border_width_all(1)
	building_hover.set_corner_radius_all(6)
	for btn in [_gacha_button, _shop_button, _craft_button, _tower_button]:
		btn.add_theme_stylebox_override("normal", building_style)
		btn.add_theme_stylebox_override("hover", building_hover)
	# 主线按钮金色副色
	var story_style := StyleBoxFlat.new()
	story_style.bg_color = Color(0.28, 0.22, 0.08)
	story_style.border_color = Color(1.0, 0.82, 0.35)
	story_style.set_border_width_all(2)
	story_style.set_corner_radius_all(8)
	_challenge_button.add_theme_stylebox_override("normal", story_style)
	_nav_buttons[PAGE_STORY].text = "★ 主线 ★"


## ------------------------------------------------------------------
## 整页切换（v0.23 §1.4：同屏一页不堆叠）
## ------------------------------------------------------------------
func _on_nav_pressed(index: int) -> void:
	_switch_page(index)


func _switch_page(index: int) -> void:
	var pages: Array[Control] = [_city_page, _formation_page, _story_page, _dungeon_page, _mech_page, _collection_page]
	for i in pages.size():
		pages[i].visible = (i == index)
	for i in _nav_buttons.size():
		_nav_buttons[i].button_pressed = (i == index)


## ------------------------------------------------------------------
## 覆盖层打开（v0.23：二级界面/战斗叠加在当前页之上；关闭 = 覆盖层自身 queue_free）
## ------------------------------------------------------------------
func _open_overlay(path: String) -> void:
	var inst: Node = load(path).instantiate()
	get_tree().root.add_child(inst)


## ------------------------------------------------------------------
## 信号处理（只刷新显示；余额/指挥官随相关信号一并刷新）
## ------------------------------------------------------------------
func _on_gold_changed(_value: int) -> void:
	_refresh_balance()


func _on_idle_rewards_updated(gold: int, exp: int) -> void:
	_idle_rewards_label.text = "待收获：金币 +%d 经验 +%d" % [gold, exp]
	_refresh_balance()


func _on_exp_balance_updated(_balance: int) -> void:
	_refresh_balance()


func _on_diamond_changed(value: int) -> void:
	_diamond_label.text = "钻石：%d" % value


func _on_stamina_changed(value: int) -> void:
	_stamina_label.text = "体力 %d/%d" % [value, Data.STAMINA_MAX]


func _on_commander_changed(_level: int, _exp: int) -> void:
	_refresh_commander()


func _on_mech_girl_updated(id: StringName, _hp: int, _atk: int, _level: int) -> void:
	_render_mech_card(id)


func _on_mech_star_updated(id: StringName, _star: int, _level_cap: int) -> void:
	_render_mech_card(id)


func _on_owned_mechs_updated(_ids: Array) -> void:
	_rebuild_mech_cards()
	_refresh_mech_count()


func _on_fragments_updated(_id: StringName, _count: int) -> void:
	_rebuild_mech_cards()


func _on_collection_changed(_count: int) -> void:
	_refresh_mech_count()


func _on_level_cleared(level: int, first_clear: bool) -> void:
	if first_clear:
		var reward: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward", 0))
		var diamond: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward_diamond", 0))
		_message_label.text = "首通奖励：金币 +%d 钻石 +%d 小钰碎片 ×%d" % [reward, diamond, _first_clear_frag(level)]
	else:
		_message_label.text = "第 %d 关已通关" % level
	_refresh_story_progress()


func _on_level_progress_changed(_level: int) -> void:
	_refresh_challenge()
	_refresh_story_progress()


func _on_battle_star(star: int) -> void:
	_message_label.text = "本关评价：%d 星！" % star


func _on_box_count_changed(count: int) -> void:
	_box_button.text = "开箱（%d）" % count
	_box_button.disabled = count <= 0


func _on_bag_updated(_items: Dictionary, _capacity: int) -> void:
	pass


func _on_box_opened(reward: Dictionary) -> void:
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


func _on_sign_changed(days: int) -> void:
	if days % 7 == 0:
		_message_label.text = "签到成功！连续 %d 天，满 7 天额外奖励！" % days
	else:
		_message_label.text = "签到成功！连续 %d 天" % days
	_refresh_sign_button()


func _on_guide_changed(_step: int) -> void:
	_refresh_guide()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口 / 打开覆盖层 / 整页切换）
## ------------------------------------------------------------------
func _on_collect_pressed() -> void:
	Game.collect_idle()


func _on_box_pressed() -> void:
	Game.open_box()


func _on_save_pressed() -> void:
	Save.save_game()
	_message_label.text = "已保存"


func _on_settings_pressed() -> void:
	_open_overlay("res://scenes/Settings.tscn")


func _on_novice_pressed() -> void:
	# 新手福利不在覆盖层清单，整页切换（其返回会重载 Main 回主城页）
	get_tree().change_scene_to_file("res://scenes/Novice.tscn")


func _on_task_pressed() -> void:
	_open_overlay("res://scenes/Task.tscn")


func _on_sign_pressed() -> void:
	Game.sign_in()


func _on_activity_pressed() -> void:
	_open_overlay("res://scenes/Activity.tscn")


func _on_gacha_pressed() -> void:
	_open_overlay("res://scenes/Gacha.tscn")


func _on_shop_pressed() -> void:
	_open_overlay("res://scenes/Shop.tscn")


func _on_craft_pressed() -> void:
	_open_overlay("res://scenes/Equipment.tscn")


func _on_tower_pressed() -> void:
	_open_overlay("res://scenes/Tower.tscn")


func _on_enter_battle_pressed() -> void:
	var level: int = Game.get_next_level()
	if level < 1 or level > Data.MAX_LEVEL:
		_message_label.text = "主线已全部通关"
		return
	Game.start_battle(level)
	_open_overlay("res://scenes/Battle.tscn")


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
## 右上角常驻余额（契约 §3.7；所有页面显示）
## ------------------------------------------------------------------
func _refresh_balance() -> void:
	_gold_balance_label.text = "金币 %s (+%d)" % [_format_num(int(Game.gold)), roundi(Game.idle_pending)]
	_exp_balance_label.text = "经验 %s (+%d)" % [_format_num(int(Game.exp_balance)), roundi(Game.idle_pending_exp)]


func _refresh_commander() -> void:
	var info: Dictionary = Game.get_commander_info()
	_commander_label.text = "指挥官 Lv.%d 经验 %d/%d" % [int(info.get("level", 1)), int(info.get("exp", 0)), int(info.get("exp_next", 100))]


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
## 主线页（挑战 N 关 + 章节进度）
## ------------------------------------------------------------------
func _refresh_challenge() -> void:
	var next: int = Game.get_next_level()
	if next > Data.MAX_LEVEL:
		_challenge_button.text = "主线已全部通关"
		_challenge_button.disabled = true
	else:
		_challenge_button.text = "挑战第 %d 关" % next
		_challenge_button.disabled = false


func _refresh_story_progress() -> void:
	var cleared: int = Game.cleared_levels.size()
	var chapter: Dictionary = Data.CHAPTERS.get(1, {})
	_story_progress_label.text = "第 1 章：已通关 %d/%d 关" % [cleared, int(chapter.get("levels", Data.MAX_LEVEL))]
	if not Game.last_clear.is_empty():
		var lc: Dictionary = Game.last_clear
		var level: int = int(lc.get("level", 0))
		var star: int = int(Game.level_stars.get(level, 0))
		if bool(lc.get("first_clear", false)):
			var reward: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward", 0))
			var diamond: int = int(Data.LEVELS.get(level, {}).get("first_clear_reward_diamond", 0))
			_story_last_clear_label.text = "上次通关：第 %d 关（首通）★%d 奖励：金币+%d 钻石+%d 小钰碎片×%d" % [level, star, reward, diamond, _first_clear_frag(level)]
		else:
			_story_last_clear_label.text = "上次通关：第 %d 关（重复通关）★%d" % [level, star]


## ------------------------------------------------------------------
## 机娘页（§1.6 ⑨：计数/筛选 + 卡片 → 详情覆盖层）
## ------------------------------------------------------------------
func _on_filter_pressed(rarity: int) -> void:
	_filter_rarity = rarity
	_filter_all_button.button_pressed = (rarity == -1)
	_filter_r_button.button_pressed = (rarity == 0)
	_filter_sr_button.button_pressed = (rarity == 1)
	_filter_ssr_button.button_pressed = (rarity == 2)
	_rebuild_mech_cards()


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
		if _filter_rarity >= 0 and int(Data.MECH_GIRLS[mech_id].get("rarity", 0)) != _filter_rarity:
			continue
		grid.add_child(_make_mech_card(mech_id))
	inner.add_child(grid)
	_mech_box.add_child(inner)


func _make_mech_card(mech_id: StringName) -> Control:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var card := Panel.new()
	card.custom_minimum_size = Vector2(140, 92)
	var avatar := ColorRect.new()
	avatar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	avatar.offset_bottom = 32.0
	avatar.color = _rarity_color(int(cfg.get("rarity", 0)))
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(avatar)
	var name_label := Label.new()
	name_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	name_label.offset_top = 36.0
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.text = "★%d %s" % [int(Game.mech_stars.get(mech_id, 1)), str(cfg.get("name", str(mech_id)))]
	card.add_child(name_label)
	var info_label := Label.new()
	info_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	info_label.offset_top = 54.0
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.add_theme_font_size_override("font_size", 11)
	info_label.text = "%s · %s\n战力 %s" % [_class_text(StringName(str(cfg.get("class", "")))), _rarity_text(int(cfg.get("rarity", 0))), _format_num(Game.get_power(mech_id))]
	card.add_child(info_label)
	var click := Button.new()
	click.flat = true
	click.text = ""
	click.set_anchors_preset(Control.PRESET_FULL_RECT)
	click.pressed.connect(_on_mech_card_pressed.bind(mech_id))
	card.add_child(click)
	_mech_cards[mech_id] = { "card": card, "name_label": name_label, "info_label": info_label }
	return card


func _render_mech_card(mech_id: StringName) -> void:
	var card: Dictionary = _mech_cards.get(mech_id, {})
	if card.is_empty():
		return
	var cfg: Dictionary = Data.MECH_GIRLS.get(mech_id, {})
	card.name_label.text = "★%d %s" % [int(Game.mech_stars.get(mech_id, 1)), str(cfg.get("name", str(mech_id)))]
	card.info_label.text = "%s · %s\n战力 %s" % [_class_text(StringName(str(cfg.get("class", "")))), _rarity_text(int(cfg.get("rarity", 0))), _format_num(Game.get_power(mech_id))]


func _on_mech_card_pressed(mech_id: StringName) -> void:
	pending_mech_id = mech_id
	_open_overlay("res://scenes/MechDetail.tscn")


func _refresh_mech_count() -> void:
	var info: Dictionary = Game.get_collection_info()
	_mech_count_label.text = "机娘收集 %d/%d" % [int(info.get("count", 0)), int(info.get("total", 0))]


## ------------------------------------------------------------------
## 新手引导层（6 步自动切到目标页面并高亮目标按钮）
## ------------------------------------------------------------------
func _refresh_guide() -> void:
	var info: Dictionary = Game.get_guide_info()
	var step: int = int(info.get("step", 0))
	if bool(info.get("done", false)) or bool(info.get("skipped", false)):
		_guide_layer.visible = false
		return
	var steps: Array = Data.GUIDE_STEPS
	if step < 0 or step >= steps.size():
		_guide_layer.visible = false
		return
	var cfg: Dictionary = steps[step]
	var total: int = int(info.get("total", steps.size()))
	_guide_step_label.text = "第 %d/%d 步 · %s" % [step + 1, total, str(cfg.get("name", ""))]
	_guide_desc_label.text = str(cfg.get("desc", ""))
	var target: Dictionary = _guide_target(step)
	if not target.is_empty():
		_switch_page(int(target.page))
		var control: Control = target.control
		if control != null:
			var r: Rect2 = control.get_global_rect()
			_guide_highlight.position = r.position
			_guide_highlight.size = r.size
			_guide_highlight.visible = true
	else:
		_guide_highlight.visible = false
	_guide_layer.visible = true


## 当前步目标 {page, control}（收获/升级/挑战/抽卡/布阵/秘境；引导自动切到对应页）
func _guide_target(step: int) -> Dictionary:
	match step:
		0:
			# 收获按钮在主线页（#31 调整）
			return { "page": PAGE_STORY, "control": _collect_button }
		1:
			if _mech_cards.is_empty():
				return { "page": PAGE_MECH, "control": _mech_box }
			var first_id: StringName = _mech_cards.keys()[0]
			return { "page": PAGE_MECH, "control": _mech_cards[first_id].get("card", _mech_box) }
		2:
			return { "page": PAGE_STORY, "control": _challenge_button }
		3:
			return { "page": PAGE_CITY, "control": _gacha_button }
		4:
			return { "page": PAGE_FORMATION, "control": _formation_grid }
		5:
			return { "page": PAGE_DUNGEON, "control": _dungeon_list }
	return {}


func _on_guide_next_pressed() -> void:
	Game.guide_next()


func _on_guide_skip_pressed() -> void:
	Game.guide_skip()


## ------------------------------------------------------------------
## 首屏只读快照（契约 §3.1"首屏铺底例外"）
## ------------------------------------------------------------------
func _seed_initial_state() -> void:
	_switch_page(PAGE_CITY)
	_idle_rewards_label.text = "待收获：金币 +%d 经验 +%d" % [roundi(Game.idle_pending), roundi(Game.idle_pending_exp)]
	_diamond_label.text = "钻石：%d" % Game.diamond
	_stamina_label.text = "体力 %d/%d" % [Game.get_stamina(), Data.STAMINA_MAX]
	_on_box_count_changed(Game.get_box_count())
	_refresh_sign_button()
	_refresh_balance()
	_refresh_commander()
	_refresh_mech_count()
	_refresh_challenge()
	_refresh_story_progress()
	_refresh_guide()


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
