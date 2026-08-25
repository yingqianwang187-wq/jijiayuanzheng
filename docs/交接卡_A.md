# 【交接卡_A】

- 项目：机娘放置挂机游戏（机甲远征），项目文件夹 `C:\Users\28015\DEEPSEEK\ceshi`，**游戏版本 v0.10（已上线）**，**契约版本 v0.11**
- 角色：总指挥 A（兼契约官）
- 项目现状一句话：v0.10 已上线（https://jiangmufeng.online/game/jijiayuanzheng/）——阶段 0~2 完成（MVP / 抽卡 / 战斗 2.0 / 主线调整 / 战斗判定 / 升星 1~10 星 / 移除充值），契约 v0.11、设计文档 v0.18，待办仅观察项与阶段 3 规划。
- 已完成的事（要点）：
  1. 设计文档 v0.18 定稿（策划官 P）：世界观/货币/抽卡/战斗 2.0/升星/主线规则/装备/秘境/爬塔/任务/成就等全阶段设计
  2. 契约 v0.11（docs/契约.md + scripts/contract.gd 双载体）：金币/钻石/召唤券三资源；挂机点收获+经验；升级金币+经验双消耗；战斗 2.0（九宫格/技能/能量/克制/暴击闪避/状态/波次/BOSS/星级）；主线不可选关/不可扫荡/首通小钰碎片；升星 1~10 星；移除充值/付费（无付费币）
  3. B/C 各轮交付并验收：data/save/game（挂机/抽卡/战斗 2.0/升星）+ main_ui/battle_view/gacha_ui/formation_ui + Main/Battle/Gacha/Formation 场景
  4. project.godot 装配（自动加载 Contract→Data→Save→Game、GL Compatibility、默认中文字体）
  5. D 多轮只读验收（契约零违规）；问题清单 21 条（15~18 闭环，19/20/21 待办）
  6. GitHub 仓库 yingqianwang187-wq/jijiayuanzheng（已全部同步）
  7. Godot Web 导出 + 上传服务器（/var/www/game/jijiayuanzheng/）+ 子集字体（1395 字符，含中文）
- 你拥有的文件：project.godot、.gitignore、export_presets.cfg、scripts/contract.gd、docs/契约.md、docs/项目状态.md、docs/问题清单.md、docs/变更单.md、docs/验收报告.md、docs/任务清单.md、docs/工作原则.md、（另：机甲远征·完整开发手册.md 为团队手册，根目录）
- 你的关键习惯/规则：
  1. 契约改版 = docs/契约.md + scripts/contract.gd 同步改、版本号同步升（当前 v0.11）；变更记录必须写
  2. 只有你能改契约和 project.godot；改别人文件 = 提变更申请（设计文档→P、B 文件→B、C 文件→C）
  3. 每轮交付后更新 docs/项目状态.md
  4. 流程铁律：P 出设计 → 你升契约 → 变更单（docs/变更单.md）→ 派单 B → 验收 → 派单 C → 验收 → 用户 F5 → D 只读复核 → 重生成子集字体 → 重新导出 Web → 上传
  5. 新增中文字后、重新导出前，必须重生成子集字体（方法见"给下一位的提醒"）
- 当前进行中/待办（以 docs/项目状态.md 为准）：① 验证 v0.10 在线版（Ctrl+F5；网页版旧档需清站点数据才见新档开局）；② 观察项 #19（ENEMY_SKILLS 补 id，随 data.gd 批次）/ #20（满级升级按钮置灰，随 C 批次）/ #21（"被控不加能量"是否含受击，待 P 澄清）；③ 阶段 3 规划（商城/背包/开箱/装备/秘境/体力）
- 还没做完的事 / 下一步：① 待办观察项处理；② 阶段 3：请 P 出设计 → 契约 v0.12 → 派单 B/C；③ （可选）安卓 APK 打包（上次导出未成功，需配 Android 导出模板+签名）、域名正式证书（当前自签，浏览器警告）；④ 安全：GitHub token 与服务器 root 密码都出现在历史聊天中，建议吊销/更改
- 依赖的约定：docs/契约.md **v0.11**、docs/设计文档.md **v0.18**、docs/工作原则.md（8 条）、机甲远征·完整开发手册.md（第三节所有权 / 第五节契约流程）
- 给下一位的提醒（操作要点，务必看）：
  1. **Git 推送**：本地已 init+提交；推送用 `git -c http.sslBackend=openssl -c credential.helper= push "https://x-access-token:<TOKEN>@github.com/yingqianwang187-wq/jijiayuanzheng.git" main`（直连，**别走代理 127.0.0.1:7890**，代理常断；网络不稳时多试几次直连）
  2. **上传服务器**：Node 18+ 可用（网络直连 OK）；临时目录里 `npm install ssh2 --ignore-scripts` 后写脚本 SFTP 上传 `D:\Godot\jijia` → `/var/www/game/jijiayuanzheng/`；服务器 47.94.104.210:22 root（密码在历史聊天，用后建议改）；URL 是自签证书，验证用 `NODE_TLS_REJECT_UNAUTHORIZED=0` + node fetch
  3. **子集字体重生成**：临时目录下载 Noto Sans SC（fonts.gstatic.com 的 10MB URL）→ `npm install subset-font --ignore-scripts` → 脚本扫描项目 .gd/.tscn/.md + project.godot 提取字符 → subsetFont sfnt → 写 assets/fonts/NotoSansSC-subset.ttf；每次加新中文字后必须做
  4. **开新档**：删 `%APPDATA%\Godot\app_userdata\机甲远征\save.json`（先备份 .bak；该路径在工作区外，沙箱需 danger-full-access 或让用户手动删；游戏运行时文件被锁，必须先关游戏）
  5. 本环境沙箱无外网时用 Node（直连可用）；curl/git 直连 TLS 有问题时用 `http.sslBackend=openssl`
  6. 每轮用户实测通过后，更新 docs/项目状态.md 并 commit
