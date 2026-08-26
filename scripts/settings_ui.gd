# ==================================================================
# scripts/settings_ui.gd —— 设置界面脚本（挂在 scenes/Settings.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.12（v0.15）、scripts/contract.gd（只读）
# 职责   ：设置界面的纯显示层 + 修改入口。
#          - 连接信号：settings_changed（设置变化后刷新全部控件）
#          - 按钮/控件只调入口（契约 §3.6）：开关/音量/语言 → Game.set_setting(key, value)；
#            重置存档 → 二次确认后 Game.reset_save()；返回 → 切回 Main.tscn
#          - 只读入口：Game.get_settings()；存档导出 = JSON.stringify(Game.get_save_snapshot())
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 防循环 ：刷新控件用 set_pressed_no_signal / set_value_no_signal + _refreshing 标志，
#          避免"控件信号 → set_setting → settings_changed → 重建控件 → 信号"循环。
# 二次确认：重置按钮 → ConfirmationDialog → confirmed 才调 Game.reset_save()。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Settings.tscn 结构一一对应）----
@onready var _music_on: CheckButton = $root_box/music_row/music_on
@onready var _music_volume: HSlider = $root_box/music_row/music_volume
@onready var _sfx_on: CheckButton = $root_box/sfx_row/sfx_on
@onready var _sfx_volume: HSlider = $root_box/sfx_row/sfx_volume
@onready var _default_2x: CheckButton = $root_box/default_2x_row/default_2x
@onready var _language: OptionButton = $root_box/language_row/language
@onready var _export_text: TextEdit = $root_box/export_text
@onready var _message_label: Label = $root_box/message_label
@onready var _reset_button: Button = $root_box/reset_button
@onready var _confirm_dialog: ConfirmationDialog = $confirm_dialog
@onready var _back_button: Button = $root_box/back_button

## 刷新防循环标志
var _refreshing := false


func _ready() -> void:
	Contract.settings_changed.connect(_on_settings_changed)
	_music_on.toggled.connect(_on_bool_setting.bind(&"music_on"))
	_sfx_on.toggled.connect(_on_bool_setting.bind(&"sfx_on"))
	_default_2x.toggled.connect(_on_bool_setting.bind(&"default_2x"))
	_music_volume.value_changed.connect(_on_volume_setting.bind(&"music_volume"))
	_sfx_volume.value_changed.connect(_on_volume_setting.bind(&"sfx_volume"))
	_language.item_selected.connect(_on_language_selected)
	_reset_button.pressed.connect(_on_reset_pressed)
	_confirm_dialog.confirmed.connect(_on_reset_confirmed)
	_back_button.pressed.connect(_on_back_pressed)
	# 语言下拉：仅中文（Data.SETTINGS_LANGUAGES）
	_language.clear()
	for lang in Data.SETTINGS_LANGUAGES:
		_language.add_item(str(lang))
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）
	_refresh_all()


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_settings_changed(_settings: Dictionary) -> void:
	_refresh_all()


## ------------------------------------------------------------------
## 控件 → Game 入口（契约 §3.6）
## ------------------------------------------------------------------
func _on_bool_setting(on: bool, key: StringName) -> void:
	if _refreshing:
		return
	Game.set_setting(key, on)


func _on_volume_setting(value: float, key: StringName) -> void:
	if _refreshing:
		return
	Game.set_setting(key, value)


func _on_language_selected(_index: int) -> void:
	if _refreshing:
		return
	Game.set_setting(&"language", "zh")


func _on_reset_pressed() -> void:
	# 二次确认：弹窗后 confirmed 才重置
	_confirm_dialog.dialog_text = "确定重置存档？所有进度将清空并重新开始！"
	_confirm_dialog.popup_centered()


func _on_reset_confirmed() -> void:
	Game.reset_save()  # 重置后重发初始信号（含 settings_changed）→ 界面自动刷新
	_message_label.text = "存档已重置"


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 刷新（读 Game.get_settings() 只读；无信号循环）
## ------------------------------------------------------------------
func _refresh_all() -> void:
	_refreshing = true
	var s: Dictionary = Game.get_settings()
	_music_on.set_pressed_no_signal(bool(s.get("music_on", true)))
	_sfx_on.set_pressed_no_signal(bool(s.get("sfx_on", true)))
	_default_2x.set_pressed_no_signal(bool(s.get("default_2x", false)))
	_music_volume.set_value_no_signal(float(s.get("music_volume", 0.8)))
	_sfx_volume.set_value_no_signal(float(s.get("sfx_volume", 0.8)))
	_language.select(0)
	_refreshing = false
	# 存档导出：显示只读 JSON 文本（UI JSON.stringify 展示，不修改数值）
	_export_text.text = JSON.stringify(Game.get_save_snapshot(), "\t")
