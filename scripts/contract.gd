# 机娘放置挂机游戏 · 公共契约（代码版） v0.7
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
const CONTRACT_VERSION := "v0.7"

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
const TERM_PAID_COIN := "paid_coin"   # 付费币（阶段 4 起用）

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
