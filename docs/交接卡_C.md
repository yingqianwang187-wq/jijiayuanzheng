# 【交接卡_C】

- **项目**：机娘放置挂机游戏（机甲远征），项目文件夹 `ceshi`，当前契约 **v0.16** / 设计文档 **v0.21**
- **角色**：画面与界面会话 C
- **项目现状一句话**：阶段 3 全部完成并上线、v0.16（4A：爬塔/签到/每日周任务/新手7日）已上线并通过 Godot headless 验证；下一步为 4B（图鉴/成就/称号/好感）与 4U（已有界面按设计文档 §1.6 逐格对齐）。
- **我负责的文件**（除 C 初版 8 个外，还创建了 v0.13~v0.16 的 8 个界面，**全部**为 C 所有）：
  - 场景：`scenes/Main.tscn`、`scenes/Battle.tscn`、`scenes/Formation.tscn`、`scenes/Gacha.tscn`、`scenes/Dungeon.tscn`、`scenes/Bag.tscn`、`scenes/Equipment.tscn`、`scenes/Shop.tscn`、`scenes/Settings.tscn`、`scenes/Tower.tscn`、`scenes/Task.tscn`、`scenes/Novice.tscn`
  - 脚本：`scripts/main_ui.gd`、`scripts/battle_view.gd`、`scripts/formation_ui.gd`、`scripts/gacha_ui.gd`、`scripts/dungeon_ui.gd`、`scripts/bag_ui.gd`、`scripts/equipment_ui.gd`、`scripts/shop_ui.gd`、`scripts/settings_ui.gd`、`scripts/tower_ui.gd`、`scripts/task_ui.gd`、`scripts/novice_ui.gd`
- **已完成的事**（按版本，每轮均 Godot 4.7.2 headless 实跑验证 + 红线 grep）：
  - **v0.1~v0.2**：主界面（金币/机娘列表/升级/关卡选择/进入战斗）与战斗场景初版；`battle_failed` 失败重试
  - **v0.4**：挂机收获（金币+经验）、机娘个人经验条、`idle_rewards_updated(gold, exp)` 改签名
  - **v0.5**：返回=中止战斗（`Game.stop_battle`）、升级按钮禁用+原因提示（`upgrade_cost/upgrade_exp_cost` 只读）、上次通关消息；小补丁：`last_clear_label` 独立标签、重复通关无"+0"
  - **v0.6**：右上角余额（金币/经验含待收获，千分位）、`exp_balance_updated`
  - **v0.7**：抽卡界面（`Gacha.tscn`+`gacha_ui.gd`，池切换/单抽十连/保底/结果展示）、主界面钻石+拥有列表
  - **v0.8**：布阵界面（`Formation.tscn`，3x3 九宫格/候选放置/预设存载）、**战斗 2.0 重写**（11 信号、双方九宫格、技能名/能量条/状态/波次/分色提示/星级/简版统计/2x）；复验轮 + 挑战按钮 connect 微补丁
  - **v0.9**：主线改单"挑战第 N 关"按钮（`Game.get_next_level`，去选关列表）、首通奖励含小钰碎片、战斗去扫荡
  - **v0.10**：机娘星级显示（★N）与等级上限（`get_level_cap`）、升星按钮（`star_cost`/`upgrade_star`/`mech_star_updated`）；修复"初始信号重建列表后行显示占位"缺陷（新增 `_render_all_rows`）
  - **v0.13**：体力显示、秘境（`Dungeon.tscn`，5副本×5档/挑战/扫荡）、背包（`Bag.tscn`，容量/扩容）、开箱按钮；**battle_view 秘境适配**（标题"副本名·档位"/重试 `start_dungeon`/connect `dungeon_reward`）
  - **v0.14**：装备界面（`Equipment.tscn`，穿卸/强化/3合1合成/宝石镶拆合/词条显示）
  - **v0.15**：商城（`Shop.tscn`，每日商品/限购/已购置灰）、设置（`Settings.tscn`，开关/音量/2x/语言/存档导出 JSON/重置二次确认弹窗）
  - **v0.16**：爬塔（`Tower.tscn`）、任务（`Task.tscn`，日/周页签+档位领奖）、新手福利（`Novice.tscn`，7日领奖）、主界面签到按钮（`sign_in`/`sign_changed`/连签显示）；**battle_view 爬塔三分支**（标题"第 N 层·爬塔"读 `dungeon_ctx.layer`/重试 `start_tower`/满上限隐藏重试/`tower_changed` 通关反馈）
  - **D 复核补丁**：秘境失败体力不足隐藏重试+"体力不足，无法重试"（#26 模式）
- **关键决策/当前依赖**：
  1. 界面按 `docs/设计文档.md` §1.6 的十八界面布局实现/对齐（4B 新界面按 §1.6 ⑨⑩⑮⑰；4U 已有界面逐格对齐）
  2. 只 connect 信号显示，绝不改数值、绝不 emit（契约 §3.1 红线）；一切显示值以信号参数为准
  3. 场景节点/组名/血条命名按契约术语表（snake_case、`hp_bar`、组 `mech_girl`/`enemy`）
  4. **首屏快照模式**（契约 §3.1"首屏铺底例外"）：`_ready` 时只读 Game 公开状态铺首屏（场景切换收不到信号），此后一切走信号；波次切换/`wave_changed` 同理只读 `Game.battle` 布局
  5. **读 B 实际返回字段**（与契约文档字段名有出入，以 B 实现为准）：`star_cost() -> {fragments, level_required}`、`get_shop_items() -> {items, bought}`、`get_tower_info() -> {highest, daily_count, daily_limit}`、爬塔层数在 `battle.dungeon_ctx.layer`
  6. **⚠️ B 的 game.gd 秘境波次 bug 未修复**（已多轮报告）：`_start_dungeon_battle` 误用 `tier_cfg.waves`，正确为 `battle.pending_waves.append(Data.DUNGEONS[kind].waves[tier])`——本地验证秘境挑战前需在临时副本打此补丁
- **当前进行中/待办**（以 `docs/项目状态.md` 为准）：
  - 用户浏览器 **Ctrl+F5 在线验证 v0.16（4A）**（爬塔/签到/任务/新手福利）
  - **4B 开工**（契约 v0.17：图鉴/成就/称号/好感，按 §1.6 ⑨⑩⑮⑰ 实现）
  - **4U UI 布局对齐批次**（已有界面按 §1.6 逐格对齐，C 分批派单）
  - 观察项：满体力可购买、问题清单 #19/#20；**问题清单 #20 满级按钮置灰**（待办）
- **还没做完的事 / 下一步**：等 A 派 4B 单（新信号/入口先读契约 v0.17 + contract.gd）与 4U 对齐单；每轮交付后输出【交付说明】；B 的 game.gd 秘境 waves bug 持续提醒 A 修复后再做秘境完整回归
- **依赖的约定**：`docs/契约.md` v0.16（§3.5 信号 / §3.6 入口 / §3.10~3.13）、`docs/设计文档.md` v0.21（§1.6 界面布局）、`docs/工作原则.md`（8 条）、`scripts/contract.gd`（代码版契约，信号权威）
- **跨会话规则（重要）**：其他会话（A/B/D/P）是独立会话，消息由用户（人）转达；需要 A 裁决/契约变更时输出【变更申请】给用户转达。不要开子代理、不要直接指挥其他会话。只允许修改自己所有（C）的文件；改 B/A 文件 = 违规，只能提变更申请。
- **给下一位的提醒**：
  1. 开工前必读：`docs/工作原则.md`、`docs/契约.md`、`scripts/contract.gd`、`docs/设计文档.md`（§1.6）、`docs/项目状态.md`（当前唯一权威待办）
  2. 红线自查固定动作：对改动脚本 grep `emit|gold=|hp=|diamond=|...`（应只命中注释行）
  3. 验证固定流程：复制全工程到 `%TEMP%\godot_ui_check`（含全部 .gd/.tscn + 临时 project.godot 注册 4 autoload），用 `D:\Godot\Godot_v4.7.2-stable_win64.exe --headless --path <temp>` + 测试 autoload 实跑；跑前给临时 `game.gd` 副本打秘境 waves 补丁；结束后清理临时目录与残留 Godot 进程
  4. 已多轮验证稳定：主界面全入口、各界面信号驱动刷新；新增界面一律"只 connect + 只调 Game 入口 + 只读 Data/Game"
  5. 与 B 字段不一致时按 B 实际实现读并在交付说明标注（提请 A 对齐契约文档）
  6. 存档/测试造数据（如 `Game.equip_inventory.append(...)`）仅用于临时验证环境，不要写进交付代码
