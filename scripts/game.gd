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

## 当前战斗状态（非战斗时 active = false）
var battle: Dictionary = {
	"level": 1,
	"tick": 0,
	"active": false,
	"mechs": [],    # [{ id, hp, atk, def, spd, level }]
	"enemies": [],  # [{ id, hp, atk, def, spd }]
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
	# 成长状态只建"已拥有"机娘（未拥有无等级/经验；抽到新机娘时再初始化）
	mech_levels.clear()
	mech_exp.clear()
	for mech_id in _owned_mech_ids():
		mech_levels[mech_id] = 1
		mech_exp[mech_id] = 0
	var mechs: Dictionary = data.get("mechs", {})
	for key in mechs:
		var mech_id := StringName(str(key))
		if Data.MECH_GIRLS.has(mech_id) and owned_mechs.has(mech_id):
			var entry: Dictionary = mechs[key]
			mech_levels[mech_id] = maxi(int(entry.get("level", 1)), 1)
			mech_exp[mech_id] = maxi(int(entry.get("exp", 0)), 0)
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
	if elapsed > 0.0:
		idle_pending += elapsed * _idle_gold_rate()
		idle_pending_exp += elapsed * _idle_gold_rate() * Data.IDLE_EXP_RATIO
		idle_last_time = now

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
	Contract.exp_balance_updated.emit(exp_balance)
	Contract.level_progress_changed.emit(unlocked_level)
	Contract.idle_rewards_updated.emit(roundi(idle_pending), roundi(idle_pending_exp))
	Contract.owned_mechs_updated.emit(_owned_mech_ids())

## 由 Data 基础值 + 当前等级计算机娘完整属性（hp 为满血）
func _mech_stats(mech_id: StringName) -> Dictionary:
	var cfg: Dictionary = Data.MECH_GIRLS[mech_id]
	var level: int = int(mech_levels.get(mech_id, 1))
	var g: Dictionary = cfg.growth
	var spd_gain: int = floori(float(level - 1) / float(g.spd_every)) * int(g.spd_amount)
	return {
		"level": level,
		"hp": int(cfg.base_hp) + (level - 1) * int(g.hp),
		"atk": int(cfg.base_atk) + (level - 1) * int(g.atk),
		"def": int(cfg.base_def) + (level - 1) * int(g.def),
		"spd": int(cfg.base_spd) + spd_gain,
	}

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
## 进入关卡，开始自动节拍战斗（契约 §3.6 入口）
## 签名：start_battle(level: int)
## 校验：仅接受已解锁的合法关卡（1..MAX_LEVEL 且 <= unlocked_level）
## ---------------------------------------------------------------
func start_battle(level: int) -> void:
	if not (level is int):
		return
	if level < 1 or level > Data.MAX_LEVEL or level > unlocked_level:
		return
	battle = {
		"level": level,
		"tick": 0,
		"active": true,
		"mechs": [],
		"enemies": [],
	}
	# 上阵 = 已拥有机娘的前 ≤5 位（按 Data.MECH_GIRLS 声明顺序；契约 §1.2 / §3.8 v0.7）
	for mech_id in Data.MECH_GIRLS:
		if not owned_mechs.has(mech_id):
			continue
		if battle.mechs.size() >= 5:
			break
		var s := _mech_stats(mech_id)
		battle.mechs.append({ "id": mech_id, "hp": s.hp, "atk": s.atk, "def": s.def, "spd": s.spd, "level": s.level })
	for e in Data.LEVELS[level].enemies:
		battle.enemies.append({ "id": e.id, "hp": e.hp, "atk": e.atk, "def": e.def, "spd": e.spd })
	# 立即发初始战斗状态（节拍 0 / 我方满血 / 敌方满血），供 battle_view 首次显示
	Contract.battle_tick.emit(0)
	for m in battle.mechs:
		Contract.mech_girl_updated.emit(m.id, m.hp, m.atk, m.level)
	for e in battle.enemies:
		Contract.enemy_updated.emit(e.id, e.hp)
	battle_timer.start()

## 战斗节拍：每秒 1 轮（契约 §1.3 / §3.4）
func _on_battle_tick() -> void:
	if not battle.active:
		return
	battle.tick += 1
	Contract.battle_tick.emit(battle.tick)
	_resolve_round()
	_check_battle_end()

## 一轮结算：全体存活单位按速度降序出手（契约 §3.4"按速度排序先后出手"；
## 敌方速度 = 0，自然落在我方之后，契合契约 §1.3"我方全体攻击一次 → 敌方全体攻击一次"）
func _resolve_round() -> void:
	var order: Array = []
	for m in battle.mechs:
		if int(m.hp) > 0:
			order.append({ "side": &"mech", "unit": m })
	for e in battle.enemies:
		if int(e.hp) > 0:
			order.append({ "side": &"enemy", "unit": e })
	order.sort_custom(func(a, b): return int(a.unit.spd) > int(b.unit.spd))
	for entry in order:
		var attacker: Dictionary = entry.unit
		if int(attacker.hp) <= 0:
			continue
		var target := _first_alive_target(entry.side)
		if target.is_empty():
			break
		# 伤害公式（Data.DAMAGE_MIN，契约 §1.3）：伤害 = max(atk - def, DAMAGE_MIN)
		var dmg: int = maxi(int(attacker.atk) - int(target.def), Data.DAMAGE_MIN)
		target.hp = int(target.hp) - dmg
		# 血量变化必须立即发信号（契约 §3.5）
		if entry.side == &"mech":
			Contract.enemy_updated.emit(StringName(target.id), int(target.hp))
		else:
			# 敌方出手 → 我方被攻击：血条刷新用 target（我方机娘）的参数
			Contract.mech_girl_updated.emit(StringName(target.id), int(target.hp), int(target.atk), int(target.level))

## 返回对方阵营第一个存活单位（MVP：集火对方列表首位）；无存活目标返回空字典
func _first_alive_target(attacker_side: StringName) -> Dictionary:
	if attacker_side == &"mech":
		for e in battle.enemies:
			if int(e.hp) > 0:
				return e
	else:
		for m in battle.mechs:
			if int(m.hp) > 0:
				return m
	return {}

## 胜负判定：敌人全灭 = 胜利（若与我方同归于尽，MVP 判玩家胜）；我方全灭 = 失败可重试
func _check_battle_end() -> void:
	var enemy_alive := false
	for e in battle.enemies:
		if int(e.hp) > 0:
			enemy_alive = true
			break
	if not enemy_alive:
		_resolve_victory()
		return
	var mech_alive := false
	for m in battle.mechs:
		if int(m.hp) > 0:
			mech_alive = true
			break
	if not mech_alive:
		_resolve_defeat()

## 胜利：首通判定与奖励 → 全体上阵机娘得经验（含本局阵亡者）→ 解锁下一关 →
## 记录 last_clear → 发 level_cleared → 自动存档
func _resolve_victory() -> void:
	battle.active = false
	battle_timer.stop()
	var level: int = int(battle.level)
	var first_clear: bool = not cleared_levels.has(level)
	var reward: int = 0
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
		var next_level: int = level + 1
		if next_level <= Data.MAX_LEVEL and next_level > unlocked_level:
			unlocked_level = next_level
			Contract.level_progress_changed.emit(unlocked_level)
	# 胜利经验：遍历本局出战名单 battle.mechs（含本局阵亡者，契约 §1.3 v0.5：
	# 所有出战机娘都得经验；非首通重复胜利也给经验用于练级；失败无经验）
	var exp_gain: int = int(Data.LEVELS[level].victory_reward_exp)
	for m in battle.mechs:
		var mech_id := StringName(m.id)
		var new_exp: int = int(mech_exp.get(mech_id, 0)) + exp_gain
		mech_exp[mech_id] = new_exp
		Contract.mech_exp_updated.emit(mech_id, new_exp, _upgrade_exp_cost(mech_id, int(mech_levels.get(mech_id, 1))))
	# 记录本局通关信息（内存态，不入档）
	last_clear = { "level": level, "first_clear": first_clear, "reward": reward }
	# level_cleared 最后发，确保 UI 收到时金币 / 关卡进度 / 经验 / last_clear 已更新
	Contract.level_cleared.emit(level, first_clear)
	Save.save_game()

## 失败：发 battle_failed（契约 §3.5 v0.2，battle_view connect 显示失败/重试）
## → 停止战斗，可重试（再次 start_battle 即可）。
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
	if cost > 0 and diamond < cost:
		return  # 钻石不足：失败不发信号
	# 计费状态消耗：免费十连优先（不耗新手池半价次数），否则新手池半价扣次数
	if times == 10 and novice_free_pull:
		novice_free_pull = false
	elif pool == &"novice" and novice_pool_left > 0:
		novice_pool_left -= 1
	if cost > 0:
		diamond -= cost
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
## 只读快照（供 Save.save_game 写档；只读不改任何数值）
## 签名：get_save_snapshot() -> Dictionary
## 返回：{ gold, exp_balance, mechs{level, exp}, unlocked_level, first_cleared,
##         idle_pending, idle_pending_exp, idle_last_time, diamond, summon_ticket,
##         fragments, owned_mechs, pity, novice_free_pull, novice_pool_left,
##         novice_first_ten_done }（契约 §3.2，v0.7 存档形状）
## ---------------------------------------------------------------
func get_save_snapshot() -> Dictionary:
	var mechs := {}
	for mech_id in _owned_mech_ids():
		mechs[mech_id] = {
			"level": int(mech_levels.get(mech_id, 1)),
			"exp": int(mech_exp.get(mech_id, 0)),
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
	}
