# 机娘放置挂机游戏 · 公共契约（代码版） v0.11
# ==================================================================
# 作者   ：契约官（= 总指挥 A，手册第三节；只写契约与常量脚本，不写业务逻辑）
# 依据   ：docs/契约.md（文档版，必须与本文件同步修改、同步升版本号）
#         ：docs/设计文档.md（v0.1 定稿，玩法与数值的唯一来源）
#         ：机甲远征·完整开发手册.md（第三节文件所有权 / 第五节契约文档）
# 职责   ：本文件是 常量 / 信号 / 术语 / 自动加载名 的唯一权威。
# 铁律   ：只允许"声明"，禁止写任何业务逻辑
#         （禁止赋值、循环、算法、UI 操作、文件读写等一切运行时代码）。
# 信号规则：所有信号在本文件声明；只有 Game 允许 emit，
#          UI 只允许 connect，其他脚本两者都不做（契约 §3.1 / §3.5）。
# 自动加载：本文件注册为名为 Contract 的 autoload，注册顺序固定：
#          Contract → Data → Save → Game（依赖在前，见契约 §2.1）。
# 变更规则：改本文件 = 改契约。先向总指挥 A 提变更申请，获准后由契约官
#          同步更新 docs/契约.md 与本文件，并升级版本号（契约 §④）。
# 变更记录：
#   v0.14（阶段 3 第二批：装备+宝石+强化，设计文档 v0.20）：新增信号 equip_inventory_changed /
#       equipped_changed / gem_stock_changed；术语新增 equipment / gem / affix / socket / enchant。
#   v0.13（阶段 3 第一批：体力+秘境+背包+开箱，设计文档 v0.19）：新增信号 stamina_changed /
#       bag_updated / box_count_changed / dungeon_reward / dungeon_cleared_changed；
#       术语新增 stamina / dungeon / bag / box / item。
#   v0.12（规则澄清，设计文档 v0.19）："被控不加能量"含受击（被控期间受击也不加能量，
#       措辞澄清，实现已符合）；"追击同排"= 同一列（派单 B 改 game.gd 追击按列匹配）。
#       无新信号 / 新常量 / 新入口。
#   v0.11（移除充值/付费）：删除付费币（TERM_PAID_COIN）与一切充值相关内容；
#       钻石来源改为 首通 + 每日/周活跃度奖励（无充值）；联动设计文档 v0.18（策划官 P 已同步）。
#   v0.10（战斗判定/星级体系/开局运营，设计文档 v0.18）：新增信号 mech_star_updated；
#       入口 upgrade_star / star_cost / get_level_cap；战斗判定细则（先闪避后暴击、护盾叠加、
#       嘲讽只影响普攻+单体技、被控不加能量、追击/连击/反击算普攻等）；升星 1~10 星
#       （1~5 星碎片升星 +8%/星；6~10 星满级 100 解锁、每星 +20 级上限）；开局金币 1000+钻石 300；
#       召唤券 1 券 = 300 钻 = 1 抽；满级经验不累计。
#   v0.9（主线玩法调整，文档级规则，无新信号/新常量）：主线不可选关（只能打当前最高未通关的下一关，
#       新增只读入口 Game.get_next_level()）；主线不可扫荡（扫荡仅限秘境，阶段 3 实装）；
#       首通掉落小钰碎片（普通 1 片 / BOSS 3 片）；主线不可重打（非首通重复胜利经验不再适用）。
#   v0.8（阶段 2 战斗 2.0）：九宫格 5v5、全自动战斗；新增信号 skill_cast / energy_changed /
#               status_changed / wave_changed / battle_prompt / battle_star / formation_changed；
#               6 职业（坦克/战士/刺客/射手/法师/辅助）+ 克制环；技能（被动/2 小技/大招）、能量、暴击闪避、
#               状态、多波+BOSS、2x 加速+扫荡、1~3 星、阵型预设、伤害统计；术语新增职业/技能/能量/战力等。
#   v0.7（阶段 1 抽卡）：钻石货币（信号 diamond_changed）；抽卡系统（信号 gacha_result、
#               入口 summon/summon_cost/summon_pity_info/get_owned_mechs）；新机娘与卡池数据；
#               碎片计数（信号 fragments_updated）；拥有与上阵（信号 owned_mechs_updated）。
#   v0.6（本次）：挂机同产经验（idle_rewards_updated 改为 (gold, exp)，存档 idle_pending_exp / exp_balance）；
#               经验分个人条 + 全局余额（新增信号 exp_balance_updated）；升级先个人条后余额补；右上角余额展示。
#   v0.5：文档约定，无新信号/新常量——新增 Game 入口 stop_battle()、
#               upgrade_cost(id) / upgrade_exp_cost(id)（§3.6）；阵亡机娘也得经验
#               （§1.3 澄清）；Game 内存态 last_clear（不入档）供主界面快照显示。
#   v0.4：挂机改"点一下收获"（新增信号 idle_rewards_updated、
#               入口 Game.collect_idle()、存档 idle_pending/idle_last_time）；
#               升级改金币+经验双消耗（新增信号 mech_exp_updated、存档 mechs.exp）；
#               战斗胜利掉机娘经验（非首通重复胜利也给）；战斗规模可扩展 5v5（数组）。
#   v0.3：文档澄清，无新信号/新常量——首屏铺底只读快照例外（§3.1）、
#       战斗外 hp 为满血（§3.5）、升级费用暂不显示（UI 不推算）。
#   v0.2：新增信号 battle_failed(level)；存档形状扩展 first_cleared；
#        明确自动存档时机（升级/通关即时、挂机金币 5 秒节流）
#        与 save_game() 经 Game.get_save_snapshot() 取只读快照。
#   v0.1：初版。
# ==================================================================
extends Node

## 契约版本号 —— 必须与 docs/契约.md 顶部版本号一致
const CONTRACT_VERSION := "v0.14"

# ------------------------------------------------------------------
# ② 自动加载单例（autoload）名 —— 必须与 project.godot 注册名一致
# ------------------------------------------------------------------
const NODE_CONTRACT := "Contract"   # 本契约代码版（常量 / 信号 / 术语）
const NODE_DATA     := "Data"       # 机娘 / 敌人 / 关卡数值表
const NODE_SAVE     := "Save"       # 存档读写（唯一负责方）
const NODE_GAME     := "Game"       # 状态与规则（唯一改数值者、唯一 emit 信号者）

# ------------------------------------------------------------------
# ⑤ 术语表 —— 全项目统一用词，禁止另起别名
# ------------------------------------------------------------------
const TERM_MECH_GIRL := "mech_girl"   # 机娘
const TERM_LEVEL     := "level"       # 关卡
const TERM_GOLD      := "gold"        # 金币
const TERM_HP_BAR    := "hp_bar"      # 血条
const TERM_ATK       := "atk"         # 攻击
const TERM_HP        := "hp"          # 血量
const TERM_UPGRADE   := "upgrade"     # 升级
const TERM_EXP       := "exp"         # 机娘个人经验条（战斗胜利获得，升级消耗）
const TERM_EXP_BALANCE := "exp_balance"  # 全局经验余额（挂机经验随收获入账，升级补足时扣减）
const TERM_SIGNAL    := "signal"      # 信号
const TERM_AUTOLOAD  := "autoload"    # 自动加载

# ---- 扩展术语（设计文档 §2.1 / §3.1，供 Data 数值表与后续阶段使用）----
const TERM_DEF       := "def"         # 防御（属性四维之一）
const TERM_SPD       := "spd"         # 速度（属性四维之一，出手排序依据）
const TERM_DIAMOND   := "diamond"     # 钻石（阶段 1 起用）
const TERM_FRAGMENT  := "fragment"    # 碎片（重复机娘转化所得，升星素材）
const TERM_SUMMON    := "summon"      # 抽卡
const TERM_SUMMON_TICKET := "summon_ticket"  # 召唤券（等价钻石，阶段 2 启用来源）

# ---- 战斗 2.0 术语（阶段 2，设计文档 §2.5 / §8.3 / §10.10）----
const TERM_CLASS_TANK     := "tank"      # 坦克（前排抗伤）
const TERM_CLASS_FIGHTER  := "fighter"   # 战士（近战均衡）
const TERM_CLASS_ASSASSIN := "assassin"  # 刺客（近战爆发）
const TERM_CLASS_ARCHER   := "archer"    # 射手（远程物理）
const TERM_CLASS_MAGE     := "mage"      # 法师（远程魔法）
const TERM_CLASS_SUPPORT  := "support"   # 辅助（治疗/增益）
const TERM_SKILL          := "skill"     # 技能（被动/小技/大招）
const TERM_ENERGY         := "energy"    # 能量（大招充能，100 满）
const TERM_CRIT           := "crit"      # 暴击
const TERM_DODGE          := "dodge"     # 闪避
const TERM_STATUS         := "status"    # 状态效果（眩晕/灼烧/中毒/加攻/减防/治疗/护盾）
const TERM_WAVE           := "wave"      # 波次
const TERM_BOSS           := "boss"      # 章节 Boss
const TERM_FORMATION      := "formation" # 阵型（3x3 九宫格选 5 格布阵）
const TERM_STAR           := "star"      # 关卡星级（1~3 星）
const TERM_STAR_UPGRADE   := "star_upgrade"  # 机娘升星（1~10 星）
const TERM_LEVEL_CAP      := "level_cap"     # 等级上限（基础 100，星突破每星 +20）

# ---- 阶段 3 术语（设计文档 §3.8 / §7 / §10.1 / §6，v0.13）----
const TERM_STAMINA := "stamina"        # 体力（秘境消耗；上限 100、5 分钟回 1、满上限停恢复）
const TERM_DUNGEON := "dungeon"        # 秘境（金币/经验/装备/宝石/碎片 × 5 档战力门槛）
const TERM_BAG     := "bag"            # 背包（道具/材料/碎片/装备库存；初始 50 格可扩容至 300）
const TERM_BOX     := "box"            # 开箱（关卡/任务发放的宝箱，直接开）
const TERM_ITEM    := "item"           # 道具（背包物品：经验药水/体力道具/加速道具/材料）

# ---- 阶段 3 装备术语（设计文档 §2.6 / §10.6，v0.14）----
const TERM_EQUIPMENT := "equipment"    # 装备（四部位：武器/装甲/护腿/战靴，1~5 星）
const TERM_GEM       := "gem"          # 宝石（白绿蓝紫金红 6 品；孔随星级；免费拆卸）
const TERM_AFFIX     := "affix"        # 词条（攻%/血%/防%/速/暴击率/暴伤/闪避）
const TERM_SOCKET    := "socket"       # 孔（1星1孔/3星2孔/5星3孔）
const TERM_ENCHANT   := "enchant"      # 强化（+1~+10，金币+材料）

# ------------------------------------------------------------------
# 稀有度（设计文档 §2.1：R / SR / SSR）—— 供 Data 数值表使用
# ------------------------------------------------------------------
enum Rarity { R, SR, SSR }

# ------------------------------------------------------------------
# ③ 信号 —— 唯一变更通知通道（清单见 docs/契约.md §3.5）
# 规则：
#   - 只有 Game 允许 emit 下列信号；任何其他脚本 emit 即违规。
#   - UI 只允许 connect 信号做显示，不允许自行修改数值。
#   - 一切显示值以信号参数为准，UI 不缓存、不推算。
# ------------------------------------------------------------------
signal gold_changed(value: int)                                          # 金币变化
signal mech_girl_updated(id: StringName, hp: int, atk: int, level: int)  # 机娘状态变化
signal enemy_updated(id: StringName, hp: int)                            # 敌人血量变化（刷新血条）
signal battle_tick(tick: int)                                            # 战斗节拍（每秒 1 轮）
signal level_cleared(level: int, first_clear: bool)                      # 关卡通过（含是否首通）
signal battle_failed(level: int)                                         # 战斗失败（我方全灭；UI 显示失败/重试）
signal level_progress_changed(level: int)                                # 当前关卡变化
signal idle_rewards_updated(gold: int, exp: int)                         # 待收获金币与经验（挂机累计，含离线；收获后发 0,0）
signal mech_exp_updated(id: StringName, exp: int, exp_next: int)         # 机娘个人经验条（战斗胜利得经验 / 升级消耗后）
signal exp_balance_updated(balance: int)                                 # 全局经验余额（挂机收获入账 / 升级补足扣减后）
signal diamond_changed(value: int)                                        # 钻石变化（首通奖励 / 抽卡消耗后）
signal fragments_updated(id: StringName, count: int)                      # 某机娘碎片变化（抽到重复机娘转化后）
signal gacha_result(entries: Array)                                       # 抽卡结果（每项 {id, rarity, is_new, fragments}）
signal owned_mechs_updated(ids: Array)                                    # 已拥有机娘 id 列表变化（抽到新机娘后）
signal skill_cast(side: StringName, unit_id: StringName, skill_id: StringName, value: int)  # 技能释放（小技/大招/被动触发；value=伤害/治疗/护盾）
signal energy_changed(side: StringName, unit_id: StringName, energy: int)  # 能量变化
signal status_changed(side: StringName, unit_id: StringName, status_id: StringName, duration: int)  # 状态增/刷新(duration>0)或移除(0)
signal wave_changed(wave: int, total: int)                                 # 波次变化
signal battle_prompt(kind: StringName, text: String)                       # 战斗提示（hit/crit/dodge/kill/skill/heal/shield，按 kind 分色）
signal battle_star(star: int)                                              # 关卡星级评价（1~3 星）
signal formation_changed(formation: Array)                                 # 阵型变化（9 格选 5，每格 {id, row, col}）
signal mech_star_updated(id: StringName, star: int, level_cap: int)        # 机娘星级变化（升星后；level_cap=当前等级上限）

# ---- 阶段 3 信号（v0.13：体力 / 秘境 / 背包 / 开箱）----
signal stamina_changed(value: int)                                            # 体力变化（恢复结算/秘境消耗/买体力后）
signal bag_updated(items: Dictionary, capacity: int)                          # 背包变化（道具增减/扩容；items={item_id:count}）
signal box_count_changed(count: int)                                          # 待开箱数变化（主线首通发放/开箱后）
signal box_opened(reward: Dictionary)                                          # 开箱结果（{type:"gold"/"material"/"fragment", amount, mech_id?}；入账走既有信号）
signal dungeon_reward(kind: StringName, tier: int, rewards: Dictionary)       # 秘境通关奖励（展示用；入账走既有信号）
signal dungeon_cleared_changed(status: Dictionary)                            # 秘境通关记录变化（解锁/扫荡可用状态）

# ---- 阶段 3 装备信号（v0.14：装备 / 宝石）----
signal equip_inventory_changed(inventory: Array)                              # 装备库变化（掉落/合成/强化后）
signal equipped_changed(equipped: Dictionary)                                 # 穿戴变化（穿/卸后；属性变化随 mech_girl_updated）
signal gem_stock_changed(stock: Dictionary)                                   # 宝石库存变化（镶嵌/拆卸/合成后）
