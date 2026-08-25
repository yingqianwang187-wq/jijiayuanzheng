# ==================================================================
# scripts/data.gd —— 机娘 / 敌人 / 关卡数值表 + 卡池配置 + 战斗常量（Data）
# 作者   ：B（数值 + 玩法 + 存档）
# 依据   ：docs/设计文档.md（v0.14，数值唯一来源）、docs/契约.md §3.3 / §3.8 / §3.9、
#          scripts/contract.gd（只读）
# 职责   ：只放"数据"，不放"逻辑"。
#          铁律：无函数实现、无信号 emit、无运行时代码（纯常量 / 字典表）。
#          所有数值的唯一存放处；Game 从这里读数值并实现规则，绝不硬编码。
# 自动加载：本文件注册为名为 Data 的 autoload（注册顺序 Contract → Data → Save → Game）。
# 变更规则：改本文件数值前，先对照 docs/设计文档.md；设计文档是数值的唯一来源。
# ==================================================================
extends Node

# ------------------------------------------------------------------
# 关卡规模与章节结构（设计文档 §1.3 / §8.1，v0.14）
#   第 1 章维持 5 关（第 5 关 = 章节 BOSS 关）；第 2 章起每章 10 关（v0.14，阶段 4+ 扩展）
# ------------------------------------------------------------------
const MAX_LEVEL := 5
const CHAPTERS := {
	1: { "name": "第 1 章", "levels": 5, "boss_level": 5 },
}

# ------------------------------------------------------------------
# 节拍间隔（设计文档 §8.3：每秒 1 轮；契约 §3.3：节拍间隔属 Data）
# ------------------------------------------------------------------
const BATTLE_TICK_INTERVAL := 1.0   # 战斗节拍：每秒 1 轮（2x 加速时减半）
const IDLE_TICK_INTERVAL := 1.0     # 挂机节拍：在线每秒累计一次

# ------------------------------------------------------------------
# 稀有度 —— 与 Contract.Rarity 一一对应（R / SR / SSR）
# ------------------------------------------------------------------
enum Rarity { R = 0, SR = 1, SSR = 2 }

# ------------------------------------------------------------------
# 机娘升级消耗（设计文档 §8.4 / 附录 B）
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
# 挂机金币与经验（设计文档 §8.4 / 附录 B）
# ------------------------------------------------------------------
const IDLE_GOLD_BASE := 0.5
const IDLE_GOLD_GROWTH := 1.25
const IDLE_EXP_RATIO := 0.5
const IDLE_OFFLINE_CAP_HOURS := 12.0        # 离线收益上限（v0.14：12 小时）

# ------------------------------------------------------------------
# 挂机自动存档节流间隔（秒）—— 契约 §3.2
# ------------------------------------------------------------------
const SAVE_THROTTLE_INTERVAL := 5.0

# ------------------------------------------------------------------
# 战斗 2.0 核心数值（设计文档 §8.3 / 附录 B，v0.8 战斗 2.0）
# ------------------------------------------------------------------
const CRIT_RATE_BASE := 0.10                 # 基础暴击率 10%
const CRIT_DAMAGE_MULT := 1.50               # 暴击伤害 150%
const DODGE_RATE_BASE := 0.05                # 基础闪避率 5%（闪避则该次伤害 0）
const ENERGY_GAIN_HIT := 10                  # 普攻命中 +10 能量
const ENERGY_GAIN_HIT_TAKEN := 10            # 受击 +10 能量
const ENERGY_MAX := 100                      # 能量 100 满格自动放大招（放完清零）
const DAMAGE_FLOOR_RATIO := 0.30             # 减伤下限：最终伤害 ≥ 原始伤害 × 30%
const DAMAGE_MIN := 1                        # 最低保底伤害
const BATTLE_MAX_ROUNDS := 60                # 每场最多 60 轮，超时按剩余血量百分比判
const COUNTER_MULT := 1.20                   # 职业克制（克制方伤害 +20%）
const COUNTER_PENALTY := 0.90                # 被克制方伤害 -10%

## 职业克制环（设计文档 §8.3：坦克→刺客→射手→法师→战士→坦克，辅助中立）
const CLASS_COUNTER := {
	&"tank": &"assassin",
	&"assassin": &"archer",
	&"archer": &"mage",
	&"mage": &"fighter",
	&"fighter": &"tank",
}

## 战力公式权重（设计文档 §10.1 / 附录 B：战力 = 攻×4 + 血×1 + 防×6 + 速×5）
const POWER_ATK_W := 4
const POWER_HP_W := 1
const POWER_DEF_W := 6
const POWER_SPD_W := 5

## 状态持续轮数（设计文档 §8.3：默认 3 轮、同效果不叠加只刷新时长）
const STATUS_DURATION_DEFAULT := 3

## 星级规则（设计文档 §8.3：无人阵亡=3星、阵亡1~2人=2星、惨胜=1星）
const STAR_3_MAX_DEATHS := 0
const STAR_2_MAX_DEATHS := 2

## 星奖（设计文档 §1.3：单关星级奖励，达到即领一次；推荐值可调）
const STAR_REWARD_GOLD := 100                # 1 星：金币
const STAR_REWARD_DIAMOND := 30              # 2 星：钻石
const STAR_REWARD_TICKET := 1                # 3 星：召唤券

## 章节星数宝箱（设计文档 §1.3：全章集满 90% 星数可领；MVP 阶段 2 无宝石/装备，给钻石+金币）
const CHAPTER_CHEST_STAR_RATIO := 0.9
const CHAPTER_CHEST_DIAMOND := 100
const CHAPTER_CHEST_GOLD := 500

## 首通掉落小钰碎片（设计文档 §1.3 / 附录 B，v0.15：普通关 1 片、章节 BOSS 关 3 片，一次性）
const XIAOYU_FRAGMENT_FIRST_CLEAR := 1
const XIAOYU_FRAGMENT_BOSS := 3

# ------------------------------------------------------------------
# 抽卡 / 召唤系统（设计文档 §4 / 附录 B，阶段 1）
# ------------------------------------------------------------------
const SUMMON_COST_SINGLE := 300
const SUMMON_COST_TEN := 2800
const SUMMON_NOVICE_DISCOUNT := 0.5
const SUMMON_RATE_SSR := 0.03
const SUMMON_RATE_SR := 0.17
const SUMMON_RATE_R := 0.80
const SUMMON_PITY_SSR_LIMIT := 80
const SUMMON_NOVICE_FREE_TEN := 1
const SUMMON_NOVICE_POOL_LEFT := 5
const FRAGMENT_CONVERT := { Rarity.R: 10, Rarity.SR: 20, Rarity.SSR: 50 }

## 卡池表（设计文档 §4.2，v0.12 扩充 30 位）
const SUMMON_POOLS := {
	&"standard": {
		"name": "常驻池",
		"members": [
			&"xiao_yu", &"a_lan", &"tong", &"ling", &"ying", &"ling2", &"ya", &"you",
			&"qianxia", &"lian", &"yuejian", &"pan", &"li", &"lin", &"yuan", &"xi",
			&"sun", &"shuang", &"li2", &"tang",
			&"fei", &"xinglan", &"yue", &"jin", &"ming", &"ya2", &"cang", &"xuan", &"mu", &"luo",
		],
	},
	&"novice": {
		"name": "新手池",
		"members": [&"xinglan", &"qianxia", &"lian", &"xiao_yu", &"a_lan"],
		"first_ten_pity": &"xinglan",
	},
}

## 开局已拥有的机娘（设计文档 §9 阶段 0；契约 §3.8）
const START_MECHS := [&"xiao_yu", &"a_lan"]

# ------------------------------------------------------------------
# 机娘数值表（设计文档 §8.4 基础属性 Lv1 + §2.4/§2.4.1 30 位）
#   字段：name / rarity / class（6 职业）/ role / base_* 四维 /
#         upgrade_cost / growth / passive（被动 effects）/ skills（2 小技）/
#         ultimate（大招）
#   技能效果格式（Game 解析）：
#     effect: "damage"|"heal"|"shield"|"buff"|"debuff"|"stun"|"burn"|"poison"|"freeze"|"taunt"|"cleanse"
#     target: "single"(自动同列最近/前排) | "lowest_hp" | "front" | "back" | "all" | "all_ally" | "self" | "lowest_hp_ally"
#     rate: 伤害/治疗（按 atk%）或护盾（按 max_hp%）倍率；hits 段数；chance 概率；duration 轮数
#     bonus 数组：{kind: "chase"|"combo"|"burn"|"stun"|"freeze"|"poison"|"armor_break"|"execute"|"crit_bonus"|"ignore_def"|"buff"|"debuff"|"heal_self_on_kill", ...}
#   被动 kind：kill_heal/crit_rate/shield_start/counter/armor_break_on_hit/enrage/dodge/dodge_crit/
#              damage_reduce/atk_high_hp/atk_up/combo_chance/energy_on_hit/heal_per_round/
#              energy_on_hit_taken/ambush/stun_chance/reflect/execute_bonus/atk_aura/ignore_def
# ------------------------------------------------------------------
const MECH_GIRLS := {
	# ================= R 级 8 位 =================
	&"xiao_yu": {
		"name": "小钰", "rarity": Rarity.R, "class": "fighter", "role": "近战",
		"base_atk": 12, "base_hp": 120, "base_def": 8, "base_spd": 10,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"xyu_p", "name": "愈战愈勇", "effects": [ { "kind": "kill_heal", "value": 0.10 } ] },
		"skills": [
			{ "id": &"xyu_s1", "name": "热能横扫", "cd": 3, "effect": "damage", "target": "single", "rate": 1.80 },
			{ "id": &"xyu_s2", "name": "冲锋", "cd": 5, "effect": "damage", "target": "front", "rate": 1.30 },
		],
		"ultimate": { "id": &"xyu_u", "name": "绯红烈焰斩", "effect": "damage", "target": "single", "rate": 4.00, "bonus": [ { "kind": "chase", "rate": 1.50 } ] },
	},
	&"a_lan": {
		"name": "阿岚", "rarity": Rarity.R, "class": "archer", "role": "远程",
		"base_atk": 15, "base_hp": 90, "base_def": 5, "base_spd": 8,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"alan_p", "name": "狙击瞄准", "effects": [ { "kind": "crit_rate", "value": 0.15 } ] },
		"skills": [
			{ "id": &"alan_s1", "name": "点射", "cd": 3, "effect": "damage", "target": "lowest_hp", "rate": 2.00 },
			{ "id": &"alan_s2", "name": "火力压制", "cd": 4, "effect": "damage", "target": "back", "rate": 1.20, "bonus": [ { "kind": "debuff", "stat": "atk", "value": 0.20, "duration": 3 } ] },
		],
		"ultimate": { "id": &"alan_u", "name": "磁轨贯射", "effect": "damage", "target": "single", "rate": 4.50, "bonus": [ { "kind": "crit_bonus", "value": 0.50 } ] },
	},
	&"tong": {
		"name": "桐", "rarity": Rarity.R, "class": "tank", "role": "坦克",
		"base_atk": 10, "base_hp": 150, "base_def": 12, "base_spd": 6,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"tong_p", "name": "铁壁", "effects": [ { "kind": "damage_reduce", "value": 0.05 } ] },
		"skills": [
			{ "id": &"tong_s1", "name": "盾墙", "cd": 3, "effect": "shield", "target": "self", "rate": 0.20 },
			{ "id": &"tong_s2", "name": "重锤", "cd": 4, "effect": "damage", "target": "single", "rate": 1.50, "bonus": [ { "kind": "stun", "chance": 1.0, "duration": 1 } ] },
		],
		"ultimate": { "id": &"tong_u", "name": "不动盾", "effect": "shield", "target": "self", "rate": 0.40, "bonus": [ { "kind": "taunt", "duration": 1 } ] },
	},
	&"ling": {
		"name": "铃", "rarity": Rarity.R, "class": "fighter", "role": "战士",
		"base_atk": 13, "base_hp": 110, "base_def": 7, "base_spd": 9,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"ling_p", "name": "战意", "effects": [ { "kind": "atk_high_hp", "value": 0.10 } ] },
		"skills": [
			{ "id": &"ling_s1", "name": "横斩", "cd": 3, "effect": "damage", "target": "front", "rate": 1.20 },
			{ "id": &"ling_s2", "name": "突进", "cd": 4, "effect": "damage", "target": "single", "rate": 1.80 },
		],
		"ultimate": { "id": &"ling_u", "name": "旋风斩", "effect": "damage", "target": "front", "rate": 1.50, "hits": 2 },
	},
	&"ying": {
		"name": "影", "rarity": Rarity.R, "class": "assassin", "role": "刺客",
		"base_atk": 14, "base_hp": 85, "base_def": 4, "base_spd": 12,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"ying_p", "name": "疾影", "effects": [ { "kind": "atk_up", "value": 0.10 } ] },
		"skills": [
			{ "id": &"ying_s1", "name": "割喉", "cd": 3, "effect": "damage", "target": "lowest_hp", "rate": 2.00 },
			{ "id": &"ying_s2", "name": "潜行", "cd": 5, "effect": "buff", "target": "self", "stat": "dodge", "value": 0.30, "duration": 1 },
		],
		"ultimate": { "id": &"ying_u", "name": "影杀", "effect": "damage", "target": "single", "rate": 3.50, "bonus": [ { "kind": "chase", "rate": 1.00 } ] },
	},
	&"ling2": {
		"name": "翎", "rarity": Rarity.R, "class": "archer", "role": "射手",
		"base_atk": 15, "base_hp": 80, "base_def": 4, "base_spd": 10,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"ling2_p", "name": "连射", "effects": [ { "kind": "combo_chance", "chance": 0.10, "rate": 0.50 } ] },
		"skills": [
			{ "id": &"ling2_s1", "name": "速射", "cd": 3, "effect": "damage", "target": "single", "rate": 1.50, "bonus": [ { "kind": "combo", "rate": 0.80 } ] },
			{ "id": &"ling2_s2", "name": "瞄准", "cd": 4, "effect": "damage", "target": "single", "rate": 2.20 },
		],
		"ultimate": { "id": &"ling2_u", "name": "贯穿箭", "effect": "damage", "target": "single", "rate": 4.00, "bonus": [ { "kind": "ignore_def", "value": 0.20 } ] },
	},
	&"ya": {
		"name": "芽", "rarity": Rarity.R, "class": "mage", "role": "法师",
		"base_atk": 14, "base_hp": 75, "base_def": 3, "base_spd": 8,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"ya_p", "name": "能量涌动", "effects": [ { "kind": "energy_on_hit", "value": 5 } ] },
		"skills": [
			{ "id": &"ya_s1", "name": "能量弹", "cd": 3, "effect": "damage", "target": "single", "rate": 1.80 },
			{ "id": &"ya_s2", "name": "扩散", "cd": 4, "effect": "damage", "target": "all", "rate": 0.80 },
		],
		"ultimate": { "id": &"ya_u", "name": "能量风暴", "effect": "damage", "target": "all", "rate": 1.50, "bonus": [ { "kind": "debuff", "stat": "spd", "value": 0.20, "duration": 2 } ] },
	},
	&"you": {
		"name": "柚", "rarity": Rarity.R, "class": "support", "role": "辅助",
		"base_atk": 8, "base_hp": 100, "base_def": 8, "base_spd": 8,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"you_p", "name": "治愈", "effects": [ { "kind": "heal_per_round", "value": 0.01 } ] },
		"skills": [
			{ "id": &"you_s1", "name": "小治疗", "cd": 3, "effect": "heal", "target": "lowest_hp_ally", "rate": 0.20 },
			{ "id": &"you_s2", "name": "激励", "cd": 5, "effect": "buff", "target": "all_ally", "stat": "atk", "value": 0.15, "duration": 2 },
		],
		"ultimate": { "id": &"you_u", "name": "生命之光", "effect": "heal", "target": "all_ally", "rate": 0.30, "bonus": [ { "kind": "cleanse" } ] },
	},
	# ================= SR 级 12 位 =================
	&"qianxia": {
		"name": "千夏", "rarity": Rarity.SR, "class": "support", "role": "辅助·护盾",
		"base_atk": 10, "base_hp": 130, "base_def": 12, "base_spd": 7,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"qianxia_p", "name": "守护之心", "effects": [ { "kind": "shield_start", "value": 0.15 } ] },
		"skills": [
			{ "id": &"qianxia_s1", "name": "护盾发生器", "cd": 3, "effect": "shield", "target": "lowest_hp_ally", "rate": 0.25, "duration": 3 },
			{ "id": &"qianxia_s2", "name": "后勤补给", "cd": 5, "effect": "heal", "target": "all_ally", "rate": 0.15, "bonus": [ { "kind": "cleanse" } ] },
		],
		"ultimate": { "id": &"qianxia_u", "name": "绝对防御", "effect": "shield", "target": "all_ally", "rate": 0.40, "bonus": [ { "kind": "buff", "stat": "damage_reduce", "value": 0.20, "duration": 2 } ] },
	},
	&"lian": {
		"name": "莲", "rarity": Rarity.SR, "class": "tank", "role": "近战·坦克",
		"base_atk": 14, "base_hp": 190, "base_def": 15, "base_spd": 6,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"lian_p", "name": "钢铁壁垒", "effects": [ { "kind": "counter", "chance": 0.20, "rate": 0.80 } ] },
		"skills": [
			{ "id": &"lian_s1", "name": "嘲讽", "cd": 4, "effect": "taunt", "target": "self", "duration": 2 },
			{ "id": &"lian_s2", "name": "盾击", "cd": 3, "effect": "damage", "target": "single", "rate": 1.50, "bonus": [ { "kind": "stun", "chance": 1.0, "duration": 1 } ] },
		],
		"ultimate": { "id": &"lian_u", "name": "不动如山", "effect": "shield", "target": "self", "rate": 0.50, "bonus": [ { "kind": "buff", "stat": "damage_reduce", "value": 0.30, "duration": 2 } ] },
	},
	&"yuejian": {
		"name": "月见", "rarity": Rarity.SR, "class": "archer", "role": "远程·狙击",
		"base_atk": 20, "base_hp": 100, "base_def": 6, "base_spd": 12,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"yuejian_p", "name": "弱点洞察", "effects": [ { "kind": "armor_break_on_hit", "chance": 0.30, "value": 0.30, "duration": 3 } ] },
		"skills": [
			{ "id": &"yuejian_s1", "name": "致命一枪", "cd": 4, "effect": "damage", "target": "single", "rate": 2.50, "bonus": [ { "kind": "execute", "threshold": 0.50 } ] },
			{ "id": &"yuejian_s2", "name": "速射", "cd": 3, "effect": "damage", "target": "single", "rate": 1.30, "bonus": [ { "kind": "combo", "rate": 1.00 } ] },
		],
		"ultimate": { "id": &"yuejian_u", "name": "一枪穿云", "effect": "damage", "target": "single", "rate": 5.00 },
	},
	&"pan": {
		"name": "磐", "rarity": Rarity.SR, "class": "tank", "role": "坦克",
		"base_atk": 9, "base_hp": 210, "base_def": 16, "base_spd": 5,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"pan_p", "name": "坚守", "effects": [ { "kind": "energy_on_hit_taken", "value": 1 } ] },
		"skills": [
			{ "id": &"pan_s1", "name": "守护", "cd": 3, "effect": "shield", "target": "lowest_hp_ally", "rate": 0.30 },
			{ "id": &"pan_s2", "name": "震荡", "cd": 4, "effect": "damage", "target": "front", "rate": 1.20, "bonus": [ { "kind": "debuff", "stat": "spd", "value": 0.20, "duration": 2 } ] },
		],
		"ultimate": { "id": &"pan_u", "name": "磐石领域", "effect": "shield", "target": "all_ally", "rate": 0.25, "bonus": [ { "kind": "buff", "stat": "damage_reduce", "value": 0.10, "duration": 2 } ] },
	},
	&"li": {
		"name": "砺", "rarity": Rarity.SR, "class": "tank", "role": "坦克",
		"base_atk": 11, "base_hp": 200, "base_def": 15, "base_spd": 5,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"li_p", "name": "磨损", "effects": [ { "kind": "counter", "chance": 0.20, "rate": 0.60, "armor_break": true } ] },
		"skills": [
			{ "id": &"li_s1", "name": "挑衅", "cd": 4, "effect": "taunt", "target": "self", "duration": 1 },
			{ "id": &"li_s2", "name": "劈砍", "cd": 3, "effect": "damage", "target": "single", "rate": 1.60 },
		],
		"ultimate": { "id": &"li_u", "name": "百炼", "effect": "shield", "target": "self", "rate": 0.45, "bonus": [ { "kind": "buff", "stat": "counter_rate", "value": 0.20, "duration": 2 } ] },
	},
	&"lin": {
		"name": "凛", "rarity": Rarity.SR, "class": "fighter", "role": "战士",
		"base_atk": 17, "base_hp": 130, "base_def": 9, "base_spd": 10,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"lin_p", "name": "剑意", "effects": [ { "kind": "crit_rate", "value": 0.10 } ] },
		"skills": [
			{ "id": &"lin_s1", "name": "居合", "cd": 4, "effect": "damage", "target": "single", "rate": 2.50 },
			{ "id": &"lin_s2", "name": "连斩", "cd": 3, "effect": "damage", "target": "single", "rate": 1.20, "bonus": [ { "kind": "combo", "rate": 1.00 } ] },
		],
		"ultimate": { "id": &"lin_u", "name": "霜月斩", "effect": "damage", "target": "single", "rate": 4.00, "bonus": [ { "kind": "crit_bonus", "value": 1.00 } ] },
	},
	&"yuan": {
		"name": "鸢", "rarity": Rarity.SR, "class": "assassin", "role": "刺客",
		"base_atk": 18, "base_hp": 100, "base_def": 5, "base_spd": 13,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"yuan_p", "name": "偷袭", "effects": [ { "kind": "ambush", "rate": 0.80 } ] },
		"skills": [
			{ "id": &"yuan_s1", "name": "飞刃", "cd": 3, "effect": "damage", "target": "single", "rate": 1.80 },
			{ "id": &"yuan_s2", "name": "疾风步", "cd": 5, "effect": "buff", "target": "self", "stat": "dodge", "value": 0.40, "duration": 1 },
		],
		"ultimate": { "id": &"yuan_u", "name": "万刃", "effect": "damage", "target": "single", "rate": 3.50, "bonus": [ { "kind": "armor_break", "value": 0.30, "duration": 2 } ] },
	},
	&"xi": {
		"name": "汐", "rarity": Rarity.SR, "class": "assassin", "role": "刺客",
		"base_atk": 17, "base_hp": 105, "base_def": 5, "base_spd": 12,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"xi_p", "name": "暗影", "effects": [ { "kind": "stun_chance", "chance": 0.10, "duration": 1 } ] },
		"skills": [
			{ "id": &"xi_s1", "name": "影刺", "cd": 3, "effect": "damage", "target": "single", "rate": 2.00 },
			{ "id": &"xi_s2", "name": "雾隐", "cd": 5, "effect": "buff", "target": "self", "stat": "damage_reduce", "value": 0.30, "duration": 2 },
		],
		"ultimate": { "id": &"xi_u", "name": "夜幕", "effect": "damage", "target": "single", "rate": 3.80, "bonus": [ { "kind": "heal_self_on_kill", "value": 0.30, "resource": "energy" } ] },
	},
	&"sun": {
		"name": "隼", "rarity": Rarity.SR, "class": "archer", "role": "射手",
		"base_atk": 19, "base_hp": 90, "base_def": 5, "base_spd": 11,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"sun_p", "name": "鹰眼", "effects": [ { "kind": "crit_rate", "value": 0.15 } ] },
		"skills": [
			{ "id": &"sun_s1", "name": "点射", "cd": 3, "effect": "damage", "target": "lowest_hp", "rate": 2.00 },
			{ "id": &"sun_s2", "name": "双发", "cd": 4, "effect": "damage", "target": "single", "rate": 1.60, "hits": 2 },
		],
		"ultimate": { "id": &"sun_u", "name": "鹰击", "effect": "damage", "target": "single", "rate": 4.50 },
	},
	&"shuang": {
		"name": "霜", "rarity": Rarity.SR, "class": "mage", "role": "法师",
		"base_atk": 18, "base_hp": 85, "base_def": 4, "base_spd": 8,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"shuang_p", "name": "凝霜", "effects": [ { "kind": "stun_chance", "chance": 0.20, "duration": 1, "status": "freeze" } ] },
		"skills": [
			{ "id": &"shuang_s1", "name": "冰锥", "cd": 3, "effect": "damage", "target": "single", "rate": 1.80 },
			{ "id": &"shuang_s2", "name": "霜环", "cd": 5, "effect": "damage", "target": "all", "rate": 1.00, "bonus": [ { "kind": "debuff", "stat": "spd", "value": 0.20, "duration": 2 } ] },
		],
		"ultimate": { "id": &"shuang_u", "name": "极寒", "effect": "damage", "target": "all", "rate": 1.80, "bonus": [ { "kind": "freeze", "chance": 0.50, "duration": 1 } ] },
	},
	&"li2": {
		"name": "璃", "rarity": Rarity.SR, "class": "mage", "role": "法师",
		"base_atk": 17, "base_hp": 90, "base_def": 4, "base_spd": 9,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"li2_p", "name": "水晶", "effects": [ { "kind": "reflect", "chance": 0.30, "rate": 0.50 } ] },
		"skills": [
			{ "id": &"li2_s1", "name": "晶刺", "cd": 3, "effect": "damage", "target": "single", "rate": 1.90 },
			{ "id": &"li2_s2", "name": "晶壁", "cd": 5, "effect": "shield", "target": "all_ally", "rate": 0.15 },
		],
		"ultimate": { "id": &"li2_u", "name": "水晶风暴", "effect": "damage", "target": "all", "rate": 1.60, "bonus": [ { "kind": "stun", "chance": 0.20, "duration": 1 } ] },
	},
	&"tang": {
		"name": "糖", "rarity": Rarity.SR, "class": "support", "role": "辅助",
		"base_atk": 9, "base_hp": 120, "base_def": 9, "base_spd": 8,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"tang_p", "name": "甜蜜", "effects": [ { "kind": "heal_per_round", "value": 0.01 } ] },
		"skills": [
			{ "id": &"tang_s1", "name": "糖弹", "cd": 3, "effect": "heal", "target": "lowest_hp_ally", "rate": 0.25 },
			{ "id": &"tang_s2", "name": "鼓舞", "cd": 4, "effect": "buff", "target": "lowest_hp_ally", "stat": "atk", "value": 0.30, "duration": 2 },
		],
		"ultimate": { "id": &"tang_u", "name": "甜心盛宴", "effect": "heal", "target": "all_ally", "rate": 0.25, "bonus": [ { "kind": "buff", "stat": "atk", "value": 0.15, "duration": 2 } ] },
	},
	# ================= SSR 级 10 位 =================
	&"fei": {
		"name": "绯", "rarity": Rarity.SSR, "class": "fighter", "role": "近战·爆发",
		"base_atk": 26, "base_hp": 160, "base_def": 10, "base_spd": 13,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"fei_p", "name": "绯红战意", "effects": [ { "kind": "enrage", "value": 0.30 } ] },
		"skills": [
			{ "id": &"fei_s1", "name": "双剑乱舞", "cd": 3, "effect": "damage", "target": "single", "rate": 0.70, "hits": 3 },
			{ "id": &"fei_s2", "name": "绯红突进", "cd": 5, "effect": "damage", "target": "single", "rate": 2.20, "bonus": [ { "kind": "chase", "rate": 1.20 } ] },
		],
		"ultimate": { "id": &"fei_u", "name": "绯红终焉斩", "effect": "damage", "target": "front", "rate": 3.00, "bonus": [ { "kind": "chase", "rate": 2.50 } ] },
	},
	&"xinglan": {
		"name": "星澜", "rarity": Rarity.SSR, "class": "mage", "role": "远程·炮击",
		"base_atk": 30, "base_hp": 130, "base_def": 8, "base_spd": 11,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"xinglan_p", "name": "幸运星", "effects": [ { "kind": "dodge_crit", "value": 0.10 } ] },
		"skills": [
			{ "id": &"xinglan_s1", "name": "量子散射", "cd": 3, "effect": "damage", "target": "all", "rate": 0.90, "bonus": [ { "kind": "burn", "chance": 0.30, "rate": 0.30, "duration": 3 } ] },
			{ "id": &"xinglan_s2", "name": "重力压制", "cd": 5, "effect": "damage", "target": "all", "rate": 1.20, "bonus": [ { "kind": "debuff", "stat": "def", "value": 0.20, "duration": 3 } ] },
		],
		"ultimate": { "id": &"xinglan_u", "name": "群星陨落", "effect": "damage", "target": "all", "rate": 2.20, "bonus": [ { "kind": "stun", "chance": 0.50, "duration": 1 } ] },
	},
	&"yue": {
		"name": "岳", "rarity": Rarity.SSR, "class": "tank", "role": "坦克",
		"base_atk": 14, "base_hp": 280, "base_def": 20, "base_spd": 7,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"yue_p", "name": "不动", "effects": [ { "kind": "damage_reduce", "value": 0.10 }, { "kind": "energy_on_hit_taken", "value": 1 } ] },
		"skills": [
			{ "id": &"yue_s1", "name": "山崩", "cd": 4, "effect": "damage", "target": "front", "rate": 1.40, "bonus": [ { "kind": "stun", "chance": 1.0, "duration": 1 } ] },
			{ "id": &"yue_s2", "name": "壁垒", "cd": 3, "effect": "shield", "target": "all_ally", "rate": 0.20 },
		],
		"ultimate": { "id": &"yue_u", "name": "岳镇", "effect": "shield", "target": "all_ally", "rate": 0.35, "bonus": [ { "kind": "buff", "stat": "damage_reduce", "value": 0.20, "duration": 2 }, { "kind": "taunt", "duration": 2 } ] },
	},
	&"jin": {
		"name": "烬", "rarity": Rarity.SSR, "class": "fighter", "role": "战士",
		"base_atk": 27, "base_hp": 150, "base_def": 10, "base_spd": 12,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"jin_p", "name": "余烬", "effects": [ { "kind": "enrage", "value": 0.40 } ] },
		"skills": [
			{ "id": &"jin_s1", "name": "燃刃", "cd": 3, "effect": "damage", "target": "single", "rate": 1.80, "bonus": [ { "kind": "burn", "chance": 1.0, "rate": 0.30, "duration": 2 } ] },
			{ "id": &"jin_s2", "name": "冲锋", "cd": 4, "effect": "damage", "target": "front", "rate": 1.30 },
		],
		"ultimate": { "id": &"jin_u", "name": "焚天", "effect": "damage", "target": "single", "rate": 4.50, "bonus": [ { "kind": "burn_damage_bonus", "value": 1.00 } ] },
	},
	&"ming": {
		"name": "冥", "rarity": Rarity.SSR, "class": "assassin", "role": "刺客",
		"base_atk": 29, "base_hp": 120, "base_def": 7, "base_spd": 14,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"ming_p", "name": "处决", "effects": [ { "kind": "execute_bonus", "value": 0.60, "threshold": 0.30 } ] },
		"skills": [
			{ "id": &"ming_s1", "name": "影刃", "cd": 3, "effect": "damage", "target": "lowest_hp", "rate": 2.20 },
			{ "id": &"ming_s2", "name": "暗步", "cd": 5, "effect": "buff", "target": "self", "stat": "dodge", "value": 0.50, "duration": 1 },
		],
		"ultimate": { "id": &"ming_u", "name": "冥斩", "effect": "damage", "target": "single", "rate": 5.00, "bonus": [ { "kind": "chase", "rate": 1.50 } ] },
	},
	&"ya2": {
		"name": "鸦", "rarity": Rarity.SSR, "class": "assassin", "role": "刺客",
		"base_atk": 28, "base_hp": 125, "base_def": 7, "base_spd": 13,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"ya2_p", "name": "夜幕", "effects": [ { "kind": "atk_aura", "value": 0.05 } ] },
		"skills": [
			{ "id": &"ya2_s1", "name": "羽刃", "cd": 3, "effect": "damage", "target": "single", "rate": 1.90 },
			{ "id": &"ya2_s2", "name": "夜袭", "cd": 4, "effect": "damage", "target": "back", "rate": 2.50 },
		],
		"ultimate": { "id": &"ya2_u", "name": "群鸦", "effect": "damage", "target": "all", "rate": 1.40, "bonus": [ { "kind": "stun", "chance": 0.30, "duration": 1 } ] },
	},
	&"cang": {
		"name": "苍", "rarity": Rarity.SSR, "class": "archer", "role": "射手",
		"base_atk": 30, "base_hp": 115, "base_def": 7, "base_spd": 13,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"cang_p", "name": "天穹", "effects": [ { "kind": "ignore_def", "value": 0.15 } ] },
		"skills": [
			{ "id": &"cang_s1", "name": "狙杀", "cd": 4, "effect": "damage", "target": "lowest_hp", "rate": 3.00 },
			{ "id": &"cang_s2", "name": "速射", "cd": 3, "effect": "damage", "target": "single", "rate": 1.40, "bonus": [ { "kind": "combo", "rate": 1.10 } ] },
		],
		"ultimate": { "id": &"cang_u", "name": "苍穹之矢", "effect": "damage", "target": "single", "rate": 5.50 },
	},
	&"xuan": {
		"name": "璇", "rarity": Rarity.SSR, "class": "mage", "role": "法师",
		"base_atk": 29, "base_hp": 110, "base_def": 6, "base_spd": 10,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"xuan_p", "name": "星璇", "effects": [ { "kind": "energy_on_hit", "value": 8 } ] },
		"skills": [
			{ "id": &"xuan_s1", "name": "星弹", "cd": 3, "effect": "damage", "target": "single", "rate": 2.00 },
			{ "id": &"xuan_s2", "name": "星环", "cd": 5, "effect": "damage", "target": "all", "rate": 1.30, "bonus": [ { "kind": "debuff", "stat": "atk", "value": 0.20, "duration": 2 } ] },
		],
		"ultimate": { "id": &"xuan_u", "name": "星陨", "effect": "damage", "target": "all", "rate": 2.20, "bonus": [ { "kind": "stun", "chance": 0.40, "duration": 1 } ] },
	},
	&"mu": {
		"name": "沐", "rarity": Rarity.SSR, "class": "support", "role": "辅助",
		"base_atk": 12, "base_hp": 160, "base_def": 11, "base_spd": 10,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"mu_p", "name": "甘霖", "effects": [ { "kind": "heal_per_round", "value": 0.02 } ] },
		"skills": [
			{ "id": &"mu_s1", "name": "沐光", "cd": 3, "effect": "heal", "target": "all_ally", "rate": 0.20 },
			{ "id": &"mu_s2", "name": "净化", "cd": 4, "effect": "heal", "target": "all_ally", "rate": 0.10, "bonus": [ { "kind": "cleanse" } ] },
		],
		"ultimate": { "id": &"mu_u", "name": "生命之泉", "effect": "heal", "target": "all_ally", "rate": 0.40, "bonus": [ { "kind": "shield", "rate": 0.20, "duration": 2 } ] },
	},
	&"luo": {
		"name": "洛", "rarity": Rarity.SSR, "class": "support", "role": "辅助",
		"base_atk": 11, "base_hp": 165, "base_def": 12, "base_spd": 9,
		"upgrade_cost": { "base": UPGRADE_COST_BASE, "growth": UPGRADE_COST_GROWTH },
		"growth": { "atk": UPGRADE_GROWTH_ATK, "hp": UPGRADE_GROWTH_HP, "def": UPGRADE_GROWTH_DEF, "spd_every": UPGRADE_GROWTH_SPD_EVERY, "spd_amount": UPGRADE_GROWTH_SPD_AMOUNT },
		"passive": { "id": &"luo_p", "name": "祝福", "effects": [ { "kind": "atk_aura", "value": 0.08 } ] },
		"skills": [
			{ "id": &"luo_s1", "name": "圣咏", "cd": 3, "effect": "buff", "target": "lowest_hp_ally", "stat": "atk", "value": 0.40, "duration": 2 },
			{ "id": &"luo_s2", "name": "庇护", "cd": 4, "effect": "shield", "target": "lowest_hp_ally", "rate": 0.35 },
		],
		"ultimate": { "id": &"luo_u", "name": "神恩", "effect": "buff", "target": "all_ally", "stat": "atk", "value": 0.25, "duration": 2, "bonus": [ { "kind": "buff", "stat": "damage_reduce", "value": 0.15, "duration": 2 } ] },
	},
}

# ------------------------------------------------------------------
# 敌人技能模板库（设计文档 §10.10：共用技能模板库，格式同机娘技能）
#   普通兵 1 技、精英 2 技、BOSS 2 小技 + 1 大招（energy 制）
# ------------------------------------------------------------------
const ENEMY_SKILLS := {
	&"enemy_heavy": { "name": "重击", "cd": 3, "effect": "damage", "target": "single", "rate": 1.50 },
	&"enemy_sweep": { "name": "横扫", "cd": 4, "effect": "damage", "target": "front", "rate": 1.10 },
	&"enemy_shot": { "name": "射击", "cd": 3, "effect": "damage", "target": "single", "rate": 1.30 },
	&"enemy_burn": { "name": "灼烧弹", "cd": 4, "effect": "damage", "target": "single", "rate": 1.20, "bonus": [ { "kind": "burn", "chance": 0.40, "rate": 0.30, "duration": 3 } ] },
	&"enemy_ice": { "name": "冰锥", "cd": 4, "effect": "damage", "target": "single", "rate": 1.40, "bonus": [ { "kind": "freeze", "chance": 0.30, "duration": 1 } ] },
	&"enemy_heal": { "name": "治疗", "cd": 4, "effect": "heal", "target": "lowest_hp_ally", "rate": 1.50 },
	&"enemy_shield": { "name": "护盾", "cd": 4, "effect": "shield", "target": "self", "rate": 0.20 },
	&"enemy_taunt": { "name": "嘲讽", "cd": 5, "effect": "taunt", "target": "self", "duration": 2 },
	&"enemy_boss_ult": { "name": "毁灭光束", "cd": 0, "effect": "damage", "target": "all", "rate": 1.80, "is_ultimate": true },
}

# ------------------------------------------------------------------
# 关卡数值表（v0.8 战斗 2.0：每关 1~3 波、每波最多 5 名敌人、章节 BOSS 关）
#   字段：waves（数组的数组：每波 = 敌人数组）/
#         first_clear_reward / first_clear_reward_diamond / victory_reward_exp
#   说明：
#     - 敌人数值按 5v5 规模重调（单敌面板下调、总难度适配）——推荐值【待确认】
#     - 敌人 def/spd：v0.14 敌人 3 类（普通/精英/BOSS），此处补全四维
#     - 第 1 章 5 关：1~4 普通关（1~2 波）、第 5 关章节 BOSS（3 波，BOSS 带大招）
#     - tier: normal / elite / boss；class 用于 AI 排阵（tank 前排）
#     - 敌人技能引用 ENEMY_SKILLS：普通 1 技 / 精英 2 技 / BOSS 2 小技 + ultimate
# ------------------------------------------------------------------
const LEVELS := {
	1: {
		"waves": [
			[
				{ "id": &"e1_w1a", "name": "暴走机械兵", "tier": "normal", "class": "fighter", "atk": 8, "hp": 70, "def": 3, "spd": 5, "skills": [&"enemy_shot"] },
				{ "id": &"e1_w1b", "name": "暴走机械兵", "tier": "normal", "class": "fighter", "atk": 8, "hp": 70, "def": 3, "spd": 5, "skills": [&"enemy_shot"] },
			],
		],
		"first_clear_reward": 100,
		"first_clear_reward_diamond": 30,
		"victory_reward_exp": 13,
	},
	2: {
		"waves": [
			[
				{ "id": &"e2_w1a", "name": "暴走机械兵", "tier": "normal", "class": "fighter", "atk": 10, "hp": 85, "def": 4, "spd": 5, "skills": [&"enemy_shot"] },
				{ "id": &"e2_w1b", "name": "暴走机械兵", "tier": "normal", "class": "fighter", "atk": 10, "hp": 85, "def": 4, "spd": 5, "skills": [&"enemy_heavy"] },
				{ "id": &"e2_w1c", "name": "暴走机械兵", "tier": "normal", "class": "tank", "atk": 8, "hp": 100, "def": 6, "spd": 4, "skills": [&"enemy_heavy"] },
			],
		],
		"first_clear_reward": 150,
		"first_clear_reward_diamond": 40,
		"victory_reward_exp": 16,
	},
	3: {
		"waves": [
			[
				{ "id": &"e3_w1a", "name": "暴走机械兵", "tier": "normal", "class": "fighter", "atk": 12, "hp": 100, "def": 4, "spd": 5, "skills": [&"enemy_shot"] },
				{ "id": &"e3_w1b", "name": "暴走机械兵", "tier": "normal", "class": "archer", "atk": 14, "hp": 80, "def": 3, "spd": 6, "skills": [&"enemy_shot"] },
				{ "id": &"e3_w1c", "name": "暴走机械兵", "tier": "normal", "class": "tank", "atk": 10, "hp": 120, "def": 7, "spd": 4, "skills": [&"enemy_heavy"] },
			],
			[
				{ "id": &"e3_w2a", "name": "暴走精英", "tier": "elite", "class": "fighter", "atk": 16, "hp": 150, "def": 6, "spd": 6, "skills": [&"enemy_sweep", &"enemy_heavy"] },
			],
		],
		"first_clear_reward": 220,
		"first_clear_reward_diamond": 50,
		"victory_reward_exp": 19,
	},
	4: {
		"waves": [
			[
				{ "id": &"e4_w1a", "name": "暴走机械兵", "tier": "normal", "class": "fighter", "atk": 13, "hp": 110, "def": 5, "spd": 5, "skills": [&"enemy_shot"] },
				{ "id": &"e4_w1b", "name": "暴走机械兵", "tier": "normal", "class": "archer", "atk": 15, "hp": 90, "def": 4, "spd": 6, "skills": [&"enemy_shot"] },
				{ "id": &"e4_w1c", "name": "暴走机械兵", "tier": "normal", "class": "tank", "atk": 11, "hp": 130, "def": 8, "spd": 4, "skills": [&"enemy_heavy"] },
			],
			[
				{ "id": &"e4_w2a", "name": "暴走精英", "tier": "elite", "class": "fighter", "atk": 18, "hp": 170, "def": 7, "spd": 6, "skills": [&"enemy_sweep", &"enemy_burn"] },
				{ "id": &"e4_w2b", "name": "暴走精英", "tier": "elite", "class": "mage", "atk": 20, "hp": 130, "def": 5, "spd": 7, "skills": [&"enemy_ice", &"enemy_shot"] },
			],
		],
		"first_clear_reward": 320,
		"first_clear_reward_diamond": 60,
		"victory_reward_exp": 22,
	},
	5: {
		"waves": [
			[
				{ "id": &"e5_w1a", "name": "暴走机械兵", "tier": "normal", "class": "fighter", "atk": 14, "hp": 120, "def": 5, "spd": 5, "skills": [&"enemy_shot"] },
				{ "id": &"e5_w1b", "name": "暴走机械兵", "tier": "normal", "class": "archer", "atk": 16, "hp": 100, "def": 4, "spd": 6, "skills": [&"enemy_shot"] },
			],
			[
				{ "id": &"e5_w2a", "name": "暴走精英", "tier": "elite", "class": "fighter", "atk": 20, "hp": 190, "def": 8, "spd": 6, "skills": [&"enemy_sweep", &"enemy_heavy"] },
				{ "id": &"e5_w2b", "name": "暴走精英", "tier": "elite", "class": "support", "atk": 12, "hp": 160, "def": 7, "spd": 5, "skills": [&"enemy_heal", &"enemy_shield"] },
			],
			[
				{ "id": &"e5_boss", "name": "街区机械头目", "tier": "boss", "class": "tank", "atk": 30, "hp": 600, "def": 12, "spd": 8, "skills": [&"enemy_sweep", &"enemy_heavy"], "ultimate": &"enemy_boss_ult" },
			],
		],
		"first_clear_reward": 480,
		"first_clear_reward_diamond": 80,
		"victory_reward_exp": 25,
	},
}
