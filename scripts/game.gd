# ==================================================================
# scripts/game.gd —— 自动战斗 + 挂机金币 + 升级养成（Game）
# 作者   ：B（数值 + 玩法 + 存档）
# 依据   ：docs/契约.md §3.1 / §3.4 / §3.5 / §3.6、scripts/data.gd、scripts/save.gd、
#          scripts/contract.gd（只读）
# 职责   ：当前状态与规则逻辑；把 Data 的静态数值变成"当前值"。
# 铁律   ：本文件是【唯一改数值者】与【唯一 emit 信号者】（契约 §3.1 / §3.5）。
#          一切状态变化必须通过 Contract 信号通知；UI 只 connect，Save 只读写档。
# 自动加载：本文件注册为名为 Game 的 autoload（注册顺序 Contract → Data → Save → Game，
#          后注册可调用先注册的：Game → Data / Save / Contract）。
# 依赖   ：Contract（信号）、Data（数值表）、Save（存档）。
# 变更规则：改本文件不涉及契约文档；但若需新增信号 / 入口，先向总指挥 A 提变更申请。
# ==================================================================
extends Node

## ---------------------------------------------------------------
## 当前状态（唯一事实来源；只允许本文件修改）
## ---------------------------------------------------------------
var gold: int = 0
var unlocked_level: int = 1                     # 已解锁的最高关卡（初始 = 第 1 关）
var mech_levels: Dictionary = {}                # { StringName id: int level }
var mech_stars: Dictionary = {}                 # { StringName id: int star } 机娘星级（1~10，v0.10）
var cleared_levels: Dictionary = {}             # { int level: true } 已首通关卡（内存态）

## 挂机"点一下收获，同产金币+经验"（契约 §1.2 / §3.2，v0.4 / v0.6）
var idle_pending: float = 0.0                   # 待收获金币（浮点精确累计，显示/入账取整）
var idle_pending_exp: float = 0.0               # 待收获经验（= 待收获金币 × Data.IDLE_EXP_RATIO，v0.6）
var idle_last_time: int = 0                     # 上次结算时间戳（unix 秒；在线每秒推进，离线按"现在-上次"补入）
var _idle_save_accum: float = 0.0               # 节流存档计时（秒）

## 全局经验余额（契约 §1.2 / §3.2，v0.6）：只接收挂机经验（随"收获"入账），
## 战斗经验进个人条；升级时个人条不足自动从余额补
var exp_balance: int = 0

## 阶段 1 抽卡状态（契约 §3.8，v0.7）
var diamond: int = 0                              # 钻石（首通奖励 / 抽卡消耗）
var summon_ticket: int = 0                        # 召唤券（等价钻石；阶段 2 启用来源，先存字段）
var fragments: Dictionary = {}                    # { StringName id: int } 机娘碎片计数（重复机娘转化）
var owned_mechs: Dictionary = {}                  # { StringName id: true } 已拥有机娘
var pity: int = 0                                 # SSR 保底计数（全局，每 80 抽必出 SSR，出 SSR 重置）
var novice_free_pull: bool = true                 # 开局免费十连是否可用（首次十连免钻石）
var novice_pool_left: int = 5                     # 新手池半价剩余次数（初始 = Data.SUMMON_NOVICE_POOL_LEFT = 5）
var novice_first_ten_done: bool = false           # 新手池首十连保底（必出星澜）是否已触发

## 战斗 2.0 状态（契约 §3.9，v0.8）
var formation: Array = []                         # 当前阵型：[{id, row, col}]（3x3 九宫格选 ≤5）
var formation_presets: Dictionary = {}            # { index: Array } 阵型预设（2~3 套）
var level_stars: Dictionary = {}                  # { int level: int star } 每关最高星级（1~3）
var cleared_boss: Dictionary = {}                 # { int level: true } 已通关的章节 BOSS 关
var chapter_chest_claimed: bool = false           # 章节星数宝箱是否已领（第 1 章；不入契约字段清单，防重复领取）
var accelerate: bool = false                      # 战斗 2x 加速开关（内存态，不入档）

## 阶段 3：体力 / 秘境 / 背包 / 开箱（契约 §3.10，v0.13）
var stamina: int = Data.STAMINA_MAX               # 体力（上限 100，满上限停止恢复）
var stamina_last_time: int = 0                    # 上次体力恢复结算时间戳
var stamina_buy_count: int = 0                    # 当日买体力次数（跨日重置）
var last_reset_day: String = ""                   # 上次每日重置日期（本地日期 YYYY-MM-DD）
var dungeon_cleared: Dictionary = {}              # {kind: {tier: true}} 秘境通关记录
var dungeon_attempted: Dictionary = {}            # {kind: {tier: true}} 秘境挑战记录（内存态：首免判定，不入档）
var bag: Dictionary = { "items": {}, "capacity": Data.BAG_START_CAPACITY }  # 背包 {items:{item_id:count}, capacity}
var boxes: int = 0                                # 待开箱数

## v0.14：装备 / 宝石
var equip_inventory: Array = []                   # 装备库 [{uid, slot, star(1~5), level(0~10), gems:[{quality, affixes:[{stat,value}]}]}]
var equipped: Dictionary = {}                     # 穿戴 {mech_id: {slot: uid}}
var gem_stock: Dictionary = {}                    # 宝石库存 {quality_name: count}
var _equip_uid_seed: int = 1                      # 装备 uid 自增种子（load 后扫描库存续号）

## v0.15：设置 / 商城
var settings: Dictionary = {}                     # 设置 {music_on, sfx_on, music_volume, sfx_volume, default_2x, language}
var shop_day: String = ""                         # 上次商城刷新日（本地日期；跨日清已购）
var shop_bought: Dictionary = {}                  # 当日已购 {item_id: true}（每商品每日限购 1 次）

## v0.16：爬塔 / 签到 / 任务 / 新手
var tower_highest: int = 0                        # 爬塔最高层
var tower_daily_count: int = 0                    # 当日已爬层数（每日 30 层上限，跨日重置）
var sign_days: int = 0                            # 签到连续天数（断签归 0）
var sign_last_day: String = ""                    # 上次签到日
var task_daily: Dictionary = { "progress": {}, "claimed": [] }    # 每日任务 {progress:{task_id:count}, claimed:[tier]}
var task_weekly: Dictionary = { "progress": {}, "claimed": [] }   # 每周任务（每周一重置）
var novice_progress: Dictionary = {}              # 新手 7 日进度 {day: {task_id: count}}
var novice_claimed: Array = []                    # 已领新手奖励的天 [day]

## v0.17：图鉴 / 成就 / 称号 / 好感
var collection_rewards_claimed: Array = []        # 已领图鉴档位 [10/20/30]
var achievements_claimed: Array = []              # 已领成就 [StringName id]
var titles_unlocked: Array = []                   # 已解锁称号 [StringName id]
var title_equipped: StringName = &""              # 当前佩戴称号（空 = 未佩戴）
var affinity: Dictionary = {}                     # 好感 {mech_id: int 0~100}
var _total_summon_count: int = 0                  # 累计抽卡次数（成就 progress 用；入档）

## v0.18：指挥官 / 引导 / 活动
var commander_exp: int = 0                        # 指挥官经验
var commander_level: int = 1                      # 指挥官等级（初始 1）
var commander_ten_rewarded: int = 0               # 已发免费十连的档位（每 5 级 +10 券，一次性）
var guide_step: int = 0                           # 引导步数 0~6（6 = 完成）
var guide_skipped: bool = false                   # 引导是否跳过
var activity_claimed: Array = []                  # 已领活动 [StringName id]

## v0.20：限定池 / 皮肤 / 每日 BOSS
var limited_pity: int = 0                         # 限定池独立 SSR 保底计数（80 抽必出，跨期保留）
var skins_unlocked: Array = []                    # 已解锁皮肤 [StringName id]
var skin_equipped: Dictionary = {}                # 穿戴 {mech_id: skin_id}
var daily_boss: Dictionary = { "day": "", "damage": 0, "reward_claimed": -1 }  # 每日 BOSS {day, damage, reward_claimed}

## v0.21：远征 / 生存 / 家园
var expedition: Dictionary = {}                   # 远征 {mech_id: {task_id: StringName, end_time: int}}（end_time = 到期 unix 秒）
var survival: Dictionary = { "day": "", "best_waves": 0, "reward_claimed": -1 }  # 生存 {day, best_waves, reward_claimed}
var home_interact: Dictionary = {}                # 家园互动 {mech_id: {day: String, count: int}}（每日次数）

## v0.22：转盘 / 节日活动
var spin: Dictionary = { "day": "", "free_used": false }   # 转盘 {day, free_used}（免费次数跨日重置）
var festival_claimed: Dictionary = {}             # 节日活动已领 {festival_id: true}

## 当前战斗状态（非战斗时 active = false）
var battle: Dictionary = {
	"level": 1,
	"tick": 0,
	"active": false,
	"mode": &"story",           # 战斗模式：story 主线 / dungeon 秘境（v0.13）
	"dungeon_ctx": {},          # 秘境上下文：{kind, tier, cost}（v0.13）
	"wave": 1,
	"total_waves": 1,
	"mechs": [],        # 我方单位 [{ side, id, name, class, row, col, hp, max_hp, atk, def, spd, energy, cd_1, cd_2, statuses, buffs, shield, taunt_turns, dodge_crit_ready, alive, dmg_dealt, heal_done, level, cfg }]
	"enemies": [],      # 当前波敌方单位（结构同上 + tier/ultimate）
	"pending_waves": [],# 未出场的敌方波配置（LEVELS[level].waves 的副本，已出场波移除）
	"deaths": 0,        # 我方阵亡数（星级评价用）
	"mech_ids": [],     # 我方上阵机娘 id（经验发放用）
	"accelerate": false,
	"survival_wave": 1, # 生存模式当前波数（v0.21；其余模式不用）
}

var idle_timer: Timer
var battle_timer: Timer

## 上次通关信息（内存态，不入档、不持久化；契约 §3.6 v0.5，供主界面快照显示）
## 形状：{ level: int, first_clear: bool, reward: int }（reward = 本局实际发放的首通金币奖励，非首通为 0）
var last_clear: Dictionary = {}

## 启动：读档 → 建节拍 → 等 UI connect 后发初始状态信号
func _ready() -> void:
	_load_initial_state()
	_setup_timers()
	# autoload 先于主场景 _ready；等一帧再发初始信号，确保 main_ui 已 connect 信号
	await get_tree().process_frame
	_emit_initial_state()

## 读档初始化（契约 §3.6：Game → Save.load_game；失败由 Save 返回默认值）
## 含挂机离线补入：按"现在 - 上次结算时间"× 每秒产出累计待收获金币与经验（契约 §1.2，v0.4 / v0.6）
func _load_initial_state() -> void:
	var data: Dictionary = Save.load_game()
	gold = maxi(int(data.get("gold", 0)), 0)
	exp_balance = maxi(int(data.get("exp_balance", 0)), 0)
	unlocked_level = clampi(int(data.get("unlocked_level", 1)), 1, Data.MAX_LEVEL)
	# 阶段 1 抽卡状态恢复（契约 §3.8，v0.7）
	diamond = maxi(int(data.get("diamond", 0)), 0)
	summon_ticket = maxi(int(data.get("summon_ticket", 0)), 0)
	pity = clampi(int(data.get("pity", 0)), 0, Data.SUMMON_PITY_SSR_LIMIT)
	novice_free_pull = bool(data.get("novice_free_pull", true))
	novice_pool_left = maxi(int(data.get("novice_pool_left", Data.SUMMON_NOVICE_POOL_LEFT)), 0)
	novice_first_ten_done = bool(data.get("novice_first_ten_done", false))
	fragments.clear()
	var fragments_data: Dictionary = data.get("fragments", {})
	for key in fragments_data:
		var frag_id := StringName(str(key))
		if Data.MECH_GIRLS.has(frag_id):
			fragments[frag_id] = maxi(int(fragments_data[key]), 0)
	# 拥有恢复：默认开局 2 位（Data.START_MECHS）+ 存档拥有；只认 Data 中存在的机娘
	owned_mechs.clear()
	for mech_id in Data.START_MECHS:
		owned_mechs[mech_id] = true
	var owned_data: Dictionary = data.get("owned_mechs", {})
	for key in owned_data:
		var mid := StringName(str(key))
		if Data.MECH_GIRLS.has(mid):
			owned_mechs[mid] = true
	# 成长状态只建"已拥有"机娘（未拥有无等级/星级；抽到新机娘时再初始化）
	mech_levels.clear()
	mech_stars.clear()
	for mech_id in _owned_mech_ids():
		mech_levels[mech_id] = 1
		mech_stars[mech_id] = 1
	var mechs: Dictionary = data.get("mechs", {})
	for key in mechs:
		var mech_id := StringName(str(key))
		if Data.MECH_GIRLS.has(mech_id) and owned_mechs.has(mech_id):
			var entry: Dictionary = mechs[key]
			mech_levels[mech_id] = maxi(int(entry.get("level", 1)), 1)
			# 星级（v0.10）：旧档无此字段 → 默认 1
			mech_stars[mech_id] = clampi(int(entry.get("star", 1)), 1, Data.MAX_STAR)
	# 首通记录恢复：直接读存档 first_cleared（契约 §3.2）
	cleared_levels.clear()
	for l in data.get("first_cleared", []):
		cleared_levels[int(l)] = true
	# 挂机待收获（金币+经验）：读档值 + 离线时长补入（离线期间照常累计）
	idle_pending = maxf(float(data.get("idle_pending", 0)), 0.0)
	idle_pending_exp = maxf(float(data.get("idle_pending_exp", 0)), 0.0)
	idle_last_time = int(data.get("idle_last_time", int(Time.get_unix_time_from_system())))
	var now: int = int(Time.get_unix_time_from_system())
	var elapsed: float = maxf(float(now - idle_last_time), 0.0)
	# 离线收益上限 12 小时（设计文档 §8.4 / 附录 B，v0.14）
	var elapsed_capped: float = minf(elapsed, Data.IDLE_OFFLINE_CAP_HOURS * 3600.0)
	if elapsed_capped > 0.0:
		idle_pending += elapsed_capped * _idle_gold_rate()
		idle_pending_exp += elapsed_capped * _idle_gold_rate() * Data.IDLE_EXP_RATIO
		idle_last_time = now
	# 战斗 2.0 状态恢复（契约 §3.9，v0.8）
	formation = []
	var formation_data: Variant = data.get("formation", [])
	if formation_data is Array:
		for slot in formation_data:
			if slot is Dictionary and owned_mechs.has(StringName(str(slot.get("id", "")))):
				formation.append({
					"id": StringName(str(slot.get("id", ""))),
					"row": clampi(int(slot.get("row", 0)), 0, 2),
					"col": clampi(int(slot.get("col", 0)), 0, 2),
				})
	if formation.size() < 2:
		_ensure_default_formation()
	formation_presets.clear()
	var presets_data: Variant = data.get("formation_presets", {})
	if presets_data is Dictionary:
		for key in presets_data:
			var preset: Variant = presets_data[key]
			if preset is Array:
				var preset_result: Array = []
				for slot in preset:
					if slot is Dictionary and owned_mechs.has(StringName(str(slot.get("id", "")))):
						preset_result.append({
							"id": StringName(str(slot.get("id", ""))),
							"row": clampi(int(slot.get("row", 0)), 0, 2),
							"col": clampi(int(slot.get("col", 0)), 0, 2),
						})
				if not preset_result.is_empty():
					formation_presets[str(key)] = preset_result
	level_stars.clear()
	var stars_data: Variant = data.get("level_stars", {})
	if stars_data is Dictionary:
		for key in stars_data:
			var level := int(key)
			if level >= 1 and level <= Data.MAX_LEVEL:
				level_stars[level] = clampi(int(stars_data[key]), 1, 3)
	cleared_boss.clear()
	var boss_data: Variant = data.get("cleared_boss", {})
	if boss_data is Dictionary:
		for key in boss_data:
			var level := int(key)
			if level >= 1 and level <= Data.MAX_LEVEL:
				cleared_boss[level] = true
	chapter_chest_claimed = bool(data.get("chapter_chest_claimed", false))
	# —— v0.13：体力 / 秘境 / 背包 / 开箱 ——
	stamina = clampi(int(data.get("stamina", Data.STAMINA_MAX)), 0, Data.STAMINA_MAX)
	stamina_last_time = int(data.get("stamina_last_time", int(Time.get_unix_time_from_system())))
	stamina_buy_count = maxi(int(data.get("stamina_buy_count", 0)), 0)
	last_reset_day = str(data.get("last_reset_day", Time.get_date_string_from_system()))
	dungeon_cleared.clear()
	var dungeon_data: Variant = data.get("dungeon_cleared", {})
	if dungeon_data is Dictionary:
		for kind in dungeon_data:
			var tier_map: Variant = dungeon_data[kind]
			if tier_map is Dictionary:
				dungeon_cleared[str(kind)] = {}
				for tier in tier_map:
					dungeon_cleared[str(kind)][str(tier)] = true
	dungeon_attempted.clear()
	bag = { "items": {}, "capacity": Data.BAG_START_CAPACITY }
	var bag_data: Variant = data.get("bag", {})
	if bag_data is Dictionary:
		bag["capacity"] = clampi(int(bag_data.get("capacity", Data.BAG_START_CAPACITY)), 0, Data.BAG_MAX_CAPACITY)
		var bag_items: Variant = bag_data.get("items", {})
		if bag_items is Dictionary:
			for item_key in bag_items:
				if Data.ITEMS.has(StringName(str(item_key))):
					bag["items"][str(item_key)] = maxi(int(bag_items[item_key]), 0)
	boxes = maxi(int(data.get("boxes", 0)), 0)
	# —— v0.14：装备 / 宝石 ——
	equip_inventory = []
	var eq_data: Variant = data.get("equip_inventory", [])
	if eq_data is Array:
		for eq in eq_data:
			if eq is Dictionary and Data.EQUIP_SLOTS.has(StringName(str(eq.get("slot", "")))):
				var eq_load := {
					"uid": StringName(str(eq.get("uid", ""))),
					"slot": StringName(str(eq.get("slot", ""))),
					"star": clampi(int(eq.get("star", 1)), 1, 5),
					"level": clampi(int(eq.get("level", 0)), 0, Data.ENCHANT_MAX_LEVEL),
					"gems": [],
				}
				var eq_gems: Variant = eq.get("gems", [])
				if eq_gems is Array:
					for g in eq_gems:
						if g is Dictionary and StringName(str(g.get("quality", ""))) in Data.GEM_QUALITIES:
							eq_load["gems"].append({
								"quality": StringName(str(g.get("quality", ""))),
								"affixes": g.get("affixes", []),
							})
				equip_inventory.append(eq_load)
	equipped.clear()
	var equipped_data: Variant = data.get("equipped", {})
	if equipped_data is Dictionary:
		for mech_id in equipped_data:
			var slot_map: Variant = equipped_data[mech_id]
			if slot_map is Dictionary and owned_mechs.has(StringName(str(mech_id))):
				equipped[StringName(str(mech_id))] = {}
				for slot_key in slot_map:
					equipped[StringName(str(mech_id))][StringName(str(slot_key))] = StringName(str(slot_map[slot_key]))
	gem_stock.clear()
	var gem_data: Variant = data.get("gem_stock", {})
	if gem_data is Dictionary:
		for q in gem_data:
			if StringName(str(q)) in Data.GEM_QUALITIES:
				gem_stock[StringName(str(q))] = maxi(int(gem_data[q]), 0)
	_init_equip_uid_seed()
	# —— v0.15：设置 / 商城 ——
	settings = {}
	var settings_data: Variant = data.get("settings", {})
	if settings_data is Dictionary:
		for key in Data.SETTINGS_KEYS:
			var key_str: String = str(key)
			if settings_data.has(key_str):
				settings[key_str] = settings_data[key_str]
			else:
				settings[key_str] = Data.SETTINGS_DEFAULTS[key]
	else:
		for key in Data.SETTINGS_KEYS:
			settings[str(key)] = Data.SETTINGS_DEFAULTS[key]
	shop_day = str(data.get("shop_day", Time.get_date_string_from_system()))
	shop_bought.clear()
	var shop_bought_data: Variant = data.get("shop_bought", {})
	if shop_bought_data is Dictionary:
		for item_id in shop_bought_data:
			if Data.SHOP_ITEMS.has(StringName(str(item_id))):
				shop_bought[str(item_id)] = true
	# —— v0.16：爬塔 / 签到 / 任务 / 新手 ——
	tower_highest = maxi(int(data.get("tower_highest", 0)), 0)
	tower_daily_count = maxi(int(data.get("tower_daily_count", 0)), 0)
	sign_days = maxi(int(data.get("sign_days", 0)), 0)
	sign_last_day = str(data.get("sign_last_day", ""))
	task_daily = { "progress": {}, "claimed": [] }
	task_weekly = { "progress": {}, "claimed": [] }
	_load_task_store(task_daily, data.get("task_daily", {}))
	_load_task_store(task_weekly, data.get("task_weekly", {}))
	novice_progress.clear()
	var novice_prog_data: Variant = data.get("novice_progress", {})
	if novice_prog_data is Dictionary:
		for day in novice_prog_data:
			var day_map: Variant = novice_prog_data[day]
			if day_map is Dictionary:
				novice_progress[str(day)] = {}
				for task_id in day_map:
					novice_progress[str(day)][str(task_id)] = maxi(int(day_map[task_id]), 0)
	novice_claimed = []
	var novice_claimed_data: Variant = data.get("novice_claimed", [])
	if novice_claimed_data is Array:
		for day in novice_claimed_data:
			var d := int(day)
			if d >= 1 and d <= 7:
				novice_claimed.append(d)
	# —— v0.17：图鉴 / 成就 / 称号 / 好感 ——
	collection_rewards_claimed = []
	var col_claimed_data: Variant = data.get("collection_rewards_claimed", [])
	if col_claimed_data is Array:
		for t in col_claimed_data:
			var tier := int(t)
			if Data.COLLECTION_REWARDS.has(tier):
				collection_rewards_claimed.append(tier)
	achievements_claimed = []
	var ach_claimed_data: Variant = data.get("achievements_claimed", [])
	if ach_claimed_data is Array:
		for a in ach_claimed_data:
			var aid := StringName(str(a))
			if Data.ACHIEVEMENTS.has(aid):
				achievements_claimed.append(aid)
	titles_unlocked = []
	var titles_data: Variant = data.get("titles_unlocked", [])
	if titles_data is Array:
		for t2 in titles_data:
			var tid := StringName(str(t2))
			if Data.TITLES.has(tid):
				titles_unlocked.append(tid)
	title_equipped = &""
	var title_equipped_data: Variant = data.get("title_equipped", "")
	if StringName(str(title_equipped_data)) != &"" and Data.TITLES.has(StringName(str(title_equipped_data))):
		title_equipped = StringName(str(title_equipped_data))
	affinity.clear()
	var affinity_data: Variant = data.get("affinity", {})
	if affinity_data is Dictionary:
		for mech_id in affinity_data:
			if Data.MECH_GIRLS.has(StringName(str(mech_id))):
				affinity[StringName(str(mech_id))] = clampi(int(affinity_data[mech_id]), 0, Data.AFFINITY_MAX)
	_total_summon_count = maxi(int(data.get("total_summon_count", 0)), 0)
	# —— v0.18：指挥官 / 引导 / 活动 ——
	commander_exp = maxi(int(data.get("commander_exp", 0)), 0)
	commander_level = maxi(int(data.get("commander_level", 1)), 1)
	commander_ten_rewarded = maxi(int(data.get("commander_ten_rewarded", 0)), 0)
	guide_step = clampi(int(data.get("guide_step", 0)), 0, Data.GUIDE_STEPS.size())
	guide_skipped = bool(data.get("guide_skipped", false))
	activity_claimed = []
	var activity_data: Variant = data.get("activity_claimed", [])
	if activity_data is Array:
		for a in activity_data:
			var aid := StringName(str(a))
			if Data.ACTIVITIES.has(aid):
				activity_claimed.append(aid)
	# —— v0.20：限定池 / 皮肤 / 每日 BOSS ——
	limited_pity = clampi(int(data.get("limited_pity", 0)), 0, Data.SUMMON_PITY_SSR_LIMIT)
	skins_unlocked = []
	var skins_data: Variant = data.get("skins_unlocked", [])
	if skins_data is Array:
		for s in skins_data:
			var sid := StringName(str(s))
			if Data.SKINS.has(sid):
				skins_unlocked.append(sid)
	skin_equipped.clear()
	var skin_eq_data: Variant = data.get("skin_equipped", {})
	if skin_eq_data is Dictionary:
		for mech_id in skin_eq_data:
			var sid2 := StringName(str(skin_eq_data[mech_id]))
			if Data.SKINS.has(sid2) and Data.MECH_GIRLS.has(StringName(str(mech_id))):
				skin_equipped[StringName(str(mech_id))] = sid2
	var daily_boss_data: Variant = data.get("daily_boss", {})
	if daily_boss_data is Dictionary:
		daily_boss["day"] = str(daily_boss_data.get("day", ""))
		daily_boss["damage"] = maxi(int(daily_boss_data.get("damage", 0)), 0)
		daily_boss["reward_claimed"] = int(daily_boss_data.get("reward_claimed", -1))
	# —— v0.21：远征 / 生存 / 家园 ——
	expedition.clear()
	var expedition_data: Variant = data.get("expedition", {})
	if expedition_data is Dictionary:
		for mech_id in expedition_data:
			var exp_entry: Variant = expedition_data[mech_id]
			if exp_entry is Dictionary and owned_mechs.has(StringName(str(mech_id))):
				var task_id := StringName(str(exp_entry.get("task_id", "")))
				if Data.EXPEDITION_TASKS.has(task_id) and int(exp_entry.get("end_time", 0)) > 0:
					expedition[StringName(str(mech_id))] = { "task_id": task_id, "end_time": int(exp_entry["end_time"]) }
	survival = { "day": "", "best_waves": 0, "reward_claimed": -1 }
	var survival_data: Variant = data.get("survival", {})
	if survival_data is Dictionary:
		survival["day"] = str(survival_data.get("day", ""))
		survival["best_waves"] = maxi(int(survival_data.get("best_waves", 0)), 0)
		survival["reward_claimed"] = int(survival_data.get("reward_claimed", -1))
	home_interact.clear()
	var home_data: Variant = data.get("home_interact", {})
	if home_data is Dictionary:
		for mech_id in home_data:
			var hi_entry: Variant = home_data[mech_id]
			if hi_entry is Dictionary and owned_mechs.has(StringName(str(mech_id))):
				home_interact[StringName(str(mech_id))] = {
					"day": str(hi_entry.get("day", "")),
					"count": maxi(int(hi_entry.get("count", 0)), 0),
				}
	# —— v0.22：转盘 / 节日活动 ——
	spin = { "day": "", "free_used": false }
	var spin_data: Variant = data.get("spin", {})
	if spin_data is Dictionary:
		spin["day"] = str(spin_data.get("day", ""))
		spin["free_used"] = bool(spin_data.get("free_used", false))
	festival_claimed.clear()
	var festival_data: Variant = data.get("festival_claimed", {})
	if festival_data is Dictionary:
		for fid in festival_data:
			if Data.FESTIVALS.has(StringName(str(fid))):
				festival_claimed[StringName(str(fid))] = true
	# 成就 / 称号自动检查（新档启动时同步状态）
	_check_achievements()
	_check_titles()
	# 商城跨日刷新（清已购）
	_check_shop_refresh()
	# 每日重置（跨日清体力购买/爬塔日限/每日任务/签到断签；每周一清周任务）+ 离线体力恢复结算
	_check_daily_reset()
	_recover_stamina()
	_refresh_novice_power()

## 建节拍计时器：挂机常驻，战斗按需启动
func _setup_timers() -> void:
	idle_timer = Timer.new()
	idle_timer.wait_time = Data.IDLE_TICK_INTERVAL
	idle_timer.autostart = true
	idle_timer.timeout.connect(_on_idle_tick)
	add_child(idle_timer)
	battle_timer = Timer.new()
	battle_timer.wait_time = Data.BATTLE_TICK_INTERVAL
	battle_timer.autostart = false
	battle_timer.timeout.connect(_on_battle_tick)
	add_child(battle_timer)

## 发初始状态信号（gold_changed / diamond_changed / mech_girl_updated /
## exp_balance_updated / level_progress_changed / idle_rewards_updated / owned_mechs_updated）
func _emit_initial_state() -> void:
	Contract.gold_changed.emit(gold)
	Contract.diamond_changed.emit(diamond)
	for mech_id in _owned_mech_ids():
		var s := _mech_stats(mech_id)
		Contract.mech_girl_updated.emit(mech_id, s.hp, s.atk, s.level)
		Contract.mech_star_updated.emit(mech_id, int(mech_stars.get(mech_id, 1)), get_level_cap(mech_id))
	Contract.exp_balance_updated.emit(exp_balance)
	Contract.level_progress_changed.emit(unlocked_level)
	Contract.idle_rewards_updated.emit(roundi(idle_pending), roundi(idle_pending_exp))
	Contract.owned_mechs_updated.emit(_owned_mech_ids())
	Contract.formation_changed.emit(formation)
	# v0.13：体力 / 背包 / 开箱 / 秘境
	Contract.stamina_changed.emit(stamina)
	Contract.bag_updated.emit(bag["items"], int(bag["capacity"]))
	Contract.box_count_changed.emit(boxes)
	Contract.dungeon_cleared_changed.emit(get_dungeon_status())
	# v0.14：装备 / 宝石
	Contract.equip_inventory_changed.emit(equip_inventory)
	Contract.equipped_changed.emit(equipped)
	Contract.gem_stock_changed.emit(gem_stock)
	# v0.15：设置 / 商城
	Contract.settings_changed.emit(settings)
	Contract.shop_changed.emit(_shop_items_list(), shop_bought)
	# v0.16：爬塔 / 签到 / 任务 / 新手
	Contract.tower_changed.emit(tower_highest, tower_daily_count)
	Contract.sign_changed.emit(sign_days)
	Contract.task_changed.emit(task_daily, task_weekly)
	Contract.novice_changed.emit(_current_novice_day(), novice_progress, novice_claimed)
	# v0.17：图鉴 / 成就 / 称号 / 好感
	Contract.collection_changed.emit(_collection_count())
	Contract.achievement_changed.emit(_achievement_list())
	Contract.title_changed.emit(titles_unlocked, title_equipped)
	# v0.18：指挥官 / 引导 / 活动
	Contract.commander_changed.emit(commander_level, commander_exp)
	Contract.guide_changed.emit(guide_step)
	Contract.activity_changed.emit(_activity_list())
	# v0.20：皮肤 / 每日 BOSS
	Contract.skin_changed.emit(skins_unlocked, skin_equipped)
	Contract.daily_boss_changed.emit(int(daily_boss.damage), str(daily_boss.day))
	# v0.21：远征 / 生存 / 家园
	Contract.expedition_changed.emit(expedition)
	Contract.survival_changed.emit(str(survival.get("day", "")), int(survival.get("best_waves", 0)))
	for mid in home_interact:
		Contract.home_changed.emit(StringName(mid), int(home_interact[mid].get("count", 0)))
	# v0.22：节日活动（转盘无持久结果，初始不发 spin_changed；UI 用 get_spin_info 快照）
	Contract.festival_changed.emit(_festival_list())

## 由 Data 基础值 + 当前等级 + 星级 + 装备计算机娘完整属性（hp 为满血）
## 星级加成（v0.10）：每星基础属性 ×(1 + STAR_STAT_GAIN)^(star-1)
## 装备加成（v0.14）：百分比乘基础、数值直接加；crit_rate/crit_dmg/dodge 供战斗判定
func _mech_stats(mech_id: StringName) -> Dictionary:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var level: int = int(mech_levels.get(mech_id, 1))
	var star: int = int(mech_stars.get(mech_id, 1))
	var g: Dictionary = cfg.growth
	var spd_gain: int = floori(float(level - 1) / float(g.spd_every)) * int(g.spd_amount)
	var star_mult: float = pow(1.0 + Data.STAR_STAT_GAIN, float(star - 1))
	var base_hp: float = float(int(cfg.base_hp) + (level - 1) * int(g.hp)) * star_mult
	var base_atk: float = float(int(cfg.base_atk) + (level - 1) * int(g.atk)) * star_mult
	var base_def: float = float(int(cfg.base_def) + (level - 1) * int(g.def)) * star_mult
	var base_spd: float = float(int(cfg.base_spd) + spd_gain) * star_mult
	var es := _mech_equip_stats(mech_id)
	var title_bonus := _equipped_title_bonus()
	# 好感满级加成（攻击 +5%）+ 称号属性（百分比，全队生效；v0.17）
	var atk_mult: float = 1.0 + float(es.atk_pct) + float(title_bonus.atk_pct) + _affinity_bonus_atk(mech_id)
	var hp_mult: float = 1.0 + float(es.hp_pct) + float(title_bonus.hp_pct)
	var def_mult: float = 1.0 + float(es.def_pct) + float(title_bonus.def_pct)
	return {
		"level": level,
		"star": star,
		"hp": int(round(base_hp * hp_mult + float(es.hp))),
		"atk": int(round(base_atk * atk_mult + float(es.atk))),
		"def": int(round(base_def * def_mult + float(es.def))),
		"spd": int(round(base_spd + float(es.spd) + float(title_bonus.spd))),
		"crit_rate": float(es.crit_rate),
		"crit_dmg": float(es.crit_dmg),
		"dodge": float(es.dodge),
	}

## 该机娘穿戴装备的属性合计（v0.14）
func _mech_equip_stats(mech_id: StringName) -> Dictionary:
	var total := { "atk": 0, "hp": 0, "def": 0, "spd": 0, "atk_pct": 0.0, "hp_pct": 0.0, "def_pct": 0.0, "crit_rate": 0.0, "crit_dmg": 0.0, "dodge": 0.0 }
	if not equipped.has(mech_id):
		return total
	for slot_key in equipped[mech_id]:
		var eq := _find_equip(StringName(str(equipped[mech_id][slot_key])))
		if eq.is_empty():
			continue
		var eq_stats := _equip_total_stats(eq)
		for stat in eq_stats:
			total[stat] = float(total.get(stat, 0.0)) + float(eq_stats[stat])
	return total

## 单件装备总属性（部位固定属性 × 强化成长 + 宝石词条；v0.14）
func _equip_total_stats(eq: Dictionary) -> Dictionary:
	var total := { "atk": 0, "hp": 0, "def": 0, "spd": 0, "atk_pct": 0.0, "hp_pct": 0.0, "def_pct": 0.0, "crit_rate": 0.0, "crit_dmg": 0.0, "dodge": 0.0 }
	var slot_cfg: Dictionary = Data.EQUIP_SLOTS[StringName(str(eq.slot))]
	var star: int = int(eq.star)
	var enchant_mult: float = 1.0 + float(int(eq.level)) * Data.ENCHANT_STAT_GROWTH
	for st in slot_cfg.stats:
		var value: float = (float(st.base) + float(star - 1) * float(st.per_star)) * enchant_mult
		total[str(st.stat)] = float(total.get(str(st.stat), 0.0)) + value
	for g in eq.gems:
		for affix in g.affixes:
			var stat_name: String = str(affix.stat)
			total[stat_name] = float(total.get(stat_name, 0.0)) + float(affix.value)
	return total

## 等级上限（v0.10）：基础 100 + 星级>5 每星 +20（最高 200）
func get_level_cap(mech_id: StringName) -> int:
	var star: int = int(mech_stars.get(mech_id, 1))
	return Data.BASE_LEVEL_CAP + maxi(star - 5, 0) * Data.STAR_LEVEL_CAP_GAIN

## 升星消耗（v0.10）：返回 {fragments: 所需碎片, level_required: 所需等级（6 星起 100，1~5 星 0）}
func star_cost(mech_id: StringName) -> Dictionary:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var star: int = int(mech_stars.get(mech_id, 1))
	var frag_needed: int = int(Data.STAR_FRAGMENT_COST[int(cfg.rarity)])
	var level_required: int = 0
	if star >= 5:
		level_required = Data.STAR_6_UNLOCK_LEVEL
	return { "fragments": frag_needed, "level_required": level_required }

## ---------------------------------------------------------------
## 升星（契约 §3.6 / §3.8 入口，v0.10）：扣碎片 → star+1 → 发 mech_star_updated → 存档
## 校验：已拥有、star < MAX_STAR、碎片足够；6~10 星（当前 star ≥ 5）需等级 ≥ 100
## 签名：upgrade_star(mech_id: StringName)
## ---------------------------------------------------------------
func upgrade_star(mech_id: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	var star: int = int(mech_stars.get(mech_id, 1))
	if star >= Data.MAX_STAR:
		return
	var cost: Dictionary = star_cost(mech_id)
	if int(fragments.get(mech_id, 0)) < int(cost.fragments):
		return
	if int(cost.level_required) > 0 and int(mech_levels.get(mech_id, 1)) < int(cost.level_required):
		return
	fragments[mech_id] = int(fragments.get(mech_id, 0)) - int(cost.fragments)
	mech_stars[mech_id] = star + 1
	Contract.fragments_updated.emit(mech_id, int(fragments[mech_id]))
	Contract.mech_star_updated.emit(mech_id, star + 1, get_level_cap(mech_id))
	Save.save_game()

## 升级金币费用：第 N 级升 N+1 级 = 20 × 1.18^(N-1)（四舍五入，设计文档 §8.4）
func _upgrade_cost(mech_id: StringName, current_level: int) -> int:
	var c: Dictionary = Data.MECH_GIRLS[mech_id].upgrade_cost
	return roundi(float(c.base) * pow(float(c.growth), float(current_level - 1)))

## 升级所需经验：第 N 级升 N+1 级 = roundi(15 × 1.25^(N-1))（设计文档 §8.4，v0.2 双消耗）
func _upgrade_exp_cost(mech_id: StringName, current_level: int) -> int:
	return roundi(float(Data.UPGRADE_EXP_BASE) * pow(float(Data.UPGRADE_EXP_GROWTH), float(current_level - 1)))

## ---------------------------------------------------------------
## 升级机娘（契约 §3.6 入口）：扣金币 + 经验 → 升等级 → 提攻血 → 发信号
## 签名：upgrade(mech_id: StringName)
## 规则（v0.19 经验简化）：经验直接从全局经验池（exp_balance）扣；池不足 / 金币不足 / 满级
## 失败不发信号（手动唯一升级方式）。
## ---------------------------------------------------------------
func upgrade(mech_id: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	var current_level: int = int(mech_levels.get(mech_id, 1))
	# 等级上限（v0.10）：满级不可再升
	if current_level >= get_level_cap(mech_id):
		return
	var gold_cost: int = _upgrade_cost(mech_id, current_level)
	var exp_cost: int = _upgrade_exp_cost(mech_id, current_level)
	# 金币 / 经验池不足 → 失败不发信号
	if gold < gold_cost or exp_balance < exp_cost:
		return
	gold -= gold_cost
	exp_balance -= exp_cost
	mech_levels[mech_id] = current_level + 1
	Contract.gold_changed.emit(gold)
	Contract.exp_balance_updated.emit(exp_balance)
	var s := _mech_stats(mech_id)
	Contract.mech_girl_updated.emit(mech_id, s.hp, s.atk, s.level)
	# 任务钩子（v0.16）：升级
	_bump_task("daily", &"upgrade_mech")
	_bump_task("weekly", &"upgrade_total")
	_bump_novice(&"upgrade_count")
	_refresh_novice_power()
	Save.save_game()

## ---------------------------------------------------------------
## 进入关卡，开始自动节拍战斗（契约 §3.6 / §3.9 入口，v0.8 战斗 2.0；v0.9 主线规则）
## 签名：start_battle(level: int)
## 主线规则（v0.15）：不可选关——只接受"当前最高未通关的下一关"（get_next_level），
## 其余关卡（已通关旧关 / 未解锁后关）一律拒绝。
## ---------------------------------------------------------------
func start_battle(level: int) -> void:
	if not (level is int):
		return
	if level != _next_level():
		return
	if level < 1 or level > Data.MAX_LEVEL:
		return
	if formation.size() < 2:
		_ensure_default_formation()
	battle = {
		"level": level,
		"tick": 0,
		"active": true,
		"mode": &"story",
		"dungeon_ctx": {},
		"wave": 1,
		"total_waves": Data.LEVELS[level].waves.size(),
		"mechs": [],
		"enemies": [],
		"pending_waves": [],
		"deaths": 0,
		"mech_ids": [],
		"accelerate": accelerate,
	}
	# 我方：按阵型布阵（九宫格 3x3 选 ≤5 格；位置只影响接敌顺序，无属性加成）
	var used_ids := {}
	for slot in formation:
		var mech_id := StringName(str(slot.id))
		if not owned_mechs.has(mech_id) or used_ids.has(mech_id):
			continue
		used_ids[mech_id] = true
		battle.mechs.append(_build_mech_unit(mech_id, int(slot.row), int(slot.col)))
		battle.mech_ids.append(mech_id)
	# 敌方波次配置副本
	battle.pending_waves = []
	for wave_cfg in Data.LEVELS[level].waves:
		battle.pending_waves.append(wave_cfg)
	# 生成第一波
	_spawn_wave(battle.pending_waves[0])
	battle.pending_waves.remove_at(0)
	# 开局被动（护盾/光环/偷袭）
	_apply_passive_battle_start()
	# 立即发初始战斗状态（节拍 0 / 我方满血 / 敌方满血 / 波次）
	Contract.battle_tick.emit(0)
	for m in battle.mechs:
		Contract.mech_girl_updated.emit(m.id, int(m.hp), int(m.atk), int(m.level))
		Contract.energy_changed.emit(&"mech", m.id, int(m.energy))
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, int(e.hp))
		Contract.energy_changed.emit(&"enemy", e.id, int(e.energy))
	Contract.wave_changed.emit(battle.wave, battle.total_waves)
	_apply_battle_timer_speed()
	battle_timer.start()

## 阵型为空时自动生成：拥有的前 ≤5 位排 3-2 布局（v0.11：右列 col2 3 前排 + 中列 col1 2 后排；
## 前排 = 靠近敌方一侧，我方右列先接敌）
func _ensure_default_formation() -> void:
	var ids := _owned_mech_ids()
	formation = []
	var layout := [ [0, 2], [1, 2], [2, 2], [0, 1], [1, 1] ]
	for i in mini(ids.size(), 5):
		formation.append({ "id": ids[i], "row": layout[i][0], "col": layout[i][1] })

## 构建我方单位（引用 Data 技能配置）
func _build_mech_unit(mech_id: StringName, row: int, col: int) -> Dictionary:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var s := _mech_stats(mech_id)
	return {
		"side": &"mech", "id": mech_id, "name": str(cfg.name), "class": str(cfg.class),
		"row": row, "col": col, "level": int(s.level),
		"hp": int(s.hp), "max_hp": int(s.hp), "atk": int(s.atk), "def": int(s.def), "spd": int(s.spd),
		"energy": 0, "cd_1": 0, "cd_2": 0,
		"statuses": {}, "buffs": {}, "shield": 0, "taunt_turns": 0, "dodge_crit_ready": false,
		"alive": true, "dmg_dealt": 0, "heal_done": 0,
		"crit_rate": float(s.get("crit_rate", 0.0)),
		"crit_dmg": float(s.get("crit_dmg", 0.0)),
		"dodge": float(s.get("dodge", 0.0)),
		"passive": cfg.passive, "skills": cfg.skills, "ultimate": cfg.ultimate,
	}

## 生成一波敌方单位（AI 排阵 v0.11：tank 排 col0 前排（靠近我方一侧），其余输出单位排 col1/col2；
## row 仅用于同列内铺开——col0 内 row0/row1/row2 依次分配，col1 内同理，col2 最后；保持每波 ≤5）
func _spawn_wave(wave_cfg: Array) -> void:
	battle.enemies = []
	var col0_row := 0
	var col1_row := 0
	var col2_row := 0
	for cfg in wave_cfg:
		var row: int = col1_row
		var col: int = 1
		if str(cfg.class) == "tank":
			row = col0_row
			col = 0
			col0_row += 1
		elif col1_row < 3:
			row = col1_row
			col = 1
			col1_row += 1
		else:
			row = col2_row
			col = 2
			col2_row += 1
		var skills_arr: Array = []
		for skill_id in cfg.skills:
			if Data.ENEMY_SKILLS.has(StringName(str(skill_id))):
				skills_arr.append(Data.ENEMY_SKILLS[StringName(str(skill_id))])
		var ultimate: Dictionary = {}
		if cfg.has("ultimate") and Data.ENEMY_SKILLS.has(StringName(str(cfg.ultimate))):
			ultimate = Data.ENEMY_SKILLS[StringName(str(cfg.ultimate))]
		battle.enemies.append({
			"side": &"enemy", "id": StringName(str(cfg.id)), "name": str(cfg.name),
			"class": str(cfg.class), "tier": str(cfg.get("tier", "normal")),
			"row": row, "col": col,
			"hp": int(cfg.hp), "max_hp": int(cfg.hp), "atk": int(cfg.atk), "def": int(cfg.def), "spd": int(cfg.spd),
			"energy": 0, "cd_1": 0, "cd_2": 0,
			"statuses": {}, "buffs": {}, "shield": 0, "taunt_turns": 0, "dodge_crit_ready": false,
			"alive": true, "dmg_dealt": 0, "heal_done": 0,
			"passive": { "effects": [] }, "skills": skills_arr, "ultimate": ultimate,
		})

## 战斗节拍：每秒 1 轮（契约 §1.3 / §3.4；2x 加速时 0.5 秒/轮）
func _on_battle_tick() -> void:
	if not battle.active:
		return
	battle.tick += 1
	Contract.battle_tick.emit(battle.tick)
	if battle.tick > Data.BATTLE_MAX_ROUNDS:
		_check_timeout()
		return
	# 全体存活单位按速度降序行动（含状态回合开始处理）
	var order: Array = []
	for m in battle.mechs:
		if bool(m.alive):
			order.append(m)
	for e in battle.enemies:
		if bool(e.alive):
			order.append(e)
	order.sort_custom(func(a, b): return int(a.spd) > int(b.spd))
	for unit in order:
		if not bool(unit.alive) or not battle.active:
			continue
		_unit_turn(unit)
	# 回合结束：每轮回血被动 + 计时递减
	for m in battle.mechs:
		if bool(m.alive):
			_apply_passive_per_round_end(m)
		_tick_unit_timers(m)
	for e in battle.enemies:
		_tick_unit_timers(e)
	# 胜负判定
	if not _any_alive(battle.mechs):
		_resolve_defeat()
		return
	_check_wave_clear()

## 单位回合：大招（能量满）→ 小技能（CD 到）→ 普攻
func _unit_turn(unit) -> void:
	if _apply_turn_start_status(unit):
		return
	if int(unit.energy) >= Data.ENERGY_MAX and not unit.ultimate.is_empty():
		unit.energy = 0
		_emit_energy(unit)
		_cast_skill(unit, unit.ultimate, true)
		return
	for i in unit.skills.size():
		var cd_key: String = "cd_" + str(i + 1)
		if int(unit[cd_key]) <= 0:
			var skill: Dictionary = unit.skills[i]
			unit[cd_key] = int(skill.cd)
			_cast_skill(unit, skill, false)
			return
	_cast_basic_attack(unit)

## 普攻（目标 = 同列最近/嘲讽优先；命中加能量）
func _cast_basic_attack(unit) -> void:
	var target := _default_attack_target(unit)
	if target.is_empty():
		return
	var dmg: int = _deal_damage(unit, target, 1.0, null, false)
	if dmg > 0:
		_gain_energy(unit, Data.ENERGY_GAIN_HIT)
		# 被动：普攻连击（翎）、额外能量（芽/璇）
		for eff in unit.passive.effects:
			match str(eff.kind):
				"combo_chance":
					if randf() < float(eff.chance) and bool(target.alive):
						_deal_damage(unit, target, float(eff.rate), null, false)
				"energy_on_hit":
					_gain_energy(unit, int(eff.value))

## 释放技能（小技/大招）；发 skill_cast
func _cast_skill(unit, skill: Dictionary, is_ultimate: bool) -> void:
	var targets := _targets_for(unit, str(skill.target))
	var value: int = 0
	var effect: String = str(skill.effect)
	match effect:
		"damage":
			for t in targets:
				if not bool(t.alive):
					continue
				for hit in int(skill.get("hits", 1)):
					if not bool(t.alive):
						break
					value += _deal_damage(unit, t, float(skill.rate), skill, is_ultimate)
		"heal":
			for t in targets:
				if bool(t.alive):
					value += _heal_unit(unit, t, float(skill.rate))
		"shield":
			for t in targets:
				if bool(t.alive):
					value += _shield_unit(unit, t, float(skill.rate))
		"buff":
			for t in targets:
				if bool(t.alive):
					_apply_buff(t, StringName(str(skill.stat)), float(skill.value), int(skill.get("duration", Data.STATUS_DURATION_DEFAULT)))
		"debuff":
			for t in targets:
				if bool(t.alive):
					_apply_debuff(t, StringName(str(skill.stat)), float(skill.value), int(skill.get("duration", Data.STATUS_DURATION_DEFAULT)))
		"stun", "freeze":
			for t in targets:
				if bool(t.alive) and randf() < float(skill.get("chance", 1.0)):
					_apply_status(t, StringName(effect), int(skill.get("duration", 1)), 0.0, 0.0)
		"burn", "poison":
			for t in targets:
				if bool(t.alive) and randf() < float(skill.get("chance", 1.0)):
					_apply_status(t, StringName(effect), int(skill.get("duration", Data.STATUS_DURATION_DEFAULT)), float(skill.get("rate", 0.3)), float(unit.atk))
		"taunt":
			for t in targets:
				if bool(t.alive):
					_apply_taunt(t, int(skill.get("duration", 1)))
		"cleanse":
			for t in targets:
				if bool(t.alive):
					_cleanse_unit(t)
	# 非 damage 型技能的 bonus（damage 型在 _deal_damage 内处理）
	if effect != "damage" and skill.has("bonus"):
		_apply_skill_bonus(unit, targets, skill.bonus, 0)
	Contract.skill_cast.emit(unit.side, unit.id, StringName(str(skill.get("id", skill.get("name", &"skill")))), value)

## 技能/普攻的附加效果（bonus 数组）
func _apply_skill_bonus(attacker, targets: Array, bonus: Array, dealt: int) -> void:
	for t in targets:
		if not bool(t.alive):
			continue
		for b in bonus:
			match str(b.kind):
				"combo":
					# 连击算普攻：可暴击闪避、命中可获能量（v0.10）
					var cdmg: int = _deal_damage(attacker, t, float(b.rate), null, false)
					if cdmg > 0:
						_gain_energy(attacker, Data.ENERGY_GAIN_HIT)
				"burn":
					if randf() < float(b.get("chance", 1.0)):
						_apply_status(t, &"burn", int(b.get("duration", Data.STATUS_DURATION_DEFAULT)), float(b.get("rate", 0.3)), float(attacker.atk))
				"poison":
					if randf() < float(b.get("chance", 1.0)):
						_apply_status(t, &"poison", int(b.get("duration", Data.STATUS_DURATION_DEFAULT)), float(b.get("rate", 0.3)), float(attacker.atk))
				"stun", "freeze":
					if randf() < float(b.get("chance", 1.0)):
						_apply_status(t, StringName(str(b.kind)), int(b.get("duration", 1)), 0.0, 0.0)
				"armor_break":
					_apply_debuff(t, &"def", float(b.get("value", 0.3)), int(b.get("duration", Data.STATUS_DURATION_DEFAULT)))
				"debuff":
					_apply_debuff(t, StringName(str(b.stat)), float(b.value), int(b.get("duration", Data.STATUS_DURATION_DEFAULT)))
				"buff":
					_apply_buff(t, StringName(str(b.stat)), float(b.value), int(b.get("duration", Data.STATUS_DURATION_DEFAULT)))
				"shield":
					_shield_unit(attacker, t, float(b.get("rate", 0.2)))
				"cleanse":
					_cleanse_unit(t)

## 造成伤害主流程（闪避/斩杀/克制/暴击/减防/下限/护盾/能量/附加/击杀）
## allow_chase：本次伤害的击杀是否允许再触发追击（追击不可再触发追击，v0.10）
## allow_counter：本次受击是否允许触发反击/反弹（防递归）
func _deal_damage(attacker, target, rate: float, skill, is_ultimate: bool, allow_chase: bool = true, allow_counter: bool = true) -> int:
	if _roll_dodge(target):
		Contract.battle_prompt.emit(&"dodge", "闪避")
		_on_dodge(target)
		return 0
	var mult: float = 1.0
	var ignore_def: float = _passive_ignore_def(attacker)
	if skill != null:
		for b in skill.get("bonus", []):
			if str(b.kind) == "execute" and float(target.hp) <= float(target.max_hp) * float(b.threshold):
				mult *= 2.0
			elif str(b.kind) == "ignore_def":
				ignore_def += float(b.value)
	mult *= _passive_execute_bonus(attacker, target)
	var base: float = float(attacker.atk) * rate * mult
	var def_eff: float = float(target.def) * (1.0 - ignore_def)
	var dmg: float = base - def_eff
	if dmg < base * Data.DAMAGE_FLOOR_RATIO:
		dmg = base * Data.DAMAGE_FLOOR_RATIO
	dmg *= _counter_mult(str(attacker.class), str(target.class))
	var crit: bool = _roll_crit(attacker)
	if crit:
		var crit_mult: float = Data.CRIT_DAMAGE_MULT + float(attacker.get("crit_dmg", 0.0))
		if skill != null:
			for b in skill.get("bonus", []):
				if str(b.kind) == "crit_bonus":
					crit_mult += float(b.value)
		dmg *= crit_mult
	dmg *= (1.0 - _total_buff(target, "damage_reduce"))
	dmg *= (1.0 - _passive_damage_reduce(target))
	var final_dmg: int = maxi(int(round(dmg)), Data.DAMAGE_MIN)
	final_dmg = _damage_unit(target, final_dmg)
	_gain_energy(target, Data.ENERGY_GAIN_HIT_TAKEN)
	attacker.dmg_dealt = int(attacker.dmg_dealt) + final_dmg
	if skill != null:
		_apply_skill_bonus(attacker, [target], skill.get("bonus", []), final_dmg)
	# 被动：月见破甲、汐/霜控制（普攻/技能命中时）
	for eff in attacker.passive.effects:
		match str(eff.kind):
			"armor_break_on_hit":
				if randf() < float(eff.chance):
					_apply_debuff(target, &"def", float(eff.value), int(eff.duration))
			"stun_chance":
				if randf() < float(eff.chance):
					_apply_status(target, StringName(eff.get("status", "stun")), int(eff.duration), 0.0, 0.0)
	_on_taken_hit(target, attacker, final_dmg, allow_counter)
	if not bool(target.alive):
		_handle_kill(attacker, target, skill, allow_chase)
	if crit:
		Contract.battle_prompt.emit(&"crit", "暴击 " + str(final_dmg))
	else:
		Contract.battle_prompt.emit(&"hit", str(final_dmg))
	_emit_hp(target)
	return final_dmg

## 简化伤害（反击/反弹用，不递归完整判定）
func _simple_damage(attacker, target, rate: float) -> int:
	var dmg: float = float(attacker.atk) * rate - float(target.def)
	if dmg < float(attacker.atk) * rate * Data.DAMAGE_FLOOR_RATIO:
		dmg = float(attacker.atk) * rate * Data.DAMAGE_FLOOR_RATIO
	var final_dmg: int = maxi(int(round(dmg)), Data.DAMAGE_MIN)
	final_dmg = _damage_unit(target, final_dmg)
	if not bool(target.alive):
		_handle_kill(attacker, target, null)
	_emit_hp(target)
	return final_dmg

## 扣血（护盾优先吸收）
func _damage_unit(target, dmg: int) -> int:
	var shield: int = int(target.shield)
	if shield > 0:
		var absorbed: int = mini(shield, dmg)
		target.shield = shield - absorbed
		dmg -= absorbed
		if dmg <= 0:
			Contract.battle_prompt.emit(&"shield", "护盾")
			return 0
	target.hp = int(target.hp) - dmg
	if int(target.hp) <= 0:
		target.hp = 0
		target.alive = false
		if target.side == &"mech":
			battle.deaths = int(battle.deaths) + 1
	return dmg

## 治疗
func _heal_unit(healer, target, rate: float) -> int:
	var amount: int = maxi(int(round(float(healer.atk) * rate)), 1)
	target.hp = mini(int(target.hp) + amount, int(target.max_hp))
	healer.heal_done = int(healer.heal_done) + amount
	Contract.battle_prompt.emit(&"heal", "治疗 " + str(amount))
	_emit_hp(target)
	return amount

## 按最大血量比例治疗（被动回血用）
func _heal_unit_raw(healer, target, ratio: float) -> int:
	var amount: int = maxi(int(round(float(target.max_hp) * ratio)), 1)
	target.hp = mini(int(target.hp) + amount, int(target.max_hp))
	healer.heal_done = int(healer.heal_done) + amount
	Contract.battle_prompt.emit(&"heal", "治疗 " + str(amount))
	_emit_hp(target)
	return amount

## 护盾
func _shield_unit(caster, target, rate: float) -> int:
	var amount: int = maxi(int(round(float(target.max_hp) * rate)), 1)
	target.shield = int(target.shield) + amount
	Contract.battle_prompt.emit(&"shield", "护盾 " + str(amount))
	return amount

## 增益（不叠加只刷新时长；应用即通知 UI）
func _apply_buff(unit, stat: StringName, value: float, duration: int) -> void:
	if not unit.buffs.has(stat):
		unit.buffs[stat] = { "value": value, "duration": duration }
	else:
		unit.buffs[stat]["duration"] = duration
	Contract.status_changed.emit(unit.side, unit.id, stat, duration)

## 减益（同增益；信号由 _apply_buff 统一发出）
func _apply_debuff(unit, stat: StringName, value: float, duration: int) -> void:
	_apply_buff(unit, stat, value, duration)

## 状态（眩晕/灼烧/中毒/冰冻；不叠加只刷新时长）
## 被控期间不吃新控（v0.10：已有眩晕/冰冻时，新控制不生效）
func _apply_status(unit, status_id: StringName, duration: int, rate: float, source_atk: float) -> void:
	if (status_id == &"stun" or status_id == &"freeze") and (unit.statuses.has(&"stun") or unit.statuses.has(&"freeze")):
		return
	if not unit.statuses.has(status_id):
		unit.statuses[status_id] = { "duration": duration, "rate": rate, "source_atk": source_atk }
	else:
		unit.statuses[status_id]["duration"] = duration
	Contract.status_changed.emit(unit.side, unit.id, status_id, duration)

## 嘲讽（敌人优先攻击该单位；应用即通知 UI）
func _apply_taunt(unit, duration: int) -> void:
	unit.taunt_turns = maxi(int(unit.taunt_turns), duration)
	Contract.status_changed.emit(unit.side, unit.id, &"taunt", int(unit.taunt_turns))

## 净化（清除负面状态：减益 + 控制/持续状态；移除均通知 UI）
func _cleanse_unit(unit) -> void:
	var negative := [&"stun", &"freeze", &"burn", &"poison"]
	for sid in negative:
		if unit.statuses.has(sid):
			unit.statuses.erase(sid)
			Contract.status_changed.emit(unit.side, unit.id, sid, 0)
	for bkey in unit.buffs.keys():
		var bname: String = String(bkey)
		if bname == "atk" or bname == "def" or bname == "spd":
			unit.buffs.erase(bkey)
			Contract.status_changed.emit(unit.side, unit.id, StringName(bkey), 0)

## 能量变化（100 满后不再加；被控（眩晕/冰冻）不加能量，v0.10）
func _gain_energy(unit, amount: int) -> void:
	if int(unit.energy) >= Data.ENERGY_MAX:
		return
	if unit.statuses.has(&"stun") or unit.statuses.has(&"freeze"):
		return
	unit.energy = mini(int(unit.energy) + amount, Data.ENERGY_MAX)
	_emit_energy(unit)

func _emit_energy(unit) -> void:
	Contract.energy_changed.emit(unit.side, unit.id, int(unit.energy))

## 血条信号
func _emit_hp(unit) -> void:
	if unit.side == &"mech":
		Contract.mech_girl_updated.emit(unit.id, int(unit.hp), int(unit.atk), int(unit.level))
	else:
		Contract.enemy_updated.emit(unit.id, int(unit.hp))

## 暴击判定（基础 10% + 装备 + 被动 + 闪避联动必暴击）
func _roll_crit(attacker) -> bool:
	if bool(attacker.dodge_crit_ready):
		attacker.dodge_crit_ready = false
		return true
	var rate: float = Data.CRIT_RATE_BASE + float(attacker.get("crit_rate", 0.0))
	for eff in attacker.passive.effects:
		if str(eff.kind) == "crit_rate":
			rate += float(eff.value)
	return randf() < rate

## 闪避判定（基础 5% + 装备 + 增益/被动）
func _roll_dodge(target) -> bool:
	var rate: float = Data.DODGE_RATE_BASE + _total_buff(target, "dodge") + float(target.get("dodge", 0.0))
	for eff in target.passive.effects:
		if str(eff.kind) == "dodge" or str(eff.kind) == "dodge_crit":
			rate += float(eff.value)
	return randf() < rate

## 闪避后联动（星澜被动：下次攻击必暴击）
func _on_dodge(target) -> void:
	for eff in target.passive.effects:
		if str(eff.kind) == "dodge_crit":
			target.dodge_crit_ready = true

## 职业克制系数（克制 +20%、被克 -10%、辅助中立）
func _counter_mult(attacker_class: String, target_class: String) -> float:
	if Data.CLASS_COUNTER.has(StringName(attacker_class)) and String(Data.CLASS_COUNTER[StringName(attacker_class)]) == target_class:
		return Data.COUNTER_MULT
	if Data.CLASS_COUNTER.has(StringName(target_class)) and String(Data.CLASS_COUNTER[StringName(target_class)]) == attacker_class:
		return Data.COUNTER_PENALTY
	return 1.0

## buff 总值
func _total_buff(unit, stat: String) -> float:
	var total: float = 0.0
	for key in unit.buffs:
		if String(key) == stat:
			total += float(unit.buffs[key].value)
	return total

## 被动：受伤减免
func _passive_damage_reduce(unit) -> float:
	var total: float = 0.0
	for eff in unit.passive.effects:
		if str(eff.kind) == "damage_reduce":
			total += float(eff.value)
	return total

## 被动：无视防御
func _passive_ignore_def(attacker) -> float:
	var total: float = 0.0
	for eff in attacker.passive.effects:
		if str(eff.kind) == "ignore_def":
			total += float(eff.value)
	return total

## 被动：处决加成（攻击血量低于阈值目标伤害加成，冥）
func _passive_execute_bonus(attacker, target) -> float:
	var total: float = 0.0
	for eff in attacker.passive.effects:
		if str(eff.kind) == "execute_bonus" and float(target.hp) <= float(target.max_hp) * float(eff.threshold):
			total += float(eff.value)
	return 1.0 + total

## 被动：受击触发（反击/反弹；反击算普攻可暴击闪避可获能量，但不触发对方反击/反弹，防递归，v0.10）
func _on_taken_hit(target, attacker, dmg: int, allow_counter: bool = true) -> void:
	if not bool(target.alive) or not allow_counter:
		return
	for eff in target.passive.effects:
		if str(eff.kind) == "counter" and randf() < float(eff.chance):
			var cdmg: int = _deal_damage(target, attacker, float(eff.rate), null, false, true, false)
			if bool(eff.get("armor_break", false)):
				_apply_debuff(attacker, &"def", 0.30, Data.STATUS_DURATION_DEFAULT)
			Contract.battle_prompt.emit(&"hit", "反击 " + str(cdmg))
		elif str(eff.kind) == "reflect" and randf() < float(eff.chance):
			var rdmg: int = _deal_damage(target, attacker, float(eff.rate), null, false, true, false)
			Contract.battle_prompt.emit(&"hit", "反弹 " + str(rdmg))

## 击杀处理（追击 / 击杀回血 / 击杀回能量；追击算普攻可获能量，追击不可再触发追击，v0.10）
func _handle_kill(attacker, target, skill, allow_chase: bool = true) -> void:
	Contract.battle_prompt.emit(&"kill", "击杀")
	for eff in attacker.passive.effects:
		if str(eff.kind) == "kill_heal":
			_heal_unit_raw(attacker, attacker, float(eff.value))
	if skill != null:
		for b in skill.get("bonus", []):
			match str(b.kind):
				"chase":
					if allow_chase:
						var next_target := _next_target_same_col(attacker, target)
						if not next_target.is_empty():
							var cdmg: int = _deal_damage(attacker, next_target, float(b.rate), skill, true, false, true)
							if cdmg > 0:
								_gain_energy(attacker, Data.ENERGY_GAIN_HIT)
				"heal_self_on_kill":
					if str(b.get("resource", "hp")) == "energy":
						_gain_energy(attacker, int(round(float(b.value) * 100.0)))

## 追击目标：与 target 同一 col 的下一个存活敌人（v0.12：追击"同排"= 同一列；
## row 不限、跳过 target 自己、取第一个）；无同列目标返回空
func _next_target_same_col(attacker, target) -> Dictionary:
	var enemies: Array = battle.enemies if attacker.side == &"mech" else battle.mechs
	for e in enemies:
		if bool(e.alive) and int(e.col) == int(target.col) and StringName(str(e.id)) != StringName(str(target.id)):
			return e
	return {}

## 回合开始状态处理：灼烧/中毒掉血；眩晕/冰冻跳过行动
func _apply_turn_start_status(unit) -> bool:
	var skipped: bool = unit.statuses.has(&"stun") or unit.statuses.has(&"freeze")
	if unit.statuses.has(&"burn"):
		var burn: Dictionary = unit.statuses[&"burn"]
		var dmg: int = _status_dot(unit, float(burn.rate), float(burn.source_atk))
		Contract.battle_prompt.emit(&"hit", "灼烧 " + str(dmg))
		_emit_hp(unit)
		if not bool(unit.alive):
			return true
	if unit.statuses.has(&"poison"):
		var poison: Dictionary = unit.statuses[&"poison"]
		var dmg2: int = _status_dot(unit, float(poison.rate), float(poison.source_atk))
		Contract.battle_prompt.emit(&"hit", "中毒 " + str(dmg2))
		_emit_hp(unit)
		if not bool(unit.alive):
			return true
	return skipped

## 持续状态每轮掉血（率 × 施放者攻击 − 防御，下限 30%）
func _status_dot(unit, rate: float, source_atk: float) -> int:
	var base: float = rate * source_atk
	var dmg: float = base - float(unit.def)
	if dmg < base * Data.DAMAGE_FLOOR_RATIO:
		dmg = base * Data.DAMAGE_FLOOR_RATIO
	var final_dmg: int = maxi(int(round(dmg)), Data.DAMAGE_MIN)
	_damage_unit(unit, final_dmg)
	return final_dmg

## 回合结束计时：buff/状态/CD/嘲讽递减，到期移除（移除均通知 UI，duration=0）
func _tick_unit_timers(unit) -> void:
	for key in unit.buffs.keys():
		unit.buffs[key]["duration"] = int(unit.buffs[key]["duration"]) - 1
		if int(unit.buffs[key]["duration"]) <= 0:
			unit.buffs.erase(key)
			Contract.status_changed.emit(unit.side, unit.id, StringName(key), 0)
	for key in unit.statuses.keys():
		unit.statuses[key]["duration"] = int(unit.statuses[key]["duration"]) - 1
		if int(unit.statuses[key]["duration"]) <= 0:
			unit.statuses.erase(key)
			Contract.status_changed.emit(unit.side, unit.id, StringName(key), 0)
	unit.cd_1 = maxi(int(unit.cd_1) - 1, 0)
	unit.cd_2 = maxi(int(unit.cd_2) - 1, 0)
	var old_taunt: int = int(unit.taunt_turns)
	unit.taunt_turns = maxi(old_taunt - 1, 0)
	if old_taunt > 0 and int(unit.taunt_turns) == 0:
		Contract.status_changed.emit(unit.side, unit.id, &"taunt", 0)

## 开局被动：全体护盾（千夏）/ 全队攻光环（鸦/洛）/ 战斗开始偷袭（鸢）
func _apply_passive_battle_start() -> void:
	var atk_aura: float = 0.0
	for m in battle.mechs:
		for eff in m.passive.effects:
			if str(eff.kind) == "atk_aura":
				atk_aura += float(eff.value)
	if atk_aura > 0.0:
		for m in battle.mechs:
			m.atk = int(round(float(m.atk) * (1.0 + atk_aura)))
	for m in battle.mechs:
		for eff in m.passive.effects:
			if str(eff.kind) == "shield_start":
				for ally in battle.mechs:
					_shield_unit(m, ally, float(eff.value))
			elif str(eff.kind) == "ambush":
				var ambush_target := _lowest_hp_target(&"enemy")
				if not ambush_target.is_empty():
					_deal_damage(m, ambush_target, float(eff.rate), null, false)

## 每轮回血被动（柚/糖/沐）
func _apply_passive_per_round_end(unit) -> void:
	for eff in unit.passive.effects:
		if str(eff.kind) == "heal_per_round":
			for ally in battle.mechs:
				if bool(ally.alive):
					_heal_unit_raw(unit, ally, float(eff.value))

## 目标选择
func _targets_for(unit, target_type: String) -> Array:
	var enemies: Array = battle.enemies if unit.side == &"mech" else battle.mechs
	var allies: Array = battle.mechs if unit.side == &"mech" else battle.enemies
	match target_type:
		"single":
			var t := _default_attack_target(unit)
			return [] if t.is_empty() else [t]
		"lowest_hp":
			var t2 := _lowest_hp_target(unit.side)
			return [] if t2.is_empty() else [t2]
		"lowest_hp_ally":
			var t3 := _lowest_hp_ally(unit.side)
			return [] if t3.is_empty() else [t3]
		"front":
			# 前排 = 靠近敌方一侧的那一列：我方视角 col2 / 敌方视角 col0（v0.11）
			var front_col: int = 0 if unit.side == &"mech" else 2
			return _col_targets(enemies, front_col)
		"back":
			# 后排 = 远离敌方一侧的那一列：我方视角 col0 / 敌方视角 col2（v0.11）
			var back_col: int = 2 if unit.side == &"mech" else 0
			return _col_targets(enemies, back_col)
		"all":
			var all: Array = []
			for e in enemies:
				if bool(e.alive):
					all.append(e)
			return all
		"all_ally":
			var all_a: Array = []
			for a in allies:
				if bool(a.alive):
					all_a.append(a)
			return all_a
		"self":
			return [unit]
	return []

## 默认攻击目标：嘲讽优先 → 同列最近 → 前排（靠近敌方一侧）优先 → 列距兜底（v0.11）
## 前排判定：我方攻击敌方时，敌方 col 越小越靠前（敌方 col0 为前排，先接敌）；
##            敌方攻击我方时，我方 col 越大越靠前（我方 col2 为前排，先接敌）
func _default_attack_target(attacker) -> Dictionary:
	var enemies: Array = battle.enemies if attacker.side == &"mech" else battle.mechs
	for e in enemies:
		if bool(e.alive) and int(e.taunt_turns) > 0:
			return e
	var best: Dictionary = {}
	var best_score := 99999
	for e in enemies:
		if not bool(e.alive):
			continue
		var col_diff: int = absi(int(e.col) - int(attacker.col))
		var same_col: int = 0 if col_diff == 0 else 1
		# 靠近敌方一侧优先：我方攻击者取 e.col（小=前排 col0）；敌方攻击者取 (2 - e.col)（大=前排 col2）
		var front: int = int(e.col) if attacker.side == &"mech" else 2 - int(e.col)
		var score: int = same_col * 1000 + front * 10 + col_diff
		if score < best_score:
			best_score = score
			best = e
	return best

## 敌方存活中血量最低
func _lowest_hp_target(attacker_side) -> Dictionary:
	var enemies: Array = battle.enemies if attacker_side == &"mech" else battle.mechs
	var best: Dictionary = {}
	var best_hp := 1 << 30
	for e in enemies:
		if bool(e.alive) and int(e.hp) < best_hp:
			best_hp = int(e.hp)
			best = e
	return best

## 我方存活中血量最低
func _lowest_hp_ally(attacker_side) -> Dictionary:
	var allies: Array = battle.mechs if attacker_side == &"mech" else battle.enemies
	var best: Dictionary = {}
	var best_hp := 1 << 30
	for a in allies:
		if bool(a.alive) and int(a.hp) < best_hp:
			best_hp = int(a.hp)
			best = a
	return best

## 某列全部存活目标（v0.11：front/back AOE 按列取；替换原按行取 _row_targets / _max_row）
func _col_targets(units: Array, col: int) -> Array:
	var result: Array = []
	for u in units:
		if bool(u.alive) and int(u.col) == col:
			result.append(u)
	return result

func _any_alive(units: Array) -> bool:
	for u in units:
		if bool(u.alive):
			return true
	return false

## 波次推进：当前波清空 → 下一波或胜利（生存模式：无限生成下一波而非胜利，v0.21）
func _check_wave_clear() -> void:
	if _any_alive(battle.enemies):
		return
	if battle.mode == &"survival":
		_next_survival_wave()
		return
	if battle.pending_waves.is_empty():
		_resolve_victory()
		return
	battle.wave = int(battle.wave) + 1
	battle.enemies = []
	_spawn_wave(battle.pending_waves[0])
	battle.pending_waves.remove_at(0)
	Contract.wave_changed.emit(battle.wave, battle.total_waves)
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, int(e.hp))
		Contract.energy_changed.emit(&"enemy", e.id, 0)

## 60 轮超时：按双方剩余血量百分比判定（我方高则胜，否则败；生存模式按波数结算，v0.21）
func _check_timeout() -> void:
	if battle.mode == &"survival":
		_settle_survival_end()
		return
	var mech_ratio: float = _remaining_hp_ratio(battle.mechs)
	var enemy_ratio: float = _remaining_hp_ratio(battle.enemies)
	Contract.battle_prompt.emit(&"hit", "战斗超时")
	if mech_ratio >= enemy_ratio:
		_resolve_victory()
	else:
		_resolve_defeat()

func _remaining_hp_ratio(units: Array) -> float:
	var total := 0.0
	var max_total := 0.0
	for u in units:
		max_total += float(u.max_hp)
		if bool(u.alive):
			total += float(u.hp)
	if max_total <= 0.0:
		return 0.0
	return total / max_total

## 胜利：按战斗模式分流（主线 story / 秘境 dungeon / 爬塔 tower / 每日BOSS boss；生存无胜利，v0.21）
func _resolve_victory() -> void:
	if battle.mode == &"survival":
		# 生存模式无"胜利"：超时且我方血量占比更高时也按波数结算（防御性分支，正常走 _check_timeout）
		_settle_survival_end()
		return
	if battle.mode == &"dungeon":
		_resolve_dungeon_victory()
		return
	if battle.mode == &"tower":
		_resolve_tower_victory()
		return
	if battle.mode == &"boss":
		_resolve_boss_end()
		return
	battle.active = false
	battle_timer.stop()
	var level: int = int(battle.level)
	var first_clear: bool = not cleared_levels.has(level)
	var reward: int = 0
	var star: int = _calc_star(int(battle.deaths))
	if first_clear:
		cleared_levels[level] = true
		reward = int(Data.LEVELS[level].first_clear_reward)
		if reward > 0:
			gold += reward
			Contract.gold_changed.emit(gold)
		var diamond_reward: int = int(Data.LEVELS[level].first_clear_reward_diamond)
		if diamond_reward > 0:
			diamond += diamond_reward
			Contract.diamond_changed.emit(diamond)
		# 首通掉落小钰碎片（设计文档 §1.3 / 附录 B，v0.15：普通关 1 片、章节 BOSS 关 3 片；一次性）
		var xiaoyu_frag: int = Data.XIAOYU_FRAGMENT_FIRST_CLEAR
		if int(Data.CHAPTERS[1].boss_level) == level:
			xiaoyu_frag = Data.XIAOYU_FRAGMENT_BOSS
		fragments[&"xiao_yu"] = int(fragments.get(&"xiao_yu", 0)) + xiaoyu_frag
		Contract.fragments_updated.emit(&"xiao_yu", int(fragments[&"xiao_yu"]))
		# BOSS 关记录
		if int(Data.CHAPTERS[1].boss_level) == level:
			cleared_boss[level] = true
		# 主线首通发放宝箱（每关 1 个，v0.13）
		boxes += 1
		Contract.box_count_changed.emit(boxes)
		var next_level: int = level + 1
		if next_level <= Data.MAX_LEVEL and next_level > unlocked_level:
			unlocked_level = next_level
			Contract.level_progress_changed.emit(unlocked_level)
	# 星级记录 + 星奖（首次达到某星级发对应档奖励，一次性）
	var old_star: int = int(level_stars.get(level, 0))
	if star > old_star:
		for s in range(old_star + 1, star + 1):
			_grant_star_reward(s)
		level_stars[level] = star
	# 章节星数宝箱（第 1 章 5 关 × 3 星，集满 90%）
	_check_chapter_chest()
	# 胜利经验：进入全局经验池（v0.19 经验简化，不再分个人条）
	exp_balance += int(Data.LEVELS[level].victory_reward_exp)
	Contract.exp_balance_updated.emit(exp_balance)
	# 记录本局通关信息（内存态，不入档）
	last_clear = { "level": level, "first_clear": first_clear, "reward": reward }
	# 任务钩子（v0.16）：推主线
	_bump_task("daily", &"story_levels")
	_bump_task("weekly", &"story_total")
	_bump_novice(&"story_count")
	# v0.17：出战胜利好感 +1 + 成就/称号自动检查
	_gain_battle_affinity()
	_check_achievements()
	_check_titles()
	# v0.18：指挥官经验（推关）
	_gain_commander_exp(Data.COMMANDER_EXP_STORY)
	Contract.battle_star.emit(star)
	Contract.level_cleared.emit(level, first_clear)
	Save.save_game()

## 星级规则（设计文档 §8.3）：无人阵亡 3 星、阵亡 1~2 人 2 星、惨胜 1 星
func _calc_star(deaths: int) -> int:
	if deaths <= Data.STAR_3_MAX_DEATHS:
		return 3
	if deaths <= Data.STAR_2_MAX_DEATHS:
		return 2
	return 1

## 星奖（设计文档 §1.3：1 星金币 / 2 星钻石 / 3 星召唤券，各一次性）
func _grant_star_reward(star: int) -> void:
	match star:
		1:
			gold += Data.STAR_REWARD_GOLD
			Contract.gold_changed.emit(gold)
		2:
			diamond += Data.STAR_REWARD_DIAMOND
			Contract.diamond_changed.emit(diamond)
		3:
			summon_ticket += Data.STAR_REWARD_TICKET

## 章节星数宝箱（第 1 章满 15 星，集满 90% 领一次）
func _check_chapter_chest() -> void:
	if chapter_chest_claimed:
		return
	var chapter: Dictionary = Data.CHAPTERS[1]
	var total_stars: int = int(chapter.levels) * 3
	var earned := 0
	for level in level_stars:
		if int(level) >= 1 and int(level) <= int(chapter.levels):
			earned += int(level_stars[level])
	if float(earned) >= float(total_stars) * Data.CHAPTER_CHEST_STAR_RATIO:
		chapter_chest_claimed = true
		gold += Data.CHAPTER_CHEST_GOLD
		diamond += Data.CHAPTER_CHEST_DIAMOND
		Contract.gold_changed.emit(gold)
		Contract.diamond_changed.emit(diamond)
		Contract.battle_prompt.emit(&"skill", "章节宝箱已开启！")

## 秘境胜利结算（v0.13）：预扣体力保留（成功消耗）→ 首通钻石 + 掉落资源 →
## 上阵机娘经验 → 通关记录 → 发 dungeon_reward / dungeon_cleared_changed → 存档
func _resolve_dungeon_victory() -> void:
	battle.active = false
	battle_timer.stop()
	var ctx: Dictionary = battle.dungeon_ctx
	var kind := StringName(str(ctx.kind))
	var tier: int = int(ctx.tier)
	var tier_cfg: Dictionary = Data.DUNGEONS[kind].tiers[tier]
	var diamond_reward: int = int(tier_cfg.first_clear_diamond)
	var first_clear: bool = not _dungeon_is_cleared(kind, tier)
	if first_clear:
		diamond += diamond_reward
		Contract.diamond_changed.emit(diamond)
		if not dungeon_cleared.has(str(kind)):
			dungeon_cleared[str(kind)] = {}
		dungeon_cleared[str(kind)][str(tier)] = true
		Contract.dungeon_cleared_changed.emit(get_dungeon_status())
	# 该档掉落资源（exp 分支用本局上阵名单）
	var rewards := _grant_dungeon_reward(kind, tier, battle.mech_ids)
	# 秘境胜利经验：进入全局经验池（v0.19；可重复玩法胜利给经验）
	exp_balance += 10 + tier * 10
	Contract.exp_balance_updated.emit(exp_balance)
	Contract.dungeon_reward.emit(kind, tier, rewards)
	# last_clear 仅供主线通关显示（主界面"上次通关"），秘境反馈已走 dungeon_reward 信号，不写 last_clear
	_gain_battle_affinity()  # v0.17：出战胜利好感 +1
	Save.save_game()

## 失败：发 battle_failed → 停止战斗，可重试
## 生存模式：我方全灭 → 按波数结算（v0.21）
## 秘境挑战失败：全额返还已扣体力（v0.20 裁决：重试不重复扣，成功/扫荡才真正消耗）
## 每日BOSS 战失败：按伤害结算（v0.20）
func _resolve_defeat() -> void:
	battle.active = false
	battle_timer.stop()
	if battle.mode == &"survival":
		_settle_survival_end()
		return
	if battle.mode == &"boss":
		_resolve_boss_end()
		return
	if battle.mode == &"dungeon" and not battle.dungeon_ctx.is_empty():
		var cost: int = int(battle.dungeon_ctx.cost)
		if cost > 0:
			stamina = mini(stamina + cost, Data.STAMINA_MAX)
			Contract.stamina_changed.emit(stamina)
	Contract.battle_failed.emit(int(battle.level))

## 挂机节拍：每秒累入"待收获金币 + 待收获经验"并发 idle_rewards_updated（契约 §1.2 / §3.5，v0.4 / v0.6）
## 金币、经验都不自动进账，等待玩家点收获一次性领取（金币入账、经验入全局余额）；
## idle_last_time 同步推进供离线补算。
func _on_idle_tick() -> void:
	var rate: float = _idle_gold_rate()
	idle_pending += rate
	idle_pending_exp += rate * Data.IDLE_EXP_RATIO
	idle_last_time = int(Time.get_unix_time_from_system())
	Contract.idle_rewards_updated.emit(roundi(idle_pending), roundi(idle_pending_exp))
	# v0.13：体力自然恢复结算（满上限停止）+ 每日重置检查
	_check_daily_reset()
	_recover_stamina()
	# v0.16：战力达标类新手任务检查
	_refresh_novice_power()
	# 待收获金额（金币+经验）+ 时间戳自动存档节流（契约 §3.2 / §3.6：每 5 秒一次，间隔数值在 Data）
	_idle_save_accum += Data.IDLE_TICK_INTERVAL
	if _idle_save_accum >= Data.SAVE_THROTTLE_INTERVAL:
		_idle_save_accum = 0.0
		Save.save_game()

## ---------------------------------------------------------------
## 领取待收获（契约 §3.6 入口，v0.6）：金币入账、经验入全局经验余额 → 清零 →
## 更新时间戳 → 发 gold_changed + exp_balance_updated + idle_rewards_updated(0,0) → 自动存档
## 签名：collect_idle()
## ---------------------------------------------------------------
func collect_idle() -> void:
	var amount: int = roundi(idle_pending)
	var exp_amount: int = roundi(idle_pending_exp)
	if amount > 0:
		gold += amount
		Contract.gold_changed.emit(gold)
	if exp_amount > 0:
		exp_balance += exp_amount
		Contract.exp_balance_updated.emit(exp_balance)
	idle_pending = 0.0
	idle_pending_exp = 0.0
	idle_last_time = int(Time.get_unix_time_from_system())
	Contract.idle_rewards_updated.emit(0, 0)
	_bump_task("daily", &"collect_idle")  # 任务钩子（v0.16）：收获
	Save.save_game()

## ---------------------------------------------------------------
## 中止当前战斗（契约 §3.6 入口，v0.5）：返回主界面时先调用；可重进重打。
## 幂等：非战斗状态调用无副作用；战斗不会在后台继续。
## 签名：stop_battle()
## ---------------------------------------------------------------
func stop_battle() -> void:
	if battle.active:
		battle.active = false
		battle_timer.stop()

## ---------------------------------------------------------------
## 只读：该机娘当前等级升下一级所需金币（契约 §3.6 入口，v0.5；
## 复用内部 _upgrade_cost，与 upgrade() 判定逻辑一致，不修改任何数值）
## 签名：upgrade_cost(mech_id: StringName) -> int
## ---------------------------------------------------------------
func upgrade_cost(mech_id: StringName) -> int:
	return _upgrade_cost(mech_id, int(mech_levels.get(mech_id, 1)))

## ---------------------------------------------------------------
## 只读：该机娘当前等级升下一级所需经验（契约 §3.6 入口，v0.5；
## 复用内部 _upgrade_exp_cost，与 upgrade() 判定逻辑一致，不修改任何数值）
## 签名：upgrade_exp_cost(mech_id: StringName) -> int
## ---------------------------------------------------------------
func upgrade_exp_cost(mech_id: StringName) -> int:
	return _upgrade_exp_cost(mech_id, int(mech_levels.get(mech_id, 1)))

## 挂机金币速率：基础每秒 × 1.25^(已首通关卡数)（设计文档 §8.4）
func _idle_gold_rate() -> float:
	return float(Data.IDLE_GOLD_BASE) * pow(float(Data.IDLE_GOLD_GROWTH), float(cleared_levels.size()))

## 已拥有机娘 id 列表（按 Data.MECH_GIRLS 声明顺序；契约 §3.8 v0.7）
func _owned_mech_ids() -> Array:
	var ids: Array = []
	for mech_id in Data.MECH_GIRLS:
		if owned_mechs.has(mech_id):
			ids.append(mech_id)
	return ids

## ---------------------------------------------------------------
## 抽卡（契约 §3.6 / §3.8 入口，v0.7）
## 签名：summon(pool: StringName, times: int)
## 流程：校验 → 计费（免费十连 / 新手池半价 / 全价；钻石不足失败）→ 按概率抽
##       → 保底处理（80 抽 SSR / 十连 SR / 新手池首十连星澜）→ 新机娘入拥有、
##       重复转碎片 → 发 diamond_changed / fragments_updated / owned_mechs_updated /
##       gacha_result → 自动存档
## ---------------------------------------------------------------
func summon(pool: StringName, times: int) -> void:
	if not Data.SUMMON_POOLS.has(pool):
		return
	if times != 1 and times != 10:
		return
	var cost: int = _summon_cost(pool, times)
	# 召唤券优先抵扣（1 券 = 300 钻 = 1 抽，v0.10）：先扣券，不足部分扣钻石
	var ticket_use: int = 0
	var diamond_need: int = cost
	if cost > 0:
		ticket_use = mini(summon_ticket, floori(float(cost) / float(Data.SUMMON_TICKET_VALUE)))
		diamond_need = cost - ticket_use * Data.SUMMON_TICKET_VALUE
	if diamond_need > diamond:
		return  # 钻石不足：失败不发信号
	# 计费状态消耗：免费十连优先（不耗新手池半价次数），否则新手池半价扣次数
	if times == 10 and novice_free_pull:
		novice_free_pull = false
	elif pool == &"novice" and novice_pool_left > 0:
		novice_pool_left -= 1
	if cost > 0:
		summon_ticket -= ticket_use
		diamond -= diamond_need
		Contract.diamond_changed.emit(diamond)
	var pool_cfg: Dictionary = Data.SUMMON_POOLS[pool]
	var use_limited: bool = pool == &"limited"
	# 新手池首十连保底：本次十连第 10 张必出保底位（星澜；仅新手池）
	var first_ten_pity: bool = (pool == &"novice" and times == 10 and not novice_first_ten_done)
	if first_ten_pity:
		novice_first_ten_done = true
	# 累计抽卡次数（成就 progress 用，v0.17）
	_total_summon_count += times
	# 1. 生成原始结果 id 列表（含 SSR 80 保底 / 首十连保底；限定池独立保底）
	var raw_ids: Array = []
	for i in times:
		raw_ids.append(_roll_with_pity(pool_cfg, first_ten_pity and i == times - 1, use_limited))
	# 2. 十连 SR 保底：十连内无 SR+ 则最后一张补为 SR（设计文档 §4.5）
	if times == 10 and not _ids_contain_sr_plus(raw_ids):
		raw_ids[times - 1] = _random_member_of_rarity(pool_cfg, Data.Rarity.SR)
	# 3. 应用结果：新机娘入拥有（初始化成长）、重复转碎片
	var entries: Array = []
	var got_new := false
	for mech_id in raw_ids:
		var entry := _apply_summon_result(StringName(mech_id))
		entries.append(entry)
		if bool(entry.is_new):
			got_new = true
	# 4. 结果信号 + 自动存档
	if got_new:
		Contract.owned_mechs_updated.emit(_owned_mech_ids())
	Contract.gacha_result.emit(entries)
	# 任务钩子（v0.16）：抽卡
	_bump_task("daily", &"summon")
	_bump_task("weekly", &"summon_total")
	_bump_novice(&"summon_count")
	# v0.17：抽卡成就自动检查
	_check_achievements()
	Save.save_game()

## 单抽内部：SSR 80 保底累计 + 按概率抽一个机娘（契约 §3.8）
## use_limited：限定池使用独立保底 limited_pity（80 抽必 SSR，出 SSR 重置，跨期保留，v0.20）
func _roll_with_pity(pool_cfg: Dictionary, force_first_ten: bool, use_limited: bool = false) -> StringName:
	if force_first_ten:
		# 首十连保底位必出（保底位为 SSR，出 SSR 重置保底计数；仅新手池）
		pity = 0
		return StringName(pool_cfg.first_ten_pity)
	if use_limited:
		limited_pity += 1
		var mech_id: StringName = _roll_summon(pool_cfg, true)
		var lcfg: Dictionary = Data.MECH_GIRLS[mech_id]
		if int(lcfg.rarity) == Data.Rarity.SSR:
			limited_pity = 0
		elif limited_pity >= Data.SUMMON_PITY_SSR_LIMIT:
			# 限定池 80 抽必出 SSR（UP 概率判定）
			mech_id = _limited_ssr(pool_cfg)
			limited_pity = 0
		return mech_id
	pity += 1
	var mech_id: StringName = _roll_summon(pool_cfg, false)
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	if int(cfg.rarity) == Data.Rarity.SSR:
		pity = 0
	elif pity >= Data.SUMMON_PITY_SSR_LIMIT:
		# 每 80 抽必出 ≥1 SSR：强制补一张 SSR 并重置
		mech_id = _random_member_of_rarity(pool_cfg, Data.Rarity.SSR)
		pity = 0
	return mech_id

## 按稀有度占比（SSR 3% / SR 17% / R 80%）随机抽一个池内成员
## use_limited：SSR 档按 up_rate 概率出 UP 机娘（v0.20）
func _roll_summon(pool_cfg: Dictionary, use_limited: bool = false) -> StringName:
	var roll: float = randf()
	if roll < Data.SUMMON_RATE_SSR:
		if use_limited:
			return _limited_ssr(pool_cfg)
		return _random_member_of_rarity(pool_cfg, Data.Rarity.SSR)
	elif roll < Data.SUMMON_RATE_SSR + Data.SUMMON_RATE_SR:
		return _random_member_of_rarity(pool_cfg, Data.Rarity.SR)
	return _random_member_of_rarity(pool_cfg, Data.Rarity.R)

## 限定池 SSR 判定：up_rate 概率出 UP 机娘，否则池内其他 SSR（无其他则 UP）
func _limited_ssr(pool_cfg: Dictionary) -> StringName:
	if randf() < float(pool_cfg.get("up_rate", 0.5)):
		return StringName(pool_cfg.up_id)
	var up_id := StringName(str(pool_cfg.up_id))
	var candidates: Array = []
	for mech_id in pool_cfg.members:
		if int(Data.MECH_GIRLS[mech_id].rarity) == Data.Rarity.SSR and StringName(str(mech_id)) != up_id:
			candidates.append(mech_id)
	if candidates.is_empty():
		return up_id
	return StringName(candidates[randi() % candidates.size()])

## 池内某稀有度随机成员；池内无该稀有度（如新手池 SSR 仅保底位）时退回全池随机
func _random_member_of_rarity(pool_cfg: Dictionary, rarity: int) -> StringName:
	var candidates: Array = []
	for mech_id in pool_cfg.members:
		if int(Data.MECH_GIRLS[mech_id].rarity) == rarity:
			candidates.append(mech_id)
	if candidates.is_empty():
		candidates.assign(pool_cfg.members)
	return StringName(candidates[randi() % candidates.size()])

## 十连 SR 保底判定：结果中是否有 SR 及以上
func _ids_contain_sr_plus(ids: Array) -> bool:
	for mech_id in ids:
		if int(Data.MECH_GIRLS[mech_id].rarity) >= Data.Rarity.SR:
			return true
	return false

## 应用单抽结果：新机娘入拥有（初始化 Lv1 / 经验 0）；重复转碎片（R10/SR20/SSR50）
## 返回 gacha_result 单项：{ id, rarity, is_new, fragments }
func _apply_summon_result(mech_id: StringName) -> Dictionary:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var entry := { "id": mech_id, "rarity": int(cfg.rarity), "is_new": false, "fragments": 0 }
	if owned_mechs.has(mech_id):
		# 重复机娘 → 碎片（契约 §3.8 / 设计文档 §4.6）
		var convert: int = int(Data.FRAGMENT_CONVERT[int(cfg.rarity)])
		fragments[mech_id] = int(fragments.get(mech_id, 0)) + convert
		entry["fragments"] = convert
		Contract.fragments_updated.emit(mech_id, int(fragments[mech_id]))
	else:
		owned_mechs[mech_id] = true
		mech_levels[mech_id] = 1
		mech_stars[mech_id] = 1
		entry["is_new"] = true
		# v0.17：新机娘入图鉴（collection_changed）+ 成就/称号自动检查
		Contract.collection_changed.emit(_collection_count())
		_check_achievements()
		_check_titles()
	return entry

## ---------------------------------------------------------------
## 只读：该池该次数所需钻石（契约 §3.6 入口，v0.7；含免费十连 / 新手池半价）
## 签名：summon_cost(pool: StringName, times: int) -> int
## ---------------------------------------------------------------
func summon_cost(pool: StringName, times: int) -> int:
	return _summon_cost(pool, times)

## 内部计费：与 summon() 完全同源；免费十连 → 0；新手池有半价次数 → 半价
func _summon_cost(pool: StringName, times: int) -> int:
	if not Data.SUMMON_POOLS.has(pool):
		return 0
	if times != 1 and times != 10:
		return 0
	if times == 10 and novice_free_pull:
		return 0
	var base: int = Data.SUMMON_COST_SINGLE if times == 1 else Data.SUMMON_COST_TEN
	if pool == &"novice" and novice_pool_left > 0:
		return roundi(float(base) * Data.SUMMON_NOVICE_DISCOUNT)
	return base

## ---------------------------------------------------------------
## 只读：保底信息（契约 §3.6 入口，v0.7）
## 签名：summon_pity_info(pool: StringName) -> Dictionary（返回 {progress, remain}）
## 说明：限定池返回独立保底 limited_pity（v0.20）；其余池为全局 pity（跨池累计，出 SSR 重置）
## ---------------------------------------------------------------
func summon_pity_info(pool: StringName) -> Dictionary:
	var progress: int = limited_pity if pool == &"limited" else pity
	var remain: int = maxi(Data.SUMMON_PITY_SSR_LIMIT - progress, 0)
	return { "progress": progress, "remain": remain }

## ---------------------------------------------------------------
## 只读：已拥有机娘 id 列表（契约 §3.6 入口，v0.7）
## 签名：get_owned_mechs() -> Array
## ---------------------------------------------------------------
func get_owned_mechs() -> Array:
	return _owned_mech_ids()

## ---------------------------------------------------------------
## 只读：主线下一关（契约 §3.6 入口，v0.9 / 设计文档 v0.15）
## = 当前最高未通关的下一关（第一个未首通的关卡）；全部通关返回 MAX_LEVEL + 1（无下一关）
## 签名：get_next_level() -> int
## ---------------------------------------------------------------
func get_next_level() -> int:
	return _next_level()

## 内部：第一个未首通关卡
func _next_level() -> int:
	for l in range(1, Data.MAX_LEVEL + 1):
		if not cleared_levels.has(l):
			return l
	return Data.MAX_LEVEL + 1

## ---------------------------------------------------------------
## 布阵（契约 §3.6 / §3.9 入口，v0.8）：9 格选 ≤5，每格 {id, row, col}
## 校验：id 已拥有、row/col 0..2、格不重复、id 不重复
## 签名：set_formation(formation: Array)；生效后发 formation_changed
## ---------------------------------------------------------------
func set_formation(new_formation: Array) -> void:
	if not (new_formation is Array) or new_formation.size() > 5:
		return
	var slots: Array = []
	var used_cells := {}
	var used_ids := {}
	for slot in new_formation:
		if not (slot is Dictionary):
			return
		var mech_id := StringName(str(slot.get("id", "")))
		var row: int = int(slot.get("row", -1))
		var col: int = int(slot.get("col", -1))
		if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
			return
		if row < 0 or row > 2 or col < 0 or col > 2:
			return
		var cell := row * 3 + col
		if used_cells.has(cell) or used_ids.has(mech_id):
			return
		used_cells[cell] = true
		used_ids[mech_id] = true
		slots.append({ "id": mech_id, "row": row, "col": col })
	if slots.size() < 2:
		return
	formation = slots
	Contract.formation_changed.emit(formation)
	Save.save_game()

## ---------------------------------------------------------------
## 只读：当前阵型（契约 §3.6 入口，v0.8）
## 签名：get_formation() -> Array
## ---------------------------------------------------------------
func get_formation() -> Array:
	return formation

## ---------------------------------------------------------------
## 保存阵型预设（契约 §3.6 / §3.9 入口，v0.8）：index 0..2（2~3 套）
## 签名：save_formation_preset(index: int, formation: Array)
## ---------------------------------------------------------------
func save_formation_preset(index: int, preset_formation: Array) -> void:
	if index < 0 or index > 2:
		return
	if not (preset_formation is Array) or preset_formation.size() > 5:
		return
	# 复用 set_formation 的校验逻辑（静态校验，不应用）
	var slots: Array = []
	var used_cells := {}
	var used_ids := {}
	for slot in preset_formation:
		if not (slot is Dictionary):
			return
		var mech_id := StringName(str(slot.get("id", "")))
		var row: int = int(slot.get("row", -1))
		var col: int = int(slot.get("col", -1))
		if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
			return
		if row < 0 or row > 2 or col < 0 or col > 2:
			return
		var cell := row * 3 + col
		if used_cells.has(cell) or used_ids.has(mech_id):
			return
		used_cells[cell] = true
		used_ids[mech_id] = true
		slots.append({ "id": mech_id, "row": row, "col": col })
	if slots.size() < 2:
		return
	formation_presets[str(index)] = slots
	Save.save_game()

## ---------------------------------------------------------------
## 读取阵型预设并应用（契约 §3.6 / §3.9 入口，v0.8）
## 签名：load_formation_preset(index: int)
## ---------------------------------------------------------------
func load_formation_preset(index: int) -> void:
	if not formation_presets.has(str(index)):
		return
	set_formation(formation_presets[str(index)])

## ---------------------------------------------------------------
## 战斗 2x 加速开关（契约 §3.6 / §3.9 入口，v0.8；内存态，不入档）
## 签名：toggle_accelerate(on: bool)
## ---------------------------------------------------------------
func toggle_accelerate(on: bool) -> void:
	accelerate = on
	battle.accelerate = on
	if battle.active:
		_apply_battle_timer_speed()

## 按加速状态设置战斗节拍间隔（2x = 0.5 秒/轮）
func _apply_battle_timer_speed() -> void:
	if battle.active and bool(battle.accelerate):
		battle_timer.wait_time = Data.BATTLE_TICK_INTERVAL / 2.0
	else:
		battle_timer.wait_time = Data.BATTLE_TICK_INTERVAL

## ---------------------------------------------------------------
## 扫荡（契约 §3.6 / §3.9 入口，v0.8；v0.15 主线规则调整）
## 签名：sweep_level(level: int)
## v0.15：主线不允许扫荡（不可重打）——扫荡仅保留给秘境（阶段 3 实装）；
## 当前 1..MAX_LEVEL 全部为主线关卡，故一律拒绝（保留入口签名，秘境实装后复用）。
## ---------------------------------------------------------------
func sweep_level(level: int) -> void:
	if level >= 1 and level <= Data.MAX_LEVEL:
		Contract.battle_prompt.emit(&"skill", "主线不可扫荡")
		return
	var exp_gain: int = int(Data.LEVELS[level].victory_reward_exp)
	# 扫荡经验：进入全局经验池（v0.19）
	exp_balance += exp_gain
	Contract.exp_balance_updated.emit(exp_balance)
	var star: int = int(level_stars.get(level, 1))
	Contract.battle_star.emit(star)
	Contract.battle_prompt.emit(&"skill", "扫荡完成")
	Save.save_game()

## ---------------------------------------------------------------
## 只读：机娘战力（契约 §3.6 / §3.9 入口，v0.8）
## 公式：攻×4 + 血×1 + 防×6 + 速×5（设计文档 §10.1 / 附录 B）
## 签名：get_power(mech_id: StringName) -> int
## ---------------------------------------------------------------
func get_power(mech_id: StringName) -> int:
	if not Data.MECH_GIRLS.has(mech_id):
		return 0
	var s := _mech_stats(mech_id)
	return int(s.atk) * Data.POWER_ATK_W + int(s.hp) * Data.POWER_HP_W + int(s.def) * Data.POWER_DEF_W + int(s.spd) * Data.POWER_SPD_W

## ================================================================
## v0.14：装备 / 宝石 / 强化（契约 §3.11 / 设计文档 §2.6 / §10.6）
## ================================================================
## 装备实例：{uid, slot, star(1~5), level(0~10), gems:[{quality, affixes:[{stat,value}]}]}

## uid 生成（load 后扫描库存续号，保证刷新后不撞 uid）
func _gen_equip_uid() -> StringName:
	var uid := StringName("eq_" + str(_equip_uid_seed))
	_equip_uid_seed += 1
	return uid

func _init_equip_uid_seed() -> void:
	var max_seed := 0
	for eq in equip_inventory:
		var uid_str: String = str(eq.uid)
		if uid_str.begins_with("eq_"):
			max_seed = maxi(max_seed, uid_str.substr(3).to_int())
	_equip_uid_seed = max_seed + 1

## 按 uid 找装备（空字典 = 不存在）
func _find_equip(uid: StringName) -> Dictionary:
	for eq in equip_inventory:
		if StringName(str(eq.uid)) == uid:
			return eq
	return {}

## 该装备的穿戴者（空 = 未穿戴）
func _equip_wearer(uid: StringName) -> StringName:
	for mid in equipped:
		if equipped[mid].values().has(uid):
			return StringName(mid)
	return &""

func _is_equip_equipped(uid: StringName) -> bool:
	return not _equip_wearer(uid).is_empty()

## 生成装备实例（掉落用）
func _spawn_equip(slot: StringName, star: int) -> Dictionary:
	return { "uid": _gen_equip_uid(), "slot": slot, "star": clampi(star, 1, 5), "level": 0, "gems": [] }

## 随机部位
func _random_slot() -> StringName:
	var slots := Data.EQUIP_SLOTS.keys()
	return StringName(str(slots[randi() % slots.size()]))

## 穿戴后通知机娘属性变化（mech_girl_updated）
func _emit_mech_after_equip(mech_id: StringName) -> void:
	var s := _mech_stats(mech_id)
	Contract.mech_girl_updated.emit(mech_id, s.hp, s.atk, s.level)

## ---------------------------------------------------------------
## 穿装备（契约 §3.6 入口，v0.14）：任意机娘可穿任意装备；同部位旧装备自动卸下
## 签名：equip(mech_id: StringName, uid: StringName)
## ---------------------------------------------------------------
func equip(mech_id: StringName, uid: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	var eq := _find_equip(uid)
	if eq.is_empty() or _is_equip_equipped(uid):
		return
	var slot := StringName(str(eq.slot))
	if not equipped.has(mech_id):
		equipped[mech_id] = {}
	if equipped[mech_id].has(slot):
		equipped[mech_id].erase(slot)
	equipped[mech_id][slot] = uid
	Contract.equipped_changed.emit(equipped)
	_emit_mech_after_equip(mech_id)
	Save.save_game()

## ---------------------------------------------------------------
## 卸装备（契约 §3.6 入口，v0.14）
## 签名：unequip(mech_id: StringName, slot: StringName)
## ---------------------------------------------------------------
func unequip(mech_id: StringName, slot: StringName) -> void:
	if not equipped.has(mech_id) or not equipped[mech_id].has(slot):
		return
	equipped[mech_id].erase(slot)
	Contract.equipped_changed.emit(equipped)
	_emit_mech_after_equip(mech_id)
	Save.save_game()

## ---------------------------------------------------------------
## 只读：装备库（契约 §3.6 入口，v0.14）
## 签名：get_equip_inventory() -> Array
## ---------------------------------------------------------------
func get_equip_inventory() -> Array:
	return equip_inventory

## ---------------------------------------------------------------
## 只读：穿戴映射（契约 §3.6 入口，v0.14）
## 签名：get_equipped() -> Dictionary
## ---------------------------------------------------------------
func get_equipped() -> Dictionary:
	return equipped

## ---------------------------------------------------------------
## 只读：单件装备总属性面板（契约 §3.6 入口，v0.14；部位+强化+宝石）
## 签名：get_equip_stats(uid: StringName) -> Dictionary
## ---------------------------------------------------------------
func get_equip_stats(uid: StringName) -> Dictionary:
	var eq := _find_equip(uid)
	if eq.is_empty():
		return {}
	return _equip_total_stats(eq)

## ---------------------------------------------------------------
## 合成装备（契约 §3.6 入口，v0.14）：3 件同星（未穿戴）合 1 件高星
## 合成前自动拆下宝石回库存（宝石不丢）；结果 = 第一件部位、星级+1、强化归 0
## 签名：combine_equip(uids: Array)
## ---------------------------------------------------------------
func combine_equip(uids: Array) -> void:
	if not (uids is Array) or uids.size() != 3:
		return
	var eqs: Array = []
	var star: int = -1
	for uid in uids:
		var eq := _find_equip(StringName(str(uid)))
		if eq.is_empty() or _is_equip_equipped(StringName(str(uid))):
			return
		if star == -1:
			star = int(eq.star)
		elif int(eq.star) != star:
			return
		eqs.append(eq)
	if star < 1 or star >= 5:
		return
	# 拆宝石回库存
	for eq in eqs:
		_unsocket_all_gems(eq)
	var new_slot := StringName(str(eqs[0].slot))
	for eq in eqs:
		equip_inventory.erase(eq)
	var new_eq := _spawn_equip(new_slot, star + 1)
	equip_inventory.append(new_eq)
	Contract.equip_inventory_changed.emit(equip_inventory)
	Contract.gem_stock_changed.emit(gem_stock)
	Save.save_game()

func _unsocket_all_gems(eq: Dictionary) -> void:
	for g in eq.gems:
		var quality := StringName(str(g.quality))
		gem_stock[quality] = int(gem_stock.get(quality, 0)) + 1
	eq.gems = []

## ---------------------------------------------------------------
## 只读：强化费用（契约 §3.6 入口，v0.14；金币 + 材料 material_common）
## 签名：upgrade_equip_cost(uid: StringName) -> Dictionary（{gold, material}）
## ---------------------------------------------------------------
func upgrade_equip_cost(uid: StringName) -> Dictionary:
	var eq := _find_equip(uid)
	if eq.is_empty() or int(eq.level) >= Data.ENCHANT_MAX_LEVEL:
		return { "gold": 0, "material": 0 }
	var level: int = int(eq.level)
	var gold_cost: int = roundi(float(Data.ENCHANT_GOLD_BASE) * pow(Data.ENCHANT_GOLD_GROWTH, float(level)))
	return { "gold": gold_cost, "material": Data.ENCHANT_MATERIAL_PER_LEVEL }

## ---------------------------------------------------------------
## 强化（契约 §3.6 入口，v0.14）：+1~+10，扣金币 + material_common，属性比例成长
## 签名：upgrade_equip(uid: StringName)
## ---------------------------------------------------------------
func upgrade_equip(uid: StringName) -> void:
	var cost := upgrade_equip_cost(uid)
	if int(cost.gold) <= 0:
		return
	var mat: int = int(bag["items"].get("material_common", 0))
	if gold < int(cost.gold) or mat < int(cost.material):
		return
	gold -= int(cost.gold)
	bag["items"]["material_common"] = mat - int(cost.material)
	var eq := _find_equip(uid)
	eq.level = int(eq.level) + 1
	Contract.gold_changed.emit(gold)
	Contract.bag_updated.emit(bag["items"], int(bag["capacity"]))
	Contract.equip_inventory_changed.emit(equip_inventory)
	var wearer := _equip_wearer(uid)
	if not wearer.is_empty():
		_emit_mech_after_equip(wearer)
	# 任务钩子（v0.16）：装备强化 + 战力任务刷新
	_bump_novice(&"enchant_count")
	_refresh_novice_power()
	Save.save_game()

## ---------------------------------------------------------------
## 镶嵌宝石（契约 §3.6 入口，v0.14）：扣库存 → 随机词条（保底 1、50% 概率第 2 条）→ 入孔
## 签名：socket_gem(uid: StringName, quality: StringName)
## ---------------------------------------------------------------
func socket_gem(uid: StringName, quality: StringName) -> void:
	var eq := _find_equip(uid)
	if eq.is_empty():
		return
	var q_idx: int = Data.GEM_QUALITIES.find(quality)
	if q_idx < 0 or int(gem_stock.get(quality, 0)) <= 0:
		return
	var star: int = int(eq.star)
	if eq.gems.size() >= int(Data.GEM_SOCKETS.get(star, 1)):
		return
	gem_stock[quality] = int(gem_stock.get(quality, 0)) - 1
	eq.gems.append({ "quality": quality, "affixes": _roll_gem_affixes(q_idx) })
	Contract.gem_stock_changed.emit(gem_stock)
	Contract.equip_inventory_changed.emit(equip_inventory)
	var wearer := _equip_wearer(uid)
	if not wearer.is_empty():
		_emit_mech_after_equip(wearer)
	Save.save_game()

## 生成宝石词条（保底 1 条、概率第 2 条；数值按品质区间）
func _roll_gem_affixes(quality_idx: int) -> Array:
	var affixes: Array = []
	var pool_keys := Data.GEM_AFFIX_POOL.keys()
	var first := StringName(str(pool_keys[randi() % pool_keys.size()]))
	var cfg1: Dictionary = Data.GEM_AFFIX_POOL[first]
	var r1: Array = cfg1.values[quality_idx]
	affixes.append({ "stat": first, "value": float(r1[0]) + randf() * (float(r1[1]) - float(r1[0])) })
	if randf() < Data.GEM_SECOND_AFFIX_CHANCE:
		var second := StringName(str(pool_keys[randi() % pool_keys.size()]))
		var cfg2: Dictionary = Data.GEM_AFFIX_POOL[second]
		var r2: Array = cfg2.values[quality_idx]
		affixes.append({ "stat": second, "value": float(r2[0]) + randf() * (float(r2[1]) - float(r2[0])) })
	return affixes

## ---------------------------------------------------------------
## 拆卸宝石（契约 §3.6 入口，v0.14）：免费拆卸，品级返还库存（词条丢弃）
## 签名：unsocket_gem(uid: StringName, idx: int)
## ---------------------------------------------------------------
func unsocket_gem(uid: StringName, idx: int) -> void:
	var eq := _find_equip(uid)
	if eq.is_empty() or idx < 0 or idx >= eq.gems.size():
		return
	var g: Dictionary = eq.gems[idx]
	var quality := StringName(str(g.quality))
	gem_stock[quality] = int(gem_stock.get(quality, 0)) + 1
	eq.gems.remove_at(idx)
	Contract.gem_stock_changed.emit(gem_stock)
	Contract.equip_inventory_changed.emit(equip_inventory)
	var wearer := _equip_wearer(uid)
	if not wearer.is_empty():
		_emit_mech_after_equip(wearer)
	Save.save_game()

## ---------------------------------------------------------------
## 只读：宝石库存（契约 §3.6 入口，v0.14）
## 签名：get_gem_stock() -> Dictionary
## ---------------------------------------------------------------
func get_gem_stock() -> Dictionary:
	return gem_stock

## ---------------------------------------------------------------
## 宝石合成（契约 §3.6 入口，v0.14）：3 个同品质合 1 个高品（红最高不可合）
## 签名：combine_gems(quality: StringName)
## ---------------------------------------------------------------
func combine_gems(quality: StringName) -> void:
	var q_idx: int = Data.GEM_QUALITIES.find(quality)
	if q_idx < 0 or q_idx >= Data.GEM_QUALITIES.size() - 1:
		return
	if int(gem_stock.get(quality, 0)) < 3:
		return
	gem_stock[quality] = int(gem_stock.get(quality, 0)) - 3
	var next_q := StringName(str(Data.GEM_QUALITIES[q_idx + 1]))
	gem_stock[next_q] = int(gem_stock.get(next_q, 0)) + 1
	Contract.gem_stock_changed.emit(gem_stock)
	Save.save_game()

## ================================================================
## v0.13：体力（契约 §3.10 / 设计文档 §3.8）
## ================================================================
## 只读：当前体力（先做每日重置 + 离线/在线恢复结算）
func get_stamina() -> int:
	_check_daily_reset()
	_recover_stamina()
	return stamina

## 每日重置（v0.16 扩展：跨日清体力购买/爬塔日限/每日任务/签到断签；每周一清周任务）
func _check_daily_reset() -> void:
	var today: String = Time.get_date_string_from_system()
	if last_reset_day == today:
		return
	# 跨日：清体力购买次数 / 爬塔日限 / 每日任务
	stamina_buy_count = 0
	tower_daily_count = 0
	task_daily = { "progress": {}, "claimed": [] }
	# 签到：昨天没签 → 断签归 0
	if sign_last_day != _date_offset(today, -1):
		sign_days = 0
	# 每周一重置周任务（每天只处理一次，防重复清）
	var weekday: int = int(Time.get_date_dict_from_system()["weekday"])
	if weekday == 1:
		task_weekly = { "progress": {}, "claimed": [] }
	last_reset_day = today

## 日期偏移（YYYY-MM-DD ± N 天）
func _date_offset(date_str: String, offset_days: int) -> String:
	var ts: int = int(Time.get_unix_time_from_datetime_string(date_str + "T00:00:00"))
	return Time.get_date_string_from_unix_time(ts + offset_days * 86400)

## 读档任务存储（progress 只认任务表 key）
func _load_task_store(store: Dictionary, src: Variant) -> void:
	if not (src is Dictionary):
		return
	var progress: Variant = src.get("progress", {})
	if progress is Dictionary:
		for task_id in progress:
			store["progress"][str(task_id)] = maxi(int(progress[task_id]), 0)
	var claimed: Variant = src.get("claimed", [])
	if claimed is Array:
		for tier in claimed:
			store["claimed"].append(int(tier))

## 体力恢复结算：按"现在-上次"补入（满上限停止，不溢出）
func _recover_stamina() -> void:
	var now: int = int(Time.get_unix_time_from_system())
	if stamina >= Data.STAMINA_MAX:
		stamina_last_time = now
		return
	var elapsed: int = maxi(now - stamina_last_time, 0)
	stamina_last_time = now
	if elapsed <= 0:
		return
	var gained: int = int(elapsed / Data.STAMINA_RECOVER_SECONDS)
	if gained <= 0:
		return
	var before: int = stamina
	stamina = mini(stamina + gained, Data.STAMINA_MAX)
	if stamina != before:
		Contract.stamina_changed.emit(stamina)

## 买体力（契约 §3.6 入口，v0.13）：扣 50 钻石回满，每日限 3 次
func buy_stamina() -> void:
	_check_daily_reset()
	_recover_stamina()
	if stamina_buy_count >= Data.STAMINA_BUY_LIMIT:
		return
	if diamond < Data.STAMINA_BUY_COST:
		return
	diamond -= Data.STAMINA_BUY_COST
	stamina_buy_count += 1
	stamina = Data.STAMINA_MAX
	stamina_last_time = int(Time.get_unix_time_from_system())
	Contract.diamond_changed.emit(diamond)
	Contract.stamina_changed.emit(stamina)
	Save.save_game()

## ================================================================
## v0.13：秘境（契约 §3.10 / 设计文档 §10.1）
## ================================================================
## 只读：{stamina 所需体力（首免 0/重试 10）, power_req 战力门槛, cleared 是否已通关}
func dungeon_cost(kind: StringName, tier: int) -> Dictionary:
	if not Data.DUNGEONS.has(kind) or tier < 0 or tier >= Data.DUNGEONS[kind].tiers.size():
		return { "stamina": 0, "power_req": 0, "cleared": true }
	var tier_cfg: Dictionary = Data.DUNGEONS[kind].tiers[tier]
	var cleared: bool = _dungeon_is_cleared(kind, tier)
	var cost: int = 0
	if cleared:
		cost = Data.STAMINA_DUNGEON_COST
	elif _dungeon_is_attempted(kind, tier):
		cost = Data.STAMINA_DUNGEON_COST  # 重试（失败返还）
	return { "stamina": cost, "power_req": int(tier_cfg.power_req), "cleared": cleared }

## 只读：全部副本通关状态 {kind: {tier: {cleared, power_req}}}
func get_dungeon_status() -> Dictionary:
	var status := {}
	for kind in Data.DUNGEONS:
		var kind_status := {}
		var tiers: Array = Data.DUNGEONS[kind].tiers
		for i in tiers.size():
			kind_status[str(i)] = {
				"cleared": _dungeon_is_cleared(kind, i),
				"power_req": int(tiers[i].power_req),
			}
		status[str(kind)] = kind_status
	return status

## 进入秘境战斗（契约 §3.6 入口，v0.13）：限未通关档；预扣体力（首免 0，失败返还）；
## 上阵战力 ≥ 门槛；battle.mode = "dungeon"
func start_dungeon(kind: StringName, tier: int) -> void:
	if not Data.DUNGEONS.has(kind) or tier < 0 or tier >= Data.DUNGEONS[kind].tiers.size():
		return
	if _dungeon_is_cleared(kind, tier):
		return
	var cost: int = dungeon_cost(kind, tier).stamina
	if stamina < cost:
		return
	if _team_power() < int(Data.DUNGEONS[kind].tiers[tier].power_req):
		return
	if cost > 0:
		stamina -= cost
		Contract.stamina_changed.emit(stamina)
	_dungeon_mark_attempted(kind, tier)
	# 任务钩子（v0.16）：挑战秘境
	_bump_task("daily", &"dungeon")
	_bump_novice(&"dungeon_count")
	_start_dungeon_battle(kind, tier, cost)

## 构建秘境战斗（敌方按档位配置 waves，单波）
func _start_dungeon_battle(kind: StringName, tier: int, cost: int) -> void:
	if formation.size() < 2:
		_ensure_default_formation()
	var tier_cfg: Dictionary = Data.DUNGEONS[kind].tiers[tier]
	battle = {
		"level": 0,
		"tick": 0,
		"active": true,
		"mode": &"dungeon",
		"dungeon_ctx": { "kind": str(kind), "tier": tier, "cost": cost },
		"wave": 1,
		"total_waves": 1,
		"mechs": [],
		"enemies": [],
		"pending_waves": [],
		"deaths": 0,
		"mech_ids": [],
		"accelerate": accelerate,
	}
	var used_ids := {}
	for slot in formation:
		var mech_id := StringName(str(slot.id))
		if not owned_mechs.has(mech_id) or used_ids.has(mech_id):
			continue
		used_ids[mech_id] = true
		battle.mechs.append(_build_mech_unit(mech_id, int(slot.row), int(slot.col)))
		battle.mech_ids.append(mech_id)
	# 敌方波次：副本级 Data.DUNGEONS[kind].waves 按档位索引（每档 = 一波敌人数组），
	# 整波作为 pending_waves 一项（与主线结构一致：每项 = 一波敌人数组）
	battle.pending_waves = []
	battle.pending_waves.append(Data.DUNGEONS[kind].waves[tier])
	_spawn_wave(battle.pending_waves[0])
	battle.pending_waves.remove_at(0)
	_apply_passive_battle_start()
	Contract.battle_tick.emit(0)
	for m in battle.mechs:
		Contract.mech_girl_updated.emit(m.id, int(m.hp), int(m.atk), int(m.level))
		Contract.energy_changed.emit(&"mech", m.id, int(m.energy))
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, int(e.hp))
		Contract.energy_changed.emit(&"enemy", e.id, int(e.energy))
	Contract.wave_changed.emit(battle.wave, battle.total_waves)
	_apply_battle_timer_speed()
	battle_timer.start()

## 上阵战力合计（当前阵型）
func _team_power() -> int:
	var total := 0
	for slot in formation:
		var mid := StringName(str(slot.id))
		if owned_mechs.has(mid):
			var s := _mech_stats(mid)
			total += int(s.atk) * Data.POWER_ATK_W + int(s.hp) * Data.POWER_HP_W + int(s.def) * Data.POWER_DEF_W + int(s.spd) * Data.POWER_SPD_W
	return total

## 扫荡秘境已通关档（契约 §3.6 入口，v0.13）：扣 10 体力 → 直接发该档奖励（跳过战斗）
func sweep_dungeon(kind: StringName, tier: int) -> void:
	if not Data.DUNGEONS.has(kind) or tier < 0 or tier >= Data.DUNGEONS[kind].tiers.size():
		return
	if not _dungeon_is_cleared(kind, tier):
		return
	if stamina < Data.STAMINA_DUNGEON_COST:
		return
	stamina -= Data.STAMINA_DUNGEON_COST
	stamina_last_time = int(Time.get_unix_time_from_system())
	Contract.stamina_changed.emit(stamina)
	var rewards := _grant_dungeon_reward(kind, tier, _formation_mech_ids())
	Contract.dungeon_reward.emit(kind, tier, rewards)
	# 任务钩子（v0.16）：扫荡
	_bump_task("daily", &"dungeon_sweep")
	_bump_task("weekly", &"sweep_total")
	Save.save_game()

## 上阵机娘 id（当前阵型，含重复过滤）
func _formation_mech_ids() -> Array:
	var ids: Array = []
	for slot in formation:
		var mid := StringName(str(slot.id))
		if not ids.has(mid):
			ids.append(mid)
	return ids

func _dungeon_is_cleared(kind, tier: int) -> bool:
	return dungeon_cleared.has(str(kind)) and dungeon_cleared[str(kind)].has(str(tier))

func _dungeon_is_attempted(kind, tier: int) -> bool:
	return dungeon_attempted.has(str(kind)) and dungeon_attempted[str(kind)].has(str(tier))

func _dungeon_mark_attempted(kind, tier: int) -> void:
	if not dungeon_attempted.has(str(kind)):
		dungeon_attempted[str(kind)] = {}
	dungeon_attempted[str(kind)][str(tier)] = true

## 发放秘境该档掉落资源（按 reward.kind 入账并走既有信号）；返回展示用 rewards
func _grant_dungeon_reward(kind: StringName, tier: int, exp_ids: Array) -> Dictionary:
	var tier_cfg: Dictionary = Data.DUNGEONS[kind].tiers[tier]
	var reward_cfg: Dictionary = tier_cfg.reward
	var amount: int = int(reward_cfg.amount)
	match str(reward_cfg.kind):
		"gold":
			gold += amount
			Contract.gold_changed.emit(gold)
		"exp":
			# 经验副本掉落：进入全局经验池（v0.19）
			exp_balance += amount
			Contract.exp_balance_updated.emit(exp_balance)
		"material":
			bag["items"]["material"] = int(bag["items"].get("material", 0)) + amount
			Contract.bag_updated.emit(bag["items"], int(bag["capacity"]))
		"equip":
			# 真装备掉落（v0.14）：star 按档位（1~3 星），数量 amount
			for i in amount:
				var eq := _spawn_equip(_random_slot(), int(Data.DUNGEON_EQUIP_STAR_TIERS[tier]))
				equip_inventory.append(eq)
			Contract.equip_inventory_changed.emit(equip_inventory)
		"gem":
			# 真宝石掉落（v0.14）：品质按档位（白~紫）
			var q_idx: int = int(Data.DUNGEON_GEM_QUALITY_TIERS[tier])
			var q := StringName(str(Data.GEM_QUALITIES[q_idx]))
			gem_stock[q] = int(gem_stock.get(q, 0)) + amount
			Contract.gem_stock_changed.emit(gem_stock)
		"fragment":
			var target_id := _random_mech_of_rarity(Data.Rarity.R)
			fragments[target_id] = int(fragments.get(target_id, 0)) + amount
			Contract.fragments_updated.emit(target_id, int(fragments[target_id]))
	return { "kind": str(reward_cfg.kind), "amount": amount }

## ================================================================
## v0.13：背包（契约 §3.10 / 设计文档 §6）
## ================================================================
## 只读：{items, capacity}
func get_bag() -> Dictionary:
	return { "items": bag["items"], "capacity": int(bag["capacity"]) }

## 只读：下次扩容所需金币（满上限返回 0）
func expand_bag_cost() -> int:
	var capacity: int = int(bag["capacity"])
	if capacity >= Data.BAG_MAX_CAPACITY:
		return 0
	var times: int = (capacity - Data.BAG_START_CAPACITY) / Data.BAG_EXPAND_AMOUNT
	return Data.BAG_EXPAND_BASE_COST * int(pow(2.0, float(times)))

## 背包扩容（契约 §3.6 入口，v0.13）：扣金币 → +10 格 → 发 bag_updated + gold_changed
func expand_bag() -> void:
	var cost: int = expand_bag_cost()
	if cost <= 0 or gold < cost:
		return
	gold -= cost
	bag["capacity"] = mini(int(bag["capacity"]) + Data.BAG_EXPAND_AMOUNT, Data.BAG_MAX_CAPACITY)
	Contract.gold_changed.emit(gold)
	Contract.bag_updated.emit(bag["items"], int(bag["capacity"]))
	Save.save_game()

## ================================================================
## v0.13：开箱（契约 §3.10 / 设计文档 §7）
## ================================================================
## 只读：待开箱数
func get_box_count() -> int:
	return boxes

## 开 1 个宝箱（契约 §3.6 入口，v0.13）：按权重随机金币/材料/碎片并直接入账
func open_box() -> void:
	if boxes <= 0:
		return
	boxes -= 1
	var reward := _roll_box_reward()
	Contract.box_count_changed.emit(boxes)
	Contract.box_opened.emit(reward)
	Save.save_game()

## 开箱权重（设计文档 §7：金币 50% / 材料 35% / R 碎片 10% / SR 碎片 4% / SSR 碎片 1%）
func _roll_box_reward() -> Dictionary:
	var roll: float = randf()
	if roll < Data.BOX_WEIGHT_GOLD:
		gold += Data.BOX_GOLD_AMOUNT
		Contract.gold_changed.emit(gold)
		return { "type": "gold", "amount": Data.BOX_GOLD_AMOUNT }
	if roll < Data.BOX_WEIGHT_GOLD + Data.BOX_WEIGHT_MATERIAL:
		var mat: int = Data.BOX_MATERIAL_AMOUNT
		bag["items"]["material"] = int(bag["items"].get("material", 0)) + mat
		Contract.bag_updated.emit(bag["items"], int(bag["capacity"]))
		return { "type": "material", "amount": mat }
	var rarity: int = Data.Rarity.R
	if roll >= Data.BOX_WEIGHT_GOLD + Data.BOX_WEIGHT_MATERIAL + Data.BOX_WEIGHT_FRAGMENT_R + Data.BOX_WEIGHT_FRAGMENT_SR:
		rarity = Data.Rarity.SSR
	elif roll >= Data.BOX_WEIGHT_GOLD + Data.BOX_WEIGHT_MATERIAL + Data.BOX_WEIGHT_FRAGMENT_R:
		rarity = Data.Rarity.SR
	var mech_id := _random_mech_of_rarity(rarity)
	var amount: int = int(Data.BOX_FRAGMENT_AMOUNT[rarity])
	fragments[mech_id] = int(fragments.get(mech_id, 0)) + amount
	Contract.fragments_updated.emit(mech_id, int(fragments[mech_id]))
	return { "type": "fragment", "amount": amount, "mech_id": mech_id }

## 随机一位指定稀有度机娘（池内无该稀有度时全池随机）
func _random_mech_of_rarity(rarity: int) -> StringName:
	var candidates: Array = []
	for mech_id in Data.MECH_GIRLS:
		if int(Data.MECH_GIRLS[mech_id].rarity) == rarity:
			candidates.append(mech_id)
	if candidates.is_empty():
		for mech_id in Data.MECH_GIRLS:
			candidates.append(mech_id)
	return StringName(candidates[randi() % candidates.size()])

## ================================================================
## v0.15：设置（契约 §3.12 / 设计文档 §10.9 X24）
## ================================================================
## 只读：当前设置
func get_settings() -> Dictionary:
	return settings

## 修改设置（key 白名单 + 值域校验；生效后发 settings_changed + 存档）
func set_setting(key: StringName, value) -> void:
	var key_str: String = str(key)
	if not Data.SETTINGS_KEYS.has(key):
		return
	match key_str:
		"music_on", "sfx_on", "default_2x":
			if not (value is bool):
				return
		"music_volume", "sfx_volume":
			if not (value is float or value is int):
				return
			var v: float = float(value)
			if v < 0.0 or v > 1.0:
				return
		"language":
			if not (value is String) or not Data.SETTINGS_LANGUAGES.has(str(value)):
				return
	settings[key_str] = value
	Contract.settings_changed.emit(settings)
	Save.save_game()

## ================================================================
## v0.15：商城（契约 §3.12 / 设计文档 §5）
## ================================================================
## 跨日刷新：商城每日 0 点刷新（本地日期变化清当日已购）
func _check_shop_refresh() -> void:
	var today: String = Time.get_date_string_from_system()
	if shop_day != today:
		shop_day = today
		shop_bought.clear()

## 当日商品列表（含价格/内容）
func _shop_items_list() -> Array:
	var items: Array = []
	for item_id in Data.SHOP_ITEMS:
		var cfg: Dictionary = Data.SHOP_ITEMS[item_id]
		items.append({
			"id": item_id,
			"name": str(cfg.name),
			"cost_type": str(cfg.cost_type),
			"cost": int(cfg.cost),
			"reward": cfg.reward,
		})
	return items

## 只读：商城状态（当日商品 + 已购）
func get_shop_items() -> Dictionary:
	_check_shop_refresh()
	return { "items": _shop_items_list(), "bought": shop_bought }

## 购买商品（契约 §3.6 入口，v0.15）：校验存在/限购/货币 → 扣 → 发放 → shop_changed → 存档
func buy_shop_item(item_id: StringName) -> void:
	if not Data.SHOP_ITEMS.has(item_id):
		return
	_check_shop_refresh()
	if shop_bought.has(str(item_id)):
		return  # 每商品每日限购 1 次
	var cfg: Dictionary = Data.SHOP_ITEMS[item_id]
	var cost: int = int(cfg.cost)
	if str(cfg.cost_type) == "diamond":
		if diamond < cost:
			return
		diamond -= cost
		Contract.diamond_changed.emit(diamond)
	else:
		if gold < cost:
			return
		gold -= cost
		Contract.gold_changed.emit(gold)
	# 发放内容
	_grant_shop_reward(cfg.reward)
	shop_bought[str(item_id)] = true
	Contract.shop_changed.emit(_shop_items_list(), shop_bought)
	Save.save_game()

## 发放商品内容（金币/体力/装备/宝石/碎片；入账走既有信号）
func _grant_shop_reward(reward: Dictionary) -> void:
	var amount: int = int(reward.amount)
	match str(reward.kind):
		"gold":
			gold += amount
			Contract.gold_changed.emit(gold)
		"stamina":
			var before: int = stamina
			stamina = mini(stamina + amount, Data.STAMINA_MAX)
			if stamina != before:
				Contract.stamina_changed.emit(stamina)
		"equip":
			for i in amount:
				equip_inventory.append(_spawn_equip(_random_slot(), 1 + randi() % 2))
			Contract.equip_inventory_changed.emit(equip_inventory)
		"gem":
			var q_idx: int = randi() % 2  # 白/绿
			var q := StringName(str(Data.GEM_QUALITIES[q_idx]))
			gem_stock[q] = int(gem_stock.get(q, 0)) + amount
			Contract.gem_stock_changed.emit(gem_stock)
		"fragment":
			var target_id := _random_mech_of_rarity(Data.Rarity.R)
			fragments[target_id] = int(fragments.get(target_id, 0)) + amount
			Contract.fragments_updated.emit(target_id, int(fragments[target_id]))

## ================================================================
## v0.15：重置存档（契约 §3.6 入口；UI 调用前必须二次确认）
## 清档 → 重置为新档默认 → 写默认档 → 重发全套初始信号
## ================================================================
func reset_save() -> void:
	Save.clear_save()
	_load_initial_state()
	Save.save_game()
	_emit_initial_state()

## ================================================================
## v0.16：爬塔（契约 §3.13 / 设计文档 §10.2）
## ================================================================
## 进入爬塔下一层（契约 §3.6 入口，v0.16）：不耗体力、每日 30 层上限；
## 挑战当前最高未通关层（tower_highest + 1）；battle.mode = "tower"
func start_tower() -> void:
	_check_daily_reset()
	if tower_daily_count >= Data.TOWER_DAILY_LIMIT:
		return
	_start_tower_battle(tower_highest + 1)

## 构建爬塔战斗（每层一波敌人、强度随层数）
func _start_tower_battle(layer: int) -> void:
	if formation.size() < 2:
		_ensure_default_formation()
	var growth: float = pow(Data.TOWER_ENEMY_GROWTH, float(layer - 1))
	var atk: int = roundi(float(Data.TOWER_ENEMY_BASE_ATK) * growth)
	var hp: int = roundi(float(Data.TOWER_ENEMY_BASE_HP) * growth)
	var def: int = Data.TOWER_ENEMY_BASE_DEF + int(layer / 5)
	var spd: int = Data.TOWER_ENEMY_BASE_SPD + int(layer / 10)
	var enemy_count: int = 1 if layer % 5 != 0 else 2
	var wave_cfg: Array = []
	for i in enemy_count:
		wave_cfg.append({
			"id": StringName("tower_e" + str(layer) + "_" + str(i)),
			"name": "爬塔守层兵",
			"tier": "normal",
			"class": "fighter",
			"atk": atk, "hp": hp, "def": def, "spd": spd,
			"skills": [&"enemy_shot"],
		})
	battle = {
		"level": 0,
		"tick": 0,
		"active": true,
		"mode": &"tower",
		"dungeon_ctx": { "layer": layer },
		"wave": 1,
		"total_waves": 1,
		"mechs": [], "enemies": [], "pending_waves": [],
		"deaths": 0, "mech_ids": [], "accelerate": accelerate,
	}
	var used_ids := {}
	for slot in formation:
		var mech_id := StringName(str(slot.id))
		if not owned_mechs.has(mech_id) or used_ids.has(mech_id):
			continue
		used_ids[mech_id] = true
		battle.mechs.append(_build_mech_unit(mech_id, int(slot.row), int(slot.col)))
		battle.mech_ids.append(mech_id)
	_spawn_wave(wave_cfg)
	_apply_passive_battle_start()
	Contract.battle_tick.emit(0)
	for m in battle.mechs:
		Contract.mech_girl_updated.emit(m.id, int(m.hp), int(m.atk), int(m.level))
		Contract.energy_changed.emit(&"mech", m.id, int(m.energy))
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, int(e.hp))
		Contract.energy_changed.emit(&"enemy", e.id, int(e.energy))
	Contract.wave_changed.emit(1, 1)
	_apply_battle_timer_speed()
	battle_timer.start()

## 爬塔胜利：层+1 / 日+1 → 普通层奖励 → 每 10 层大奖 → 任务钩子 → tower_changed
func _resolve_tower_victory() -> void:
	battle.active = false
	battle_timer.stop()
	var layer: int = int(battle.dungeon_ctx.layer)
	tower_highest = maxi(tower_highest, layer)
	tower_daily_count += 1
	# 普通层奖励：金币 + 经验（进全局池，v0.19）
	gold += Data.TOWER_NORMAL_GOLD_BASE + layer * Data.TOWER_NORMAL_GOLD_PER_LEVEL
	Contract.gold_changed.emit(gold)
	exp_balance += Data.TOWER_NORMAL_EXP_BASE + layer
	Contract.exp_balance_updated.emit(exp_balance)
	# 每 10 层大奖（钻石/召唤券/宝石）
	if layer % 10 == 0:
		var ten: int = int(layer / 10)
		diamond += Data.TOWER_GRAND_DIAMOND_BASE + (ten - 1) * Data.TOWER_GRAND_DIAMOND_PER
		Contract.diamond_changed.emit(diamond)
		if ten >= 1:
			summon_ticket += ten
		if layer >= Data.TOWER_GRAND_GEM_EVERY:
			gem_stock[&"white"] = int(gem_stock.get(&"white", 0)) + int(layer / Data.TOWER_GRAND_GEM_EVERY)
			Contract.gem_stock_changed.emit(gem_stock)
	# 任务钩子
	_bump_task("daily", &"tower")
	_bump_task("weekly", &"tower_total")
	_bump_novice(&"tower_count")
	# v0.17：出战胜利好感 +1 + 成就/称号自动检查
	_gain_battle_affinity()
	_check_achievements()
	_check_titles()
	Contract.tower_changed.emit(tower_highest, tower_daily_count)
	Save.save_game()

## 只读：爬塔信息（契约 §3.6 入口，v0.16）
func get_tower_info() -> Dictionary:
	_check_daily_reset()
	return { "highest": tower_highest, "daily_count": tower_daily_count, "daily_limit": Data.TOWER_DAILY_LIMIT }

## ================================================================
## v0.16：每日签到（契约 §3.13 / 设计文档 §10.3）
## ================================================================
## 签到（契约 §3.6 入口，v0.16）：每日 1 次；连续签到累计，断签归 0；
## 每累计 7 天发额外奖（钻石/召唤券/宝石）
func sign_in() -> void:
	_check_daily_reset()
	var today: String = Time.get_date_string_from_system()
	if sign_last_day == today:
		return
	if sign_last_day == _date_offset(today, -1):
		sign_days += 1
	else:
		sign_days = 1
	sign_last_day = today
	gold += Data.SIGN_GOLD
	diamond += Data.SIGN_DIAMOND
	Contract.gold_changed.emit(gold)
	Contract.diamond_changed.emit(diamond)
	if sign_days % 7 == 0:
		diamond += Data.SIGN_7_DIAMOND
		summon_ticket += Data.SIGN_7_TICKET
		gem_stock[&"white"] = int(gem_stock.get(&"white", 0)) + Data.SIGN_7_GEM
		Contract.diamond_changed.emit(diamond)
		Contract.gem_stock_changed.emit(gem_stock)
	_bump_task("daily", &"sign")
	Contract.sign_changed.emit(sign_days)
	Save.save_game()

## 只读：签到信息（契约 §3.6 入口，v0.16）
func get_sign_info() -> Dictionary:
	_check_daily_reset()
	return { "days": sign_days, "last_day": sign_last_day, "today_signed": sign_last_day == Time.get_date_string_from_system() }

## ================================================================
## v0.16：每日/周任务（契约 §3.13 / 设计文档 §10.3）
## ================================================================
## 任务进度累计（各动作处调用；达标才计活跃度）
func _bump_task(scope: String, task_id: StringName, amount: int = 1) -> void:
	var store: Dictionary = task_daily if scope == "daily" else task_weekly
	var key: String = str(task_id)
	store["progress"][key] = int(store["progress"].get(key, 0)) + amount
	Contract.task_changed.emit(task_daily, task_weekly)

## 当前活跃度（达标任务的活跃度之和）
func _task_active(scope: String) -> int:
	var tasks: Dictionary = Data.DAILY_TASKS if scope == "daily" else Data.WEEKLY_TASKS
	var store: Dictionary = task_daily if scope == "daily" else task_weekly
	var total := 0
	for task_id in tasks:
		if int(store["progress"].get(str(task_id), 0)) >= int(tasks[task_id].target):
			total += int(tasks[task_id].active)
	return total

## 领取任务档位奖励（契约 §3.6 入口，v0.16）：scope = "daily"/"weekly"
func claim_task_reward(scope: String, tier: int) -> void:
	if scope != "daily" and scope != "weekly":
		return
	var tiers: Dictionary = Data.DAILY_TASK_TIERS if scope == "daily" else Data.WEEKLY_TASK_TIERS
	if not tiers.has(tier):
		return
	var store: Dictionary = task_daily if scope == "daily" else task_weekly
	if store["claimed"].has(tier):
		return
	if _task_active(scope) < tier:
		return
	for reward in tiers[tier]:
		_grant_task_reward(reward)
	store["claimed"].append(tier)
	Contract.task_changed.emit(task_daily, task_weekly)
	_gain_commander_exp(Data.COMMANDER_EXP_TASK)  # v0.18：任务领奖给指挥官经验
	Save.save_game()

## 只读：任务信息（契约 §3.6 入口，v0.16）
func get_task_info() -> Dictionary:
	return { "daily": task_daily, "weekly": task_weekly }

## 发放任务/新手奖励（gold/diamond/ticket/gem/equip；入账走既有信号）
func _grant_task_reward(reward: Dictionary) -> void:
	match str(reward.type):
		"gold":
			gold += int(reward.amount)
			Contract.gold_changed.emit(gold)
		"diamond":
			diamond += int(reward.amount)
			Contract.diamond_changed.emit(diamond)
		"ticket":
			summon_ticket += int(reward.amount)
		"gem":
			var q := StringName(str(reward.get("quality", "white")))
			gem_stock[q] = int(gem_stock.get(q, 0)) + int(reward.amount)
			Contract.gem_stock_changed.emit(gem_stock)
		"equip":
			equip_inventory.append(_spawn_equip(_random_slot(), 1 + randi() % 2))
			Contract.equip_inventory_changed.emit(equip_inventory)

## ================================================================
## v0.16：新手 7 日任务（契约 §3.13 / 设计文档 §10.14）
## ================================================================
## 新手任务进度累计（各动作处调用）
func _bump_novice(task_id: StringName, amount: int = 1) -> void:
	var key: String = str(task_id)
	for day in Data.NOVICE_TASKS:
		for t in Data.NOVICE_TASKS[day].tasks:
			if str(t.id) == key:
				if not novice_progress.has(str(day)):
					novice_progress[str(day)] = {}
				novice_progress[str(day)][key] = int(novice_progress[str(day)].get(key, 0)) + amount
	Contract.novice_changed.emit(_current_novice_day(), novice_progress, novice_claimed)

## 当天任务是否全部达标
func _novice_day_done(day: int) -> bool:
	for t in Data.NOVICE_TASKS[day].tasks:
		var key: String = str(t.id)
		if int(novice_progress.get(str(day), {}).get(key, 0)) < int(t.target):
			return false
	return true

## 当前新手进度天（第一个未领的天；全部领完返回 8）
func _current_novice_day() -> int:
	for day in range(1, 8):
		if not novice_claimed.has(day):
			return day
	return 8

## 领取新手第 day 天奖励（契约 §3.6 入口，v0.16）
func claim_novice_reward(day: int) -> void:
	if not Data.NOVICE_TASKS.has(day) or novice_claimed.has(day):
		return
	if not _novice_day_done(day):
		return
	for reward in Data.NOVICE_TASKS[day].reward:
		_grant_task_reward(reward)
	novice_claimed.append(day)
	Contract.novice_changed.emit(_current_novice_day(), novice_progress, novice_claimed)
	Save.save_game()

## 只读：新手信息（契约 §3.6 入口，v0.16）
func get_novice_info() -> Dictionary:
	return { "day": _current_novice_day(), "progress": novice_progress, "claimed": novice_claimed }

## 战力达标类新手任务（power）：上阵战力 ≥ 目标即置 1；在战力相关动作/每帧检查
func _refresh_novice_power() -> void:
	var power: int = _team_power()
	var changed := false
	for day in Data.NOVICE_TASKS:
		for t in Data.NOVICE_TASKS[day].tasks:
			if str(t.id) == "power" and int(novice_progress.get(str(day), {}).get("power", 0)) < 1 and power >= int(t.target):
				if not novice_progress.has(str(day)):
					novice_progress[str(day)] = {}
				novice_progress[str(day)]["power"] = 1
				changed = true
	if changed:
		Contract.novice_changed.emit(_current_novice_day(), novice_progress, novice_claimed)
	# v0.17：战力变化 → 成就/称号自动检查
	_check_achievements()
	_check_titles()

## ================================================================
## v0.17：图鉴（契约 §3.14 / 设计文档 §10.4）
## ================================================================
## 已收集机娘数（owned 中 Data 存在数）
func _collection_count() -> int:
	return owned_mechs.size()

## 只读：图鉴信息（契约 §3.6 入口，v0.17）
func get_collection_info() -> Dictionary:
	return { "count": _collection_count(), "total": Data.MECH_GIRLS.size(), "claimed": collection_rewards_claimed }

## 领取图鉴档位奖励（契约 §3.6 入口，v0.17）：集齐 10/20/30 位
func claim_collection_reward(tier: int) -> void:
	if not Data.COLLECTION_REWARDS.has(tier) or collection_rewards_claimed.has(tier):
		return
	if _collection_count() < tier:
		return
	for reward in Data.COLLECTION_REWARDS[tier]:
		_grant_task_reward(reward)
	collection_rewards_claimed.append(tier)
	Contract.collection_changed.emit(_collection_count())
	Save.save_game()

## ================================================================
## v0.17：成就（契约 §3.14 / 设计文档 §10.13，12 个）
## ================================================================
## 成就/称号当前进度（type: story_cleared / summon_count / power / tower / collection / dungeon）
func _achievement_progress(type: String) -> int:
	match type:
		"story_cleared":
			return cleared_levels.size()
		"summon_count":
			return _total_summon_count
		"power":
			return _team_power()
		"tower":
			return tower_highest
		"collection":
			return _collection_count()
		"dungeon":
			# 已通关秘境档数（遍历各副本 kind 的已通关 tiers 计数；供"秘境达人"等条件判定）
			var total := 0
			for kind in dungeon_cleared:
				total += dungeon_cleared[kind].size()
			return total
	return 0

## 成就列表（含 progress / done / claimed，供 UI 与信号）
func _achievement_list() -> Array:
	var result: Array = []
	for aid in Data.ACHIEVEMENTS:
		var cfg: Dictionary = Data.ACHIEVEMENTS[aid]
		var progress: int = _achievement_progress(str(cfg.type))
		result.append({
			"id": aid,
			"name": str(cfg.name),
			"desc": str(cfg.desc),
			"progress": progress,
			"target": int(cfg.target),
			"done": progress >= int(cfg.target),
			"claimed": achievements_claimed.has(aid),
		})
	return result

## 成就自动检查（动作处调用；达成状态即时可算，此函数用于刷新 UI 状态）
func _check_achievements() -> void:
	Contract.achievement_changed.emit(_achievement_list())

## 只读：成就信息（契约 §3.6 入口，v0.17）
func get_achievement_info() -> Array:
	return _achievement_list()

## 领取成就奖励（契约 §3.6 入口，v0.17）：达成且未领
func claim_achievement(id: StringName) -> void:
	if not Data.ACHIEVEMENTS.has(id) or achievements_claimed.has(id):
		return
	var cfg: Dictionary = Data.ACHIEVEMENTS[id]
	if _achievement_progress(str(cfg.type)) < int(cfg.target):
		return
	for reward in cfg.rewards:
		_grant_task_reward(reward)
	achievements_claimed.append(id)
	Contract.achievement_changed.emit(_achievement_list())
	_gain_commander_exp(Data.COMMANDER_EXP_ACHIEVEMENT)  # v0.18：成就领奖给指挥官经验
	Save.save_game()

## ================================================================
## v0.17：称号（契约 §3.14 / 设计文档 §10.6 X4）
## ================================================================
## 称号解锁自动检查（动作处调用；新解锁发 title_changed）
func _check_titles() -> void:
	var changed := false
	for tid in Data.TITLES:
		var cond: Dictionary = Data.TITLES[tid].condition
		var progress: int = _achievement_progress(str(cond.type))
		if progress >= int(cond.target) and not titles_unlocked.has(tid):
			titles_unlocked.append(tid)
			changed = true
	if changed:
		Contract.title_changed.emit(titles_unlocked, title_equipped)

## 只读：称号信息（契约 §3.6 入口，v0.17）
func get_title_info() -> Dictionary:
	return { "unlocked": titles_unlocked, "equipped": title_equipped }

## 佩戴/卸下称号（契约 §3.6 入口，v0.17）：id 传空串卸下；解锁且未佩戴才可佩戴
func equip_title(id: StringName) -> void:
	if id != &"" and not titles_unlocked.has(id):
		return
	title_equipped = id
	Contract.title_changed.emit(titles_unlocked, title_equipped)
	# 称号属性变化：全队机娘属性变化通知
	for mech_id in _owned_mech_ids():
		_emit_mech_after_equip(mech_id)
	Save.save_game()

## 已佩戴称号的属性加成（本轮统一全队生效；scope 字段预留）
func _equipped_title_bonus() -> Dictionary:
	var total := { "atk_pct": 0.0, "hp_pct": 0.0, "def_pct": 0.0, "spd": 0.0 }
	if title_equipped == &"" or not Data.TITLES.has(title_equipped):
		return total
	var bonus: Dictionary = Data.TITLES[title_equipped].bonus
	var stat: String = str(bonus.stat)
	var value: float = float(bonus.value)
	if total.has(stat):
		total[stat] = value
	return total

## ================================================================
## v0.17：好感（契约 §3.14 / 设计文档 §10.6 X5）
## ================================================================
## 只读：好感信息（契约 §3.6 入口，v0.17）
func get_affinity_info() -> Dictionary:
	return { "affinity": affinity, "max": Data.AFFINITY_MAX }

## 送礼（契约 §3.6 入口，v0.17）：消耗金币 → 好感 +N（上限 100）
func give_gift(mech_id: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	if gold < Data.AFFINITY_GIFT_GOLD_COST:
		return
	var value: int = int(affinity.get(mech_id, 0))
	if value >= Data.AFFINITY_MAX:
		return
	gold -= Data.AFFINITY_GIFT_GOLD_COST
	value = mini(value + Data.AFFINITY_GIFT_VALUE, Data.AFFINITY_MAX)
	affinity[mech_id] = value
	Contract.gold_changed.emit(gold)
	Contract.affinity_changed.emit(mech_id, value)
	_emit_mech_after_equip(mech_id)
	Save.save_game()

## 出战胜利：上阵机娘好感 +1（各胜利结算处调用）
func _gain_battle_affinity() -> void:
	for mech_id in battle.mech_ids:
		var mid := StringName(mech_id)
		var value: int = int(affinity.get(mid, 0))
		if value >= Data.AFFINITY_MAX:
			continue
		value = mini(value + Data.AFFINITY_BATTLE_GAIN, Data.AFFINITY_MAX)
		affinity[mid] = value
		Contract.affinity_changed.emit(mid, value)

## 好感满级攻击加成（0~100 满级 +5%）
func _affinity_bonus_atk(mech_id: StringName) -> float:
	if int(affinity.get(mech_id, 0)) >= Data.AFFINITY_MAX:
		return Data.AFFINITY_MAX_BONUS_ATK
	return 0.0

## ================================================================
## v0.18：新手引导（契约 §3.15 / 设计文档 §10.11）
## ================================================================
## 推进引导（契约 §3.6 入口，v0.18）：step 0~6，6 = 完成
func guide_next() -> void:
	if guide_step >= Data.GUIDE_STEPS.size():
		return
	guide_step += 1
	Contract.guide_changed.emit(guide_step)
	Save.save_game()

## 跳过引导（契约 §3.6 入口，v0.18）：标记跳过并置为完成
func guide_skip() -> void:
	if guide_skipped:
		return
	guide_skipped = true
	guide_step = Data.GUIDE_STEPS.size()
	Contract.guide_changed.emit(guide_step)
	Save.save_game()

## 只读：引导信息（契约 §3.6 入口，v0.18）
func get_guide_info() -> Dictionary:
	return {
		"step": guide_step,
		"skipped": guide_skipped,
		"done": guide_step >= Data.GUIDE_STEPS.size(),
		"total": Data.GUIDE_STEPS.size(),
	}

## ================================================================
## v0.18：指挥官等级（契约 §3.15 / 设计文档 §4.7）
## ================================================================
## 指挥官经验获取（钩子：推关/任务领奖/成就领奖处调用）
## 经验满升级；每 5 级一次性 +10 召唤券（标记已发档位）
func _gain_commander_exp(amount: int) -> void:
	commander_exp += amount
	var leveled := false
	while commander_exp >= Data.COMMANDER_EXP_PER_LEVEL:
		commander_exp -= Data.COMMANDER_EXP_PER_LEVEL
		commander_level += 1
		leveled = true
	while commander_level >= commander_ten_rewarded + Data.COMMANDER_TEN_EVERY_LEVELS:
		commander_ten_rewarded += Data.COMMANDER_TEN_EVERY_LEVELS
		summon_ticket += Data.COMMANDER_TEN_TICKETS
	Contract.commander_changed.emit(commander_level, commander_exp)
	if leveled:
		Save.save_game()

## 只读：指挥官信息（契约 §3.6 入口，v0.18）
func get_commander_info() -> Dictionary:
	return {
		"level": commander_level,
		"exp": commander_exp,
		"exp_next": Data.COMMANDER_EXP_PER_LEVEL,
		"ten_rewarded": commander_ten_rewarded,
	}

## ================================================================
## v0.18：剧情回顾（契约 §3.15 / 设计文档 §10.9 X23）
## ================================================================
## 只读：第 1 章台词（Data + 首通解锁标记；图鉴内回看）
func get_story_lines() -> Dictionary:
	var result := {}
	for level in Data.STORY_LINES:
		var cfg: Dictionary = Data.STORY_LINES[level]
		result[level] = {
			"opening": str(cfg.opening),
			"clear": str(cfg.clear),
			"unlocked": cleared_levels.has(level),
		}
	return result

## ================================================================
## v0.18：活动（契约 §3.15 / 设计文档 §10.3）
## ================================================================
## 活动列表（含 done / claimed，供 UI 与信号）
func _activity_list() -> Array:
	var result: Array = []
	for aid in Data.ACTIVITIES:
		var cfg: Dictionary = Data.ACTIVITIES[aid]
		var cond: Dictionary = cfg.condition
		var progress: int = _achievement_progress(str(cond.type))
		result.append({
			"id": aid,
			"name": str(cfg.name),
			"desc": str(cfg.desc),
			"done": progress >= int(cond.target),
			"claimed": activity_claimed.has(aid),
		})
	return result

## 只读：活动信息（契约 §3.6 入口，v0.18）
func get_activity_info() -> Array:
	return _activity_list()

## 领取活动奖励（契约 §3.6 入口，v0.18）：达成且未领
func claim_activity(id: StringName) -> void:
	if not Data.ACTIVITIES.has(id) or activity_claimed.has(id):
		return
	var cfg: Dictionary = Data.ACTIVITIES[id]
	var cond: Dictionary = cfg.condition
	if _achievement_progress(str(cond.type)) < int(cond.target):
		return
	for reward in cfg.reward:
		_grant_task_reward(reward)
	activity_claimed.append(id)
	Contract.activity_changed.emit(_activity_list())
	Save.save_game()

## ================================================================
## v0.20：皮肤（契约 §3.16 X3 / 设计文档 §10.6 X3；纯外观无属性）
## ================================================================
## 只读：皮肤信息（契约 §3.6 入口，v0.20）
func get_skin_info() -> Dictionary:
	return { "unlocked": skins_unlocked, "equipped": skin_equipped }

## 穿戴/还原皮肤（契约 §3.6 入口，v0.20）：skin_id 传默认（&"default"）还原；
## 仅可穿该机娘已解锁皮肤
func equip_skin(mech_id: StringName, skin_id: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	if skin_id == Data.SKIN_DEFAULT_ID:
		skin_equipped.erase(mech_id)
	else:
		if not Data.SKINS.has(skin_id) or not skins_unlocked.has(skin_id):
			return
		if StringName(str(Data.SKINS[skin_id].mech_id)) != mech_id:
			return
		skin_equipped[mech_id] = skin_id
	Contract.skin_changed.emit(skins_unlocked, skin_equipped)
	Save.save_game()

## ================================================================
## v0.20：每日 BOSS（契约 §3.16 X7 / 设计文档 §10.7 X7；每日 1 次、伤害结算）
## ================================================================
## 进入每日 BOSS 战（契约 §3.6 入口，v0.20）：每日 1 次；battle.mode = "boss"
func start_daily_boss() -> void:
	var today: String = Time.get_date_string_from_system()
	if daily_boss["day"] == today:
		return  # 每日 1 次
	_start_boss_battle(today)

## 构建 BOSS 战（按星期几取当日 BOSS 配置；单波单 BOSS）
func _start_boss_battle(today: String) -> void:
	if formation.size() < 2:
		_ensure_default_formation()
	var weekday: int = int(Time.get_date_dict_from_system()["weekday"])
	var boss_cfg: Dictionary = Data.DAILY_BOSSES[weekday]
	battle = {
		"level": 0,
		"tick": 0,
		"active": true,
		"mode": &"boss",
		"dungeon_ctx": { "day": today },
		"wave": 1,
		"total_waves": 1,
		"mechs": [], "enemies": [], "pending_waves": [],
		"deaths": 0, "mech_ids": [], "accelerate": accelerate,
	}
	var used_ids := {}
	for slot in formation:
		var mech_id := StringName(str(slot.id))
		if not owned_mechs.has(mech_id) or used_ids.has(mech_id):
			continue
		used_ids[mech_id] = true
		battle.mechs.append(_build_mech_unit(mech_id, int(slot.row), int(slot.col)))
		battle.mech_ids.append(mech_id)
	# 敌方 = 当日 BOSS（单单位，血量高）
	battle.enemies = [{
		"side": &"enemy", "id": StringName("daily_boss"), "name": str(boss_cfg.name),
		"class": "tank", "tier": "boss",
		"row": 0, "col": 1,
		"hp": int(boss_cfg.hp), "max_hp": int(boss_cfg.hp), "atk": int(boss_cfg.atk), "def": int(boss_cfg.def), "spd": int(boss_cfg.spd),
		"energy": 0, "cd_1": 0, "cd_2": 0,
		"statuses": {}, "buffs": {}, "shield": 0, "taunt_turns": 0, "dodge_crit_ready": false,
		"alive": true, "dmg_dealt": 0, "heal_done": 0,
		"passive": { "effects": [] }, "skills": [Data.ENEMY_SKILLS[&"enemy_sweep"], Data.ENEMY_SKILLS[&"enemy_heavy"]], "ultimate": Data.ENEMY_SKILLS[&"enemy_boss_ult"],
	}]
	_apply_passive_battle_start()
	Contract.battle_tick.emit(0)
	for m in battle.mechs:
		Contract.mech_girl_updated.emit(m.id, int(m.hp), int(m.atk), int(m.level))
		Contract.energy_changed.emit(&"mech", m.id, int(m.energy))
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, int(e.hp))
		Contract.energy_changed.emit(&"enemy", e.id, int(e.energy))
	Contract.wave_changed.emit(1, 1)
	_apply_battle_timer_speed()
	battle_timer.start()

## BOSS 战结束（伤害结算）：按我方造成伤害合计记录当日最高伤害（v0.20）
func _resolve_boss_end() -> void:
	battle.active = false
	battle_timer.stop()
	var total_damage := 0
	for m in battle.mechs:
		total_damage += int(m.dmg_dealt)
	var day: String = str(battle.dungeon_ctx.get("day", ""))
	daily_boss["day"] = day
	daily_boss["damage"] = maxi(int(daily_boss["damage"]), total_damage)
	Contract.daily_boss_changed.emit(int(daily_boss["damage"]), day)
	Save.save_game()

## 只读：每日 BOSS 信息（契约 §3.6 入口，v0.20）
func get_daily_boss_info() -> Dictionary:
	var today: String = Time.get_date_string_from_system()
	return {
		"day": str(daily_boss["day"]),
		"damage": int(daily_boss["damage"]),
		"reward_claimed": int(daily_boss["reward_claimed"]),
		"today_done": str(daily_boss["day"]) == today,
	}

## 领取每日 BOSS 伤害档位奖励（契约 §3.6 入口，v0.20）：取最高可达且未领的档位
func claim_daily_boss_reward() -> void:
	var damage: int = int(daily_boss["damage"])
	var claimed: int = int(daily_boss["reward_claimed"])
	var best_tier: int = -1
	for i in Data.DAILY_BOSS_REWARD_TIERS.size():
		if damage >= int(Data.DAILY_BOSS_REWARD_TIERS[i].damage):
			best_tier = i
	if best_tier < 0 or best_tier <= claimed:
		return
	for reward in Data.DAILY_BOSS_REWARD_TIERS[best_tier].reward:
		_grant_task_reward(reward)
	daily_boss["reward_claimed"] = best_tier
	Contract.daily_boss_changed.emit(int(daily_boss["damage"]), str(daily_boss["day"]))
	Save.save_game()

## ================================================================
## v0.20：本地排行榜（契约 §3.16 X13 / 设计文档 §10.8 X13；只读计算，无存档）
## ================================================================
## 只读：四榜（战力/爬塔/每日BOSS 伤害/关卡进度）
func get_rank_info() -> Dictionary:
	return {
		"power": _team_power(),
		"tower": tower_highest,
		"boss_damage": int(daily_boss["damage"]),
		"story_progress": cleared_levels.size(),
	}

## ================================================================
## v0.21：远征/派遣（契约 §3.17 X6 / 设计文档 §10.7 X6；1~8 小时任务、离线计时）
## ================================================================
## 派遣机娘远征（契约 §3.6 入口，v0.21）：校验已拥有 + 闲置（未上阵且未派遣）+ 任务存在
## → 记录 end_time（now + hours×3600，离线照常）→ expedition_changed → 存档
func start_expedition(mech_id: StringName, task_id: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	if not Data.EXPEDITION_TASKS.has(task_id):
		return
	if expedition.has(mech_id):
		return  # 已派遣（未派遣校验）
	if _mech_in_formation(mech_id):
		return  # 已上阵（不闲置）
	var hours: int = int(Data.EXPEDITION_TASKS[task_id].hours)
	expedition[mech_id] = { "task_id": task_id, "end_time": int(Time.get_unix_time_from_system()) + hours * 3600 }
	Contract.expedition_changed.emit(expedition)
	Save.save_game()

## 领取远征奖励（契约 §3.6 入口，v0.21）：到期（now ≥ end_time，离线照常）→
## 金币入账 / 经验入全局池 / 材料入背包 → 移除该派遣 → expedition_changed → 存档
func collect_expedition(mech_id: StringName) -> void:
	if not expedition.has(mech_id):
		return
	var entry: Dictionary = expedition[mech_id]
	if int(Time.get_unix_time_from_system()) < int(entry.end_time):
		return  # 未到期
	var task_cfg: Dictionary = Data.EXPEDITION_TASKS[StringName(str(entry.task_id))]
	var gold_gain: int = int(task_cfg.get("gold", 0))
	var exp_gain: int = int(task_cfg.get("exp", 0))
	var mat_gain: int = int(task_cfg.get("material", 0))
	if gold_gain > 0:
		gold += gold_gain
		Contract.gold_changed.emit(gold)
	if exp_gain > 0:
		exp_balance += exp_gain
		Contract.exp_balance_updated.emit(exp_balance)
	if mat_gain > 0:
		bag["items"]["material_common"] = int(bag["items"].get("material_common", 0)) + mat_gain
		Contract.bag_updated.emit(bag["items"], int(bag["capacity"]))
	expedition.erase(mech_id)
	Contract.expedition_changed.emit(expedition)
	Save.save_game()

## 只读：远征信息（契约 §3.6 入口，v0.21）
## 返回：{expedition: {mech_id: {task_id, end_time, done}}, tasks: [...]}
func get_expedition_info() -> Dictionary:
	var now: int = int(Time.get_unix_time_from_system())
	var exp_map := {}
	for mech_id in expedition:
		var entry: Dictionary = expedition[mech_id]
		exp_map[mech_id] = {
			"task_id": StringName(str(entry.task_id)),
			"end_time": int(entry.end_time),
			"done": now >= int(entry.end_time),
		}
	var tasks: Array = []
	for task_id in Data.EXPEDITION_TASKS:
		var cfg: Dictionary = Data.EXPEDITION_TASKS[task_id]
		tasks.append({
			"id": task_id,
			"name": str(cfg.name),
			"hours": int(cfg.hours),
			"gold": int(cfg.get("gold", 0)),
			"exp": int(cfg.get("exp", 0)),
			"material": int(cfg.get("material", 0)),
		})
	return { "expedition": exp_map, "tasks": tasks }

## 闲置校验：该机娘是否在阵型中（远征派遣用）
func _mech_in_formation(mech_id: StringName) -> bool:
	for slot in formation:
		if StringName(str(slot.id)) == mech_id:
			return true
	return false

## ================================================================
## v0.21：生存模式（契约 §3.17 X8 / 设计文档 §10.7 X8；无限波次、每日 1 次、按波数奖励）
## ================================================================
## 进入生存模式（契约 §3.6 入口，v0.21）：每日 1 次免费（跨日重置）；battle.mode = "survival"
func start_survival() -> void:
	var today: String = Time.get_date_string_from_system()
	if str(survival.get("day", "")) == today:
		return  # 每日 1 次（结算时标记当日）
	_start_survival_battle()

## 构建生存模式战斗（我方按阵型；第 1 波敌人；无限波次由 _check_wave_clear 驱动）
func _start_survival_battle() -> void:
	if formation.size() < 2:
		_ensure_default_formation()
	battle = {
		"level": 0,
		"tick": 0,
		"active": true,
		"mode": &"survival",
		"dungeon_ctx": {},
		"wave": 1,
		"total_waves": Data.SURVIVAL_MAX_WAVES_SHOW,
		"mechs": [],
		"enemies": [],
		"pending_waves": [],
		"deaths": 0,
		"mech_ids": [],
		"accelerate": accelerate,
		"survival_wave": 1,
	}
	var used_ids := {}
	for slot in formation:
		var mech_id := StringName(str(slot.id))
		if not owned_mechs.has(mech_id) or used_ids.has(mech_id):
			continue
		used_ids[mech_id] = true
		battle.mechs.append(_build_mech_unit(mech_id, int(slot.row), int(slot.col)))
		battle.mech_ids.append(mech_id)
	_spawn_survival_wave(1)
	_apply_passive_battle_start()
	Contract.battle_tick.emit(0)
	for m in battle.mechs:
		Contract.mech_girl_updated.emit(m.id, int(m.hp), int(m.atk), int(m.level))
		Contract.energy_changed.emit(&"mech", m.id, int(m.energy))
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, int(e.hp))
		Contract.energy_changed.emit(&"enemy", e.id, int(e.energy))
	Contract.wave_changed.emit(battle.wave, battle.total_waves)
	_apply_battle_timer_speed()
	battle_timer.start()

## 生成生存模式第 wave 波敌人（强度随波数递增，敌人数 1~3 名递增；数值放 Data）
func _spawn_survival_wave(wave: int) -> void:
	var growth: float = pow(Data.SURVIVAL_ENEMY_GROWTH, float(wave - 1))
	var atk: int = roundi(float(Data.SURVIVAL_ENEMY_BASE_ATK) * growth)
	var hp: int = roundi(float(Data.SURVIVAL_ENEMY_BASE_HP) * growth)
	var def: int = Data.SURVIVAL_ENEMY_BASE_DEF + int(wave / 5)
	var spd: int = Data.SURVIVAL_ENEMY_BASE_SPD + int(wave / 10)
	var count: int = 1 + (wave - 1) % 3
	var wave_cfg: Array = []
	for i in count:
		wave_cfg.append({
			"id": StringName("sur_e" + str(wave) + "_" + str(i)),
			"name": "失控机械兵",
			"tier": "normal",
			"class": "fighter",
			"atk": atk, "hp": hp, "def": def, "spd": spd,
			"skills": [&"enemy_shot"],
		})
	_spawn_wave(wave_cfg)

## 生存模式清波：生成下一波（强度递增）而非胜利；重置节拍计数（60 轮上限按波计）
func _next_survival_wave() -> void:
	var wave: int = int(battle.get("survival_wave", 1)) + 1
	battle.survival_wave = wave
	battle.wave = wave
	battle.tick = 0
	_spawn_survival_wave(wave)
	Contract.wave_changed.emit(wave, int(battle.total_waves))
	Contract.battle_tick.emit(0)
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, int(e.hp))
		Contract.energy_changed.emit(&"enemy", e.id, 0)

## 生存模式结算（我方全灭 / 超时）：按已过波数更新最佳波数（标记当日）→ survival_changed → 存档
func _settle_survival_end() -> void:
	battle.active = false
	battle_timer.stop()
	var waves_cleared: int = maxi(int(battle.get("survival_wave", 1)) - 1, 0)
	var today: String = Time.get_date_string_from_system()
	survival["day"] = today
	survival["best_waves"] = maxi(int(survival.get("best_waves", 0)), waves_cleared)
	Contract.survival_changed.emit(today, int(survival["best_waves"]))
	Save.save_game()

## 只读：生存信息（契约 §3.6 入口，v0.21）
func get_survival_info() -> Dictionary:
	var today: String = Time.get_date_string_from_system()
	return {
		"day": str(survival.get("day", "")),
		"best_waves": int(survival.get("best_waves", 0)),
		"fought": str(survival.get("day", "")) == today,
		"reward_claimed": int(survival.get("reward_claimed", -1)),
	}

## 领取生存波数档位奖励（契约 §3.6 入口，v0.21）：取最高可达且未领的档位
func claim_survival_reward() -> void:
	var best_waves: int = int(survival.get("best_waves", 0))
	var claimed: int = int(survival.get("reward_claimed", -1))
	var best_tier: int = -1
	for i in Data.SURVIVAL_REWARD_TIERS.size():
		if best_waves >= int(Data.SURVIVAL_REWARD_TIERS[i].waves):
			best_tier = i
	if best_tier < 0 or best_tier <= claimed:
		return
	for reward in Data.SURVIVAL_REWARD_TIERS[best_tier].reward:
		_grant_task_reward(reward)
	survival["reward_claimed"] = best_tier
	Contract.survival_changed.emit(str(survival.get("day", "")), int(survival["best_waves"]))
	Save.save_game()

## ================================================================
## v0.21：家园互动（契约 §3.17 X10 / 设计文档 §10.7 X10；好感关联、每日次数限制）
## ================================================================
## 机娘互动（契约 §3.6 入口，v0.21）：已拥有 + 当日次数 < 上限 → count+1（好感 +1）→ home_changed → 存档
func interact_home(mech_id: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	_prune_home_interact()
	var today: String = Time.get_date_string_from_system()
	var entry: Dictionary = home_interact.get(mech_id, {})
	var count: int = 0
	if str(entry.get("day", "")) == today:
		count = int(entry.get("count", 0))
	if count >= Data.HOME_INTERACT_LIMIT:
		return  # 当日次数已满
	home_interact[mech_id] = { "day": today, "count": count + 1 }
	Contract.home_changed.emit(mech_id, count + 1)
	# 家园互动好感关联（每次互动好感 +1，上限 AFFINITY_MAX；属性变化随 mech_girl_updated）
	var value: int = int(affinity.get(mech_id, 0))
	if value < Data.AFFINITY_MAX:
		value = mini(value + Data.HOME_INTERACT_AFFINITY_GAIN, Data.AFFINITY_MAX)
		affinity[mech_id] = value
		Contract.affinity_changed.emit(mech_id, value)
		_emit_mech_after_equip(mech_id)
	Save.save_game()

## 只读：家园信息（契约 §3.6 入口，v0.21）
func get_home_info() -> Dictionary:
	_prune_home_interact()
	return { "home_interact": home_interact, "limit": Data.HOME_INTERACT_LIMIT }

## 清理过期互动记录（非当天的条目删除，保持 home_interact 只含当日数据）
func _prune_home_interact() -> void:
	var today: String = Time.get_date_string_from_system()
	for mech_id in home_interact.keys():
		if str(home_interact[mech_id].get("day", "")) != today:
			home_interact.erase(mech_id)

## ================================================================
## v0.22：日常转盘（契约 §3.18 X17 / 设计文档 §10.8 X17；每日 1 次免费、钻石续转、权重奖励）
## ================================================================
## 转盘（契约 §3.6 入口，v0.22）：每日 1 次免费（此后扣钻石）→ 按权重随机奖励
## → 发对应货币信号 + spin_changed → 存档
func spin_wheel() -> void:
	_spin_daily_reset()
	var today: String = Time.get_date_string_from_system()
	if not bool(spin.get("free_used", false)):
		spin["free_used"] = true
		spin["day"] = today
	else:
		if diamond < Data.SPIN_COST:
			return  # 钻石不足：失败不发信号
		diamond -= Data.SPIN_COST
		Contract.diamond_changed.emit(diamond)
	var reward := _roll_spin_reward()
	_grant_task_reward(reward)
	Contract.spin_changed.emit(reward)
	Save.save_game()

## 跨日重置转盘免费次数（day 变化 → free_used 归 false，沿用"每日重置"机制）
func _spin_daily_reset() -> void:
	var today: String = Time.get_date_string_from_system()
	if str(spin.get("day", "")) != today:
		spin["day"] = today
		spin["free_used"] = false

## 转盘权重随机（金币/钻石/宝石/召唤券；按 Data.SPIN_REWARDS 权重累计，返回 {type, amount, quality?}）
func _roll_spin_reward() -> Dictionary:
	var total := 0
	for entry in Data.SPIN_REWARDS:
		total += int(entry.get("weight", 1))
	if total <= 0:
		total = 1
	var roll: int = randi() % total
	var acc := 0
	for entry in Data.SPIN_REWARDS:
		acc += int(entry.get("weight", 1))
		if roll < acc:
			return { "type": str(entry.type), "amount": int(entry.amount), "quality": str(entry.get("quality", "")) }
	var first: Dictionary = Data.SPIN_REWARDS[0]
	return { "type": str(first.type), "amount": int(first.amount), "quality": str(first.get("quality", "")) }

## 只读：转盘信息（契约 §3.6 入口，v0.22；读时先做跨日重置，同 get_stamina 先例）
func get_spin_info() -> Dictionary:
	_spin_daily_reset()
	return {
		"day": str(spin.get("day", "")),
		"free_used": bool(spin.get("free_used", false)),
		"free_limit": Data.SPIN_FREE_DAILY,
		"cost": Data.SPIN_COST,
	}

## ================================================================
## v0.22：节日活动（契约 §3.18 X22 / 设计文档 §10.9 X22；日历触发节日任务 + 奖励）
## ================================================================
## 节日是否今日生效（month/day 匹配今天；month=0/day=0 = 常驻）
func _festival_active(festival_id: StringName) -> bool:
	var cfg: Dictionary = Data.FESTIVALS[festival_id]
	var month: int = int(cfg.get("month", 0))
	var day: int = int(cfg.get("day", 0))
	if month == 0 and day == 0:
		return true  # 常驻节日
	var now := Time.get_date_dict_from_system()
	return int(now["month"]) == month and int(now["day"]) == day

## 节日活动列表（含 active / done / claimed，供 UI 与信号；达成进度复用 _achievement_progress）
func _festival_list() -> Array:
	var result: Array = []
	for fid in Data.FESTIVALS:
		var cfg: Dictionary = Data.FESTIVALS[fid]
		var cond: Dictionary = cfg.condition
		var progress: int = _achievement_progress(str(cond.type))
		result.append({
			"id": fid,
			"name": str(cfg.name),
			"month": int(cfg.get("month", 0)),
			"day": int(cfg.get("day", 0)),
			"active": _festival_active(fid),
			"done": progress >= int(cond.target),
			"claimed": festival_claimed.has(fid),
		})
	return result

## 只读：节日活动信息（契约 §3.6 入口，v0.22）
func get_festival_info() -> Array:
	return _festival_list()

## 领取节日奖励（契约 §3.6 入口，v0.22）：当日生效（或常驻）+ 达成且未领 → 发奖 → festival_changed → 存档
func claim_festival_reward(festival_id: StringName) -> void:
	if not Data.FESTIVALS.has(festival_id) or festival_claimed.has(festival_id):
		return
	if not _festival_active(festival_id):
		return
	var cfg: Dictionary = Data.FESTIVALS[festival_id]
	var cond: Dictionary = cfg.condition
	if _achievement_progress(str(cond.type)) < int(cond.target):
		return
	for reward in cfg.reward:
		_grant_task_reward(reward)
	festival_claimed[festival_id] = true
	Contract.festival_changed.emit(_festival_list())
	Save.save_game()

## ---------------------------------------------------------------
## 只读快照（供 Save.save_game 写档；只读不改任何数值）
## 签名：get_save_snapshot() -> Dictionary
## 返回：{ gold, exp_balance, mechs{level, exp}, unlocked_level, first_cleared,
##         idle_pending, idle_pending_exp, idle_last_time, diamond, summon_ticket,
##         fragments, owned_mechs, pity, novice_free_pull, novice_pool_left,
##         novice_first_ten_done, formation, formation_presets, level_stars,
##         cleared_boss, chapter_chest_claimed }（契约 §3.2，v0.8 存档形状）
## ---------------------------------------------------------------
func get_save_snapshot() -> Dictionary:
	var mechs := {}
	for mech_id in _owned_mech_ids():
		mechs[mech_id] = {
			"level": int(mech_levels.get(mech_id, 1)),
			"star": int(mech_stars.get(mech_id, 1)),
		}
	var first_cleared: Array = []
	for l in cleared_levels:
		first_cleared.append(int(l))
	first_cleared.sort()
	return {
		"gold": gold,
		"exp_balance": exp_balance,
		"mechs": mechs,
		"unlocked_level": unlocked_level,
		"first_cleared": first_cleared,
		"idle_pending": roundi(idle_pending),
		"idle_pending_exp": roundi(idle_pending_exp),
		"idle_last_time": int(idle_last_time),
		"diamond": diamond,
		"summon_ticket": summon_ticket,
		"fragments": fragments,
		"owned_mechs": owned_mechs,
		"pity": pity,
		"novice_free_pull": novice_free_pull,
		"novice_pool_left": novice_pool_left,
		"novice_first_ten_done": novice_first_ten_done,
		"formation": formation,
		"formation_presets": formation_presets,
		"level_stars": level_stars,
		"cleared_boss": cleared_boss,
		"chapter_chest_claimed": chapter_chest_claimed,
		# v0.13：体力 / 秘境 / 背包 / 开箱
		"stamina": stamina,
		"stamina_last_time": stamina_last_time,
		"stamina_buy_count": stamina_buy_count,
		"last_reset_day": last_reset_day,
		"dungeon_cleared": dungeon_cleared,
		"bag": bag,
		"boxes": boxes,
		# v0.14：装备 / 宝石
		"equip_inventory": equip_inventory,
		"equipped": equipped,
		"gem_stock": gem_stock,
		# v0.15：设置 / 商城
		"settings": settings,
		"shop_day": shop_day,
		"shop_bought": shop_bought,
		# v0.16：爬塔 / 签到 / 任务 / 新手
		"tower_highest": tower_highest,
		"tower_daily_count": tower_daily_count,
		"sign_days": sign_days,
		"sign_last_day": sign_last_day,
		"task_daily": task_daily,
		"task_weekly": task_weekly,
		"novice_progress": novice_progress,
		"novice_claimed": novice_claimed,
		# v0.17：图鉴 / 成就 / 称号 / 好感
		"collection_rewards_claimed": collection_rewards_claimed,
		"achievements_claimed": achievements_claimed,
		"titles_unlocked": titles_unlocked,
		"title_equipped": title_equipped,
		"affinity": affinity,
		"total_summon_count": _total_summon_count,
		# v0.18：指挥官 / 引导 / 活动
		"commander_exp": commander_exp,
		"commander_level": commander_level,
		"commander_ten_rewarded": commander_ten_rewarded,
		"guide_step": guide_step,
		"guide_skipped": guide_skipped,
		"activity_claimed": activity_claimed,
		# v0.20：限定池 / 皮肤 / 每日 BOSS
		"limited_pity": limited_pity,
		"skins_unlocked": skins_unlocked,
		"skin_equipped": skin_equipped,
		"daily_boss": daily_boss,
		# v0.21：远征 / 生存 / 家园
		"expedition": expedition,
		"survival": survival,
		"home_interact": home_interact,
		# v0.22：转盘 / 节日活动
		"spin": spin,
		"festival_claimed": festival_claimed,
	}
