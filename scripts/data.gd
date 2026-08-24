# ==================================================================
# scripts/data.gd —— 机娘 / 敌人 / 关卡数值表（Data）
# 作者   ：B（数值 + 玩法 + 存档）
# 依据   ：docs/设计文档.md §8（数值唯一来源）、docs/契约.md §3.3 / §1.3
#          scripts/contract.gd（只读）
# 职责   ：只放"数据"，不放"逻辑"。
#          铁律：无函数实现、无信号 emit、无运行时代码（纯常量 / 字典表）。
#          所有数值的唯一存放处；Game 从这里读数值并实现规则，绝不硬编码。
# 自动加载：本文件注册为名为 Data 的 autoload（注册顺序 Contract → Data → Save → Game，
#          见契约 §2.1）。
# 变更规则：改本文件数值前，先对照 docs/设计文档.md §8；设计文档是数值的唯一来源。
# ==================================================================
extends Node

# ------------------------------------------------------------------
# 关卡规模（设计文档 §8.1：MVP 第 1 章 5 关）
# ------------------------------------------------------------------
const MAX_LEVEL := 5

# ------------------------------------------------------------------
# 节拍间隔（设计文档 §8.3 + 契约 §3.4：战斗每秒 1 轮；契约 §3.3：节拍间隔属 Data）
# ------------------------------------------------------------------
const BATTLE_TICK_INTERVAL := 1.0   # 战斗节拍：每秒 1 轮
const IDLE_TICK_INTERVAL := 1.0     # 挂机节拍：在线每秒累计一次

# ------------------------------------------------------------------
# 稀有度 —— 与 Contract.Rarity 一一对应（R / SR / SSR，设计文档 §2.1）
# （Data 自包含定义，避免 const 表达式依赖 autoload 引起的编译期问题）
# ------------------------------------------------------------------
enum Rarity { R = 0, SR = 1, SSR = 2 }

# ------------------------------------------------------------------
# 机娘升级消耗（设计文档 §8.4，v0.2 双消耗）
#   金币部分：第 N 级升 N+1 级费用 = 20 × 1.18^(N-1)，四舍五入
#   经验部分：第 N 级升 N+1 级所需经验 = 15 × 1.25^(N-1)，四舍五入
#   示例核对：1→2 级需 20 金币 + 15 经验；2→3 级 24 金币 + 19 经验；
#             3→4 级 28 金币 + 23 经验；10→11 级约 89 金币 + 112 经验
# ------------------------------------------------------------------
const UPGRADE_COST_BASE := 20
const UPGRADE_COST_GROWTH := 1.18
const UPGRADE_EXP_BASE := 15
const UPGRADE_EXP_GROWTH := 1.25

# ------------------------------------------------------------------
# 机娘升级属性成长（设计文档 §8.4：每升 1 级 攻+2 / 血+15 / 防+1，速度每 5 级 +1）
# ------------------------------------------------------------------
const UPGRADE_GROWTH_ATK := 2
const UPGRADE_GROWTH_HP := 15
const UPGRADE_GROWTH_DEF := 1
const UPGRADE_GROWTH_SPD_EVERY := 5
const UPGRADE_GROWTH_SPD_AMOUNT := 1

# ------------------------------------------------------------------
# 挂机金币与经验（设计文档 §8.4，v0.2 改"点一下收获"、v0.3 同产经验）
#   基础每秒 +0.5 金币；随通关进度每过 1 关 ×1.25
#   挂机经验 = 待收获金币 × IDLE_EXP_RATIO（1 金币 = 0.5 经验，基础 0.25 经验/秒，
#   随关卡同步 ×1.25）；随"点一下收获"一起入账（金币入账、经验入全局经验余额）
#   金币/经验按"距上次收获/上次打开的实际经过时长 × 每秒产出"累计成待收获，
#   点击一次性领取；离线（关游戏）期间同样计入
# ------------------------------------------------------------------
const IDLE_GOLD_BASE := 0.5
const IDLE_GOLD_GROWTH := 1.25
const IDLE_EXP_RATIO := 0.5

# ------------------------------------------------------------------
# 挂机金币自动存档节流间隔（秒）—— 契约 §3.2：节流间隔属数值，由 B 放入 Data
# ------------------------------------------------------------------
const SAVE_THROTTLE_INTERVAL := 5.0

# ------------------------------------------------------------------
# 伤害公式参数（契约 §1.3：伤害公式等具体数值属 Data）
#   公式：伤害 = max(攻击方 atk - 防御方 def, DAMAGE_MIN)
# ------------------------------------------------------------------
const DAMAGE_MIN := 1

# ------------------------------------------------------------------
# 机娘数值表（设计文档 §8.4 基础属性 Lv1）
#   字段：name 名 / rarity 稀有度 / role 定位 / base_atk 攻击 / base_hp 血量 /
#         base_def 防御 / base_spd 速度 / upgrade_cost 升级费用曲线 / growth 升级成长
#   id 用 StringName（与契约信号参数类型一致）
# ------------------------------------------------------------------
const MECH_GIRLS := {
	&"xiao_yu": {
		"name": "小钰",
		"rarity": Rarity.R,
		"role": "近战",
		"base_atk": 12,
		"base_hp": 120,
		"base_def": 8,
		"base_spd": 10,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": {
			"atk": UPGRADE_GROWTH_ATK,
			"hp": UPGRADE_GROWTH_HP,
			"def": UPGRADE_GROWTH_DEF,
			"spd_every": UPGRADE_GROWTH_SPD_EVERY,
			"spd_amount": UPGRADE_GROWTH_SPD_AMOUNT,
		},
	},
	&"a_lan": {
		"name": "阿岚",
		"rarity": Rarity.R,
		"role": "远程",
		"base_atk": 15,
		"base_hp": 90,
		"base_def": 5,
		"base_spd": 8,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": {
			"atk": UPGRADE_GROWTH_ATK,
			"hp": UPGRADE_GROWTH_HP,
			"def": UPGRADE_GROWTH_DEF,
			"spd_every": UPGRADE_GROWTH_SPD_EVERY,
			"spd_amount": UPGRADE_GROWTH_SPD_AMOUNT,
		},
	},
	&"qianxia": {
		"name": "千夏",
		"rarity": Rarity.SR,
		"role": "辅助·护盾",
		"base_atk": 10,
		"base_hp": 130,
		"base_def": 12,
		"base_spd": 7,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": {
			"atk": UPGRADE_GROWTH_ATK,
			"hp": UPGRADE_GROWTH_HP,
			"def": UPGRADE_GROWTH_DEF,
			"spd_every": UPGRADE_GROWTH_SPD_EVERY,
			"spd_amount": UPGRADE_GROWTH_SPD_AMOUNT,
		},
	},
	&"lian": {
		"name": "莲",
		"rarity": Rarity.SR,
		"role": "近战·坦克",
		"base_atk": 14,
		"base_hp": 190,
		"base_def": 15,
		"base_spd": 6,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": {
			"atk": UPGRADE_GROWTH_ATK,
			"hp": UPGRADE_GROWTH_HP,
			"def": UPGRADE_GROWTH_DEF,
			"spd_every": UPGRADE_GROWTH_SPD_EVERY,
			"spd_amount": UPGRADE_GROWTH_SPD_AMOUNT,
		},
	},
	&"yuejian": {
		"name": "月见",
		"rarity": Rarity.SR,
		"role": "远程·狙击",
		"base_atk": 20,
		"base_hp": 100,
		"base_def": 6,
		"base_spd": 12,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": {
			"atk": UPGRADE_GROWTH_ATK,
			"hp": UPGRADE_GROWTH_HP,
			"def": UPGRADE_GROWTH_DEF,
			"spd_every": UPGRADE_GROWTH_SPD_EVERY,
			"spd_amount": UPGRADE_GROWTH_SPD_AMOUNT,
		},
	},
	&"fei": {
		"name": "绯",
		"rarity": Rarity.SSR,
		"role": "近战·爆发",
		"base_atk": 26,
		"base_hp": 160,
		"base_def": 10,
		"base_spd": 13,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": {
			"atk": UPGRADE_GROWTH_ATK,
			"hp": UPGRADE_GROWTH_HP,
			"def": UPGRADE_GROWTH_DEF,
			"spd_every": UPGRADE_GROWTH_SPD_EVERY,
			"spd_amount": UPGRADE_GROWTH_SPD_AMOUNT,
		},
	},
	&"xinglan": {
		"name": "星澜",
		"rarity": Rarity.SSR,
		"role": "远程·炮击",
		"base_atk": 30,
		"base_hp": 130,
		"base_def": 8,
		"base_spd": 11,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": {
			"atk": UPGRADE_GROWTH_ATK,
			"hp": UPGRADE_GROWTH_HP,
			"def": UPGRADE_GROWTH_DEF,
			"spd_every": UPGRADE_GROWTH_SPD_EVERY,
			"spd_amount": UPGRADE_GROWTH_SPD_AMOUNT,
		},
	},
}

## 开局已拥有的机娘（设计文档 §9 阶段 0：2 位；契约 §3.8 v0.7：上阵 = 拥有的机娘）
const START_MECHS := [&"xiao_yu", &"a_lan"]

# ------------------------------------------------------------------
# 抽卡 / 召唤系统（契约 §3.8、设计文档 §4，阶段 1；数值全部放 Data）
# ------------------------------------------------------------------

## 抽卡价格（设计文档 §4.3）：单抽 / 十连；新手池半价（共 5 次，见 SUMMON_NOVICE_POOL_LEFT）
const SUMMON_COST_SINGLE := 300
const SUMMON_COST_TEN := 2800
const SUMMON_NOVICE_DISCOUNT := 0.5        # 新手池半价系数

## 出货概率（设计文档 §4.4）：SSR 3% / SR 17% / R 80%
const SUMMON_RATE_SSR := 0.03
const SUMMON_RATE_SR := 0.17
const SUMMON_RATE_R := 0.80

## 保底（设计文档 §4.5）：每 80 抽内必出 ≥1 个 SSR（跨十连累计，出 SSR 后重置）；
## 十连必出 ≥1 个 SR（无则补一张 SR）；新手池首十连保底出星澜（见 SUMMON_POOLS）
const SUMMON_PITY_SSR_LIMIT := 80

## 新手福利（设计文档 §4.7）：开局免费十连 ×1；新手池半价共 5 次
const SUMMON_NOVICE_FREE_TEN := 1          # 免费十连次数（MVP 仅 1 次）
const SUMMON_NOVICE_POOL_LEFT := 5         # 新手池半价剩余次数（初始）

## 重复机娘 → 碎片换算（设计文档 §4.6 / §8.4：R=10 / SR=20 / SSR=50）
const FRAGMENT_CONVERT := { Rarity.R: 10, Rarity.SR: 20, Rarity.SSR: 50 }

## 卡池表（设计文档 §4.2，v0.4 定稿）
##   standard 常驻池 = 全部 7 位（2R + 3SR + 2SSR）
##   novice   新手池 = 星澜(SSR 首十连保底位) + 千夏/莲(SR) + 小钰/阿岚(R)；半价 ×5
##   first_ten_pity：新手池首次十连保底必出的机娘 id（首十连保底位，保底位除外按稀有度占比）
const SUMMON_POOLS := {
	&"standard": {
		"name": "常驻池",
		"members": [&"xiao_yu", &"a_lan", &"qianxia", &"lian", &"yuejian", &"fei", &"xinglan"],
	},
	&"novice": {
		"name": "新手池",
		"members": [&"xinglan", &"qianxia", &"lian", &"xiao_yu", &"a_lan"],
		"first_ten_pity": &"xinglan",
	},
}

# ------------------------------------------------------------------
# 关卡数值表（设计文档 §8.4）
#   字段：enemies 敌人列表（MVP 每关 1 波 = 1 个敌人，用数组以便后续扩展多敌，
#         v0.2 起数据结构按"敌方每波最多 5 名"预留）/
#         first_clear_reward 首通奖励金币（§8.4 首通奖励表"金币"列）/
#         first_clear_reward_diamond 首通奖励钻石（§8.4 首通奖励表"钻石"列；阶段 1 起发放）/
#         victory_reward_exp 战斗胜利经验 = 10 + 关卡 × 3（§8.4 v0.2；
#         非首通重复胜利也给经验，失败无经验）
#   说明：
#     - 非首通通关无金币/钻石奖励（设计文档 §3.2：金币来源 = 挂机收获 + 关卡首通）。
#     - 敌人 def / spd：设计文档 §8.4 敌人表只给出攻击 / 血量，故防御取 0（无减伤）、
#       速度取 0（敌方后手，契合契约 §1.3"我方全体攻击一次 → 敌方全体攻击一次"的出手顺序）。
#     - 敌人 name 为 B 补充的占位名（非数值），C 可用图形/头像替代显示。
#     - 敌人攻/血按 v0.2 §8.4 表（第 1 关 14/120，每关约 +22%）。
# ------------------------------------------------------------------
const LEVELS := {
	1: {
		"enemies": [
			{ "id": &"enemy_1", "name": "暴走机械兵", "atk": 14, "hp": 120, "def": 0, "spd": 0 },
		],
		"first_clear_reward": 100,
		"first_clear_reward_diamond": 30,
		"victory_reward_exp": 13,
	},
	2: {
		"enemies": [
			{ "id": &"enemy_2", "name": "暴走机械兵", "atk": 17, "hp": 146, "def": 0, "spd": 0 },
		],
		"first_clear_reward": 150,
		"first_clear_reward_diamond": 40,
		"victory_reward_exp": 16,
	},
	3: {
		"enemies": [
			{ "id": &"enemy_3", "name": "暴走机械兵", "atk": 21, "hp": 179, "def": 0, "spd": 0 },
		],
		"first_clear_reward": 220,
		"first_clear_reward_diamond": 50,
		"victory_reward_exp": 19,
	},
	4: {
		"enemies": [
			{ "id": &"enemy_4", "name": "暴走机械兵", "atk": 25, "hp": 218, "def": 0, "spd": 0 },
		],
		"first_clear_reward": 320,
		"first_clear_reward_diamond": 60,
		"victory_reward_exp": 22,
	},
	5: {
		"enemies": [
			{ "id": &"enemy_5", "name": "暴走机械兵", "atk": 31, "hp": 266, "def": 0, "spd": 0 },
		],
		"first_clear_reward": 480,
		"first_clear_reward_diamond": 80,
		"victory_reward_exp": 25,
	},
}
