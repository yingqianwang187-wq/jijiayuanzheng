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
var mech_exp: Dictionary = {}                   # { StringName id: int exp } 机娘经验（胜利获得，升级消耗）
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

## 当前战斗状态（非战斗时 active = false）
var battle: Dictionary = {
	"level": 1,
	"tick": 0,
	"active": false,
	"wave": 1,
	"total_waves": 1,
	"mechs": [],        # 我方单位 [{ side, id, name, class, row, col, hp, max_hp, atk, def, spd, energy, cd_1, cd_2, statuses, buffs, shield, taunt_turns, dodge_crit_ready, alive, dmg_dealt, heal_done, level, cfg }]
	"enemies": [],      # 当前波敌方单位（结构同上 + tier/ultimate）
	"pending_waves": [],# 未出场的敌方波配置（LEVELS[level].waves 的副本，已出场波移除）
	"deaths": 0,        # 我方阵亡数（星级评价用）
	"mech_ids": [],     # 我方上阵机娘 id（经验发放用）
	"accelerate": false,
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
	# 成长状态只建"已拥有"机娘（未拥有无等级/经验/星级；抽到新机娘时再初始化）
	mech_levels.clear()
	mech_exp.clear()
	mech_stars.clear()
	for mech_id in _owned_mech_ids():
		mech_levels[mech_id] = 1
		mech_exp[mech_id] = 0
		mech_stars[mech_id] = 1
	var mechs: Dictionary = data.get("mechs", {})
	for key in mechs:
		var mech_id := StringName(str(key))
		if Data.MECH_GIRLS.has(mech_id) and owned_mechs.has(mech_id):
			var entry: Dictionary = mechs[key]
			mech_levels[mech_id] = maxi(int(entry.get("level", 1)), 1)
			mech_exp[mech_id] = maxi(int(entry.get("exp", 0)), 0)
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

## 发初始状态信号（gold_changed / diamond_changed / mech_girl_updated / mech_exp_updated /
## exp_balance_updated / level_progress_changed / idle_rewards_updated / owned_mechs_updated）
func _emit_initial_state() -> void:
	Contract.gold_changed.emit(gold)
	Contract.diamond_changed.emit(diamond)
	for mech_id in _owned_mech_ids():
		var s := _mech_stats(mech_id)
		Contract.mech_girl_updated.emit(mech_id, s.hp, s.atk, s.level)
		Contract.mech_exp_updated.emit(mech_id, int(mech_exp.get(mech_id, 0)), _upgrade_exp_cost(mech_id, int(mech_levels.get(mech_id, 1))))
		Contract.mech_star_updated.emit(mech_id, int(mech_stars.get(mech_id, 1)), get_level_cap(mech_id))
	Contract.exp_balance_updated.emit(exp_balance)
	Contract.level_progress_changed.emit(unlocked_level)
	Contract.idle_rewards_updated.emit(roundi(idle_pending), roundi(idle_pending_exp))
	Contract.owned_mechs_updated.emit(_owned_mech_ids())
	Contract.formation_changed.emit(formation)

## 由 Data 基础值 + 当前等级 + 星级计算机娘完整属性（hp 为满血）
## 星级加成（v0.10）：每星基础属性 ×(1 + STAR_STAT_GAIN)^(star-1)
func _mech_stats(mech_id: StringName) -> Dictionary:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var level: int = int(mech_levels.get(mech_id, 1))
	var star: int = int(mech_stars.get(mech_id, 1))
	var g: Dictionary = cfg.growth
	var spd_gain: int = floori(float(level - 1) / float(g.spd_every)) * int(g.spd_amount)
	var star_mult: float = pow(1.0 + Data.STAR_STAT_GAIN, float(star - 1))
	return {
		"level": level,
		"star": star,
		"hp": int(round(float(int(cfg.base_hp) + (level - 1) * int(g.hp)) * star_mult)),
		"atk": int(round(float(int(cfg.base_atk) + (level - 1) * int(g.atk)) * star_mult)),
		"def": int(round(float(int(cfg.base_def) + (level - 1) * int(g.def)) * star_mult)),
		"spd": int(round(float(int(cfg.base_spd) + spd_gain) * star_mult)),
	}

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
## 规则（v0.6 双路经验）：经验先扣个人经验条（mech_exp[id]），不足部分自动从
## 全局经验余额（exp_balance）补；两者合计都不足则失败（不扣金币、不发任何信号）。
## 金币不足同样失败。
## ---------------------------------------------------------------
func upgrade(mech_id: StringName) -> void:
	if not Data.MECH_GIRLS.has(mech_id) or not owned_mechs.has(mech_id):
		return
	var current_level: int = int(mech_levels.get(mech_id, 1))
	# 等级上限（v0.10）：满级不可再升
	if current_level >= get_level_cap(mech_id):
		return
	var current_exp: int = int(mech_exp.get(mech_id, 0))
	var gold_cost: int = _upgrade_cost(mech_id, current_level)
	var exp_cost: int = _upgrade_exp_cost(mech_id, current_level)
	# 经验判定：个人条 + 余额合计是否够
	var total_exp: int = current_exp + exp_balance
	if gold < gold_cost or total_exp < exp_cost:
		return
	# 扣经验：先个人条，不足从余额补
	var exp_from_personal: int = mini(current_exp, exp_cost)
	var exp_from_balance: int = exp_cost - exp_from_personal
	mech_exp[mech_id] = current_exp - exp_from_personal
	if exp_from_balance > 0:
		exp_balance -= exp_from_balance
	# 扣金币
	gold -= gold_cost
	mech_levels[mech_id] = current_level + 1
	Contract.gold_changed.emit(gold)
	var s := _mech_stats(mech_id)
	Contract.mech_girl_updated.emit(mech_id, s.hp, s.atk, s.level)
	Contract.mech_exp_updated.emit(mech_id, int(mech_exp[mech_id]), _upgrade_exp_cost(mech_id, current_level + 1))
	# 若动用了余额，通知余额变化（契约 §3.5 v0.6）
	if exp_from_balance > 0:
		Contract.exp_balance_updated.emit(exp_balance)
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

## 阵型为空时自动生成：拥有的前 ≤5 位排 3-2 布局（前排 3 格 + 中排 2 格）
func _ensure_default_formation() -> void:
	var ids := _owned_mech_ids()
	formation = []
	var layout := [ [0, 0], [0, 1], [0, 2], [1, 0], [1, 1] ]
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
		"passive": cfg.passive, "skills": cfg.skills, "ultimate": cfg.ultimate,
	}

## 生成一波敌方单位（AI 排阵：tank 前排 row0，其余 row1/row2，同排 col 依次分配）
func _spawn_wave(wave_cfg: Array) -> void:
	battle.enemies = []
	var row0_col := 0
	var row1_col := 0
	var row2_col := 0
	for cfg in wave_cfg:
		var row: int = 0
		var col: int = row0_col
		if str(cfg.class) == "tank":
			row = 0
			col = row0_col
			row0_col += 1
		elif row1_col < 3:
			row = 1
			col = row1_col
			row1_col += 1
		else:
			row = 2
			col = row2_col
			row2_col += 1
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
		var crit_mult: float = Data.CRIT_DAMAGE_MULT
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

## 暴击判定（基础 10% + 被动 + 闪避联动必暴击）
func _roll_crit(attacker) -> bool:
	if bool(attacker.dodge_crit_ready):
		attacker.dodge_crit_ready = false
		return true
	var rate: float = Data.CRIT_RATE_BASE
	for eff in attacker.passive.effects:
		if str(eff.kind) == "crit_rate":
			rate += float(eff.value)
	return randf() < rate

## 闪避判定（基础 5% + 增益/被动）
func _roll_dodge(target) -> bool:
	var rate: float = Data.DODGE_RATE_BASE + _total_buff(target, "dodge")
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
						var next_target := _next_target_same_row(attacker, target)
						if not next_target.is_empty():
							var cdmg: int = _deal_damage(attacker, next_target, float(b.rate), skill, true, false, true)
							if cdmg > 0:
								_gain_energy(attacker, Data.ENERGY_GAIN_HIT)
				"heal_self_on_kill":
					if str(b.get("resource", "hp")) == "energy":
						_gain_energy(attacker, int(round(float(b.value) * 100.0)))

## 同排下一个存活目标（追击用）
func _next_target_same_row(attacker, target) -> Dictionary:
	var enemies: Array = battle.enemies if attacker.side == &"mech" else battle.mechs
	for e in enemies:
		if bool(e.alive) and int(e.row) == int(target.row) and StringName(str(e.id)) != StringName(str(target.id)):
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
			return _row_targets(enemies, 0)
		"back":
			var max_row := _max_row(enemies)
			return _row_targets(enemies, max_row)
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

## 默认攻击目标：嘲讽优先 → 同列最近 → 前排（row 小）
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
		var score: int = same_col * 1000 + int(e.row) * 10 + col_diff
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

## 某排全部存活目标
func _row_targets(enemies: Array, row: int) -> Array:
	var result: Array = []
	for e in enemies:
		if bool(e.alive) and int(e.row) == row:
			result.append(e)
	return result

func _max_row(enemies: Array) -> int:
	var m: int = 0
	for e in enemies:
		if bool(e.alive):
			m = maxi(m, int(e.row))
	return m

func _any_alive(units: Array) -> bool:
	for u in units:
		if bool(u.alive):
			return true
	return false

## 波次推进：当前波清空 → 下一波或胜利
func _check_wave_clear() -> void:
	if _any_alive(battle.enemies):
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

## 60 轮超时：按双方剩余血量百分比判定（我方高则胜，否则败）
func _check_timeout() -> void:
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

## 胜利：星级 → 首通奖励 → 星奖/章节宝箱 → 全体上阵机娘得经验 → 解锁下一关 →
## 记录 last_clear → 发 battle_star + level_cleared → 自动存档
func _resolve_victory() -> void:
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
	# 胜利经验：全体上阵机娘（含本局阵亡者）进个人条；满级经验不累计（v0.10）
	var exp_gain: int = int(Data.LEVELS[level].victory_reward_exp)
	for mech_id in battle.mech_ids:
		var mid := StringName(mech_id)
		if int(mech_levels.get(mid, 1)) >= get_level_cap(mid):
			continue
		var new_exp: int = int(mech_exp.get(mid, 0)) + exp_gain
		mech_exp[mid] = new_exp
		Contract.mech_exp_updated.emit(mid, new_exp, _upgrade_exp_cost(mid, int(mech_levels.get(mid, 1))))
	# 记录本局通关信息（内存态，不入档）
	last_clear = { "level": level, "first_clear": first_clear, "reward": reward }
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

## 失败：发 battle_failed → 停止战斗，可重试
func _resolve_defeat() -> void:
	battle.active = false
	battle_timer.stop()
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
	# 新手池首十连保底：本次十连第 10 张必出保底位（星澜）
	var first_ten_pity: bool = (pool == &"novice" and times == 10 and not novice_first_ten_done)
	if first_ten_pity:
		novice_first_ten_done = true
	# 1. 生成原始结果 id 列表（含 SSR 80 保底 / 首十连保底）
	var raw_ids: Array = []
	for i in times:
		raw_ids.append(_roll_with_pity(pool_cfg, first_ten_pity and i == times - 1))
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
	Save.save_game()

## 单抽内部：SSR 80 保底累计 + 按概率抽一个机娘（契约 §3.8）
func _roll_with_pity(pool_cfg: Dictionary, force_first_ten: bool) -> StringName:
	if force_first_ten:
		# 首十连保底位必出（保底位为 SSR，出 SSR 重置保底计数）
		pity = 0
		return StringName(pool_cfg.first_ten_pity)
	pity += 1
	var mech_id: StringName = _roll_summon(pool_cfg)
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	if int(cfg.rarity) == Data.Rarity.SSR:
		pity = 0
	elif pity >= Data.SUMMON_PITY_SSR_LIMIT:
		# 每 80 抽必出 ≥1 SSR：强制补一张 SSR 并重置
		mech_id = _random_member_of_rarity(pool_cfg, Data.Rarity.SSR)
		pity = 0
	return mech_id

## 按稀有度占比（SSR 3% / SR 17% / R 80%）随机抽一个池内成员
func _roll_summon(pool_cfg: Dictionary) -> StringName:
	var roll: float = randf()
	if roll < Data.SUMMON_RATE_SSR:
		return _random_member_of_rarity(pool_cfg, Data.Rarity.SSR)
	elif roll < Data.SUMMON_RATE_SSR + Data.SUMMON_RATE_SR:
		return _random_member_of_rarity(pool_cfg, Data.Rarity.SR)
	return _random_member_of_rarity(pool_cfg, Data.Rarity.R)

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
		mech_exp[mech_id] = 0
		mech_stars[mech_id] = 1
		entry["is_new"] = true
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
## 说明：SSR 保底计数为全局（跨池累计，出 SSR 重置），pool 参数暂不影响结果
## ---------------------------------------------------------------
func summon_pity_info(pool: StringName) -> Dictionary:
	var remain: int = maxi(Data.SUMMON_PITY_SSR_LIMIT - pity, 0)
	return { "progress": pity, "remain": remain }

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
	# 扫荡给"上阵机娘"（当前阵型；空则拥有前 5）经验
	var sweep_ids: Array = []
	for slot in formation:
		if not sweep_ids.has(StringName(str(slot.id))):
			sweep_ids.append(StringName(str(slot.id)))
	if sweep_ids.is_empty():
		sweep_ids = _owned_mech_ids()
	for mech_id in sweep_ids:
		var mid := StringName(mech_id)
		if int(mech_levels.get(mid, 1)) >= get_level_cap(mid):
			continue
		var new_exp: int = int(mech_exp.get(mid, 0)) + exp_gain
		mech_exp[mid] = new_exp
		Contract.mech_exp_updated.emit(mid, new_exp, _upgrade_exp_cost(mid, int(mech_levels.get(mid, 1))))
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
			"exp": int(mech_exp.get(mech_id, 0)),
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
	}
