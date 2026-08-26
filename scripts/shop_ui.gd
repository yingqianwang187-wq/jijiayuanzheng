# ==================================================================
# scripts/shop_ui.gd —— 商城界面脚本（挂在 scenes/Shop.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.12（v0.15）、scripts/contract.gd（只读）
# 职责   ：商城界面的纯显示层 + 购买入口。
#          - 连接信号：shop_changed / diamond_changed / gold_changed（货币显示）
#          - 按钮只调入口（契约 §3.6）：购买 → Game.buy_shop_item(item_id)；返回 → 切回 Main.tscn
#          - 只读入口：Game.get_shop_items()（{items, bought}）
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / diamond= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 列表   ：Data.SHOP_ITEMS 驱动（每日 5 商品，0 点刷新、每商品每日限购 1 次）；
#          已购项置灰；描述由 reward（kind/amount）生成（纯显示）。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Shop.tscn 结构一一对应）----
@onready var _money_label: Label = $root_box/money_label
@onready var _item_box: VBoxContainer = $root_box/item_box
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.shop_changed.connect(_on_shop_changed)
	Contract.diamond_changed.connect(_on_money_changed)
	Contract.gold_changed.connect(_on_money_changed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）
	_refresh_money()
	var data: Dictionary = Game.get_shop_items()
	_render_items(data.get("items", []), data.get("bought", {}))


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_shop_changed(items: Array, bought: Dictionary) -> void:
	_render_items(items, bought)


func _on_money_changed(_value: int) -> void:
	_refresh_money()


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_buy_pressed(item_id: StringName) -> void:
	Game.buy_shop_item(item_id)  # 结果由 shop_changed / 对应货币信号回发


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


## ------------------------------------------------------------------
## 渲染
## ------------------------------------------------------------------
func _refresh_money() -> void:
	_money_label.text = "金币 %d | 钻石 %d" % [Game.gold, Game.diamond]


func _render_items(items: Array, bought: Dictionary) -> void:
	for child in _item_box.get_children():
		_item_box.remove_child(child)
		child.queue_free()
	for item in items:
		var id := StringName(str(item.get("id", &"")))
		var cfg: Dictionary = Data.SHOP_ITEMS.get(id, {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_label := Label.new()
		name_label.text = str(item.get("name", str(id)))
		name_label.custom_minimum_size = Vector2(100, 0)
		var desc_label := Label.new()
		desc_label.text = _item_desc(cfg)
		desc_label.custom_minimum_size = Vector2(230, 0)
		var cost_label := Label.new()
		cost_label.text = "%s %d" % [_cost_type_text(str(item.get("cost_type", "gold"))), int(item.get("cost", 0))]
		cost_label.custom_minimum_size = Vector2(90, 0)
		var buy_button := Button.new()
		if bought.has(str(id)):
			buy_button.text = "已购"
			buy_button.disabled = true
		else:
			buy_button.text = "购买"
			buy_button.pressed.connect(_on_buy_pressed.bind(id))
		row.add_child(name_label)
		row.add_child(desc_label)
		row.add_child(cost_label)
		row.add_child(buy_button)
		_item_box.add_child(row)


## 商品描述（由 Data.SHOP_ITEMS.reward 生成，纯显示）
func _item_desc(cfg: Dictionary) -> String:
	var reward: Dictionary = cfg.get("reward", {})
	var amount: int = int(reward.get("amount", 0))
	match str(reward.get("kind", "")):
		"gold": return "获得 %d 金币" % amount
		"stamina": return "恢复 %d 体力" % amount
		"equip": return "获得 %d 件随机装备" % amount
		"gem": return "获得 %d 颗随机宝石" % amount
		"fragment": return "获得 %d 机娘碎片" % amount
	return ""


func _cost_type_text(cost_type: String) -> String:
	if cost_type == "diamond":
		return "钻石"
	return "金币"
