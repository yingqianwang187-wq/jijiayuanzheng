# ==================================================================
# scripts/bag_ui.gd —— 背包界面脚本（挂在 scenes/Bag.tscn 根节点）
# 作者   ：C（画面 + 界面）
# 依据   ：docs/契约.md §3.1 / §3.5 / §3.6 / §3.10（v0.13）、scripts/contract.gd（只读）
# 职责   ：背包界面的纯显示层 + 扩容入口。
#          - 连接信号：bag_updated（道具增减 / 扩容后刷新）
#          - 按钮只调入口（契约 §3.6）：扩容 → Game.expand_bag()；返回 → 切回 Main.tscn
#          - 只读入口：Game.get_bag()（{items, capacity}）、Game.expand_bag_cost()
# 铁律   ：（契约 §3.1 红线）本文件无任何数值赋值（gold= / hp= 等）、无 emit、
#          一切更新值以 Game 信号参数为准，UI 不缓存游戏数值。
# 列表   ：Data.ITEMS 提供道具名；库存/容量/扩容费用展示，道具使用后续批次（契约 §3.10）。
# ==================================================================
extends Control

## ---- 节点引用（与 scenes/Bag.tscn 结构一一对应）----
@onready var _capacity_label: Label = $root_box/capacity_label
@onready var _item_box: VBoxContainer = $root_box/item_box
@onready var _expand_button: Button = $root_box/expand_button
@onready var _message_label: Label = $root_box/message_label
@onready var _back_button: Button = $root_box/back_button


func _ready() -> void:
	Contract.bag_updated.connect(_on_bag_updated)
	_expand_button.pressed.connect(_on_expand_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# 首屏只读快照（契约 §3.1"首屏铺底例外"）
	_render_bag(Game.get_bag())


## ------------------------------------------------------------------
## 信号处理（只刷新显示）
## ------------------------------------------------------------------
func _on_bag_updated(items: Dictionary, capacity: int) -> void:
	_render_bag({ "items": items, "capacity": capacity })
	_message_label.text = "背包已更新"


## ------------------------------------------------------------------
## 按钮（只调契约 §3.6 入口）
## ------------------------------------------------------------------
func _on_expand_pressed() -> void:
	Game.expand_bag()  # 结果由 bag_updated / gold_changed 信号回发


func _on_back_pressed() -> void:
	queue_free()  # 4U 覆盖层：关闭回到原页


## ------------------------------------------------------------------
## 渲染（items / capacity 来自只读入口或信号参数）
## ------------------------------------------------------------------
func _render_bag(data: Dictionary) -> void:
	var items: Dictionary = data.get("items", {})
	var capacity: int = int(data.get("capacity", 0))
	_capacity_label.text = "容量：%d/%d" % [items.size(), capacity]
	# 扩容按钮：显示费用；满上限禁用
	var cost: int = Game.expand_bag_cost()
	if cost <= 0:
		_expand_button.text = "已满（%d 格）" % Data.BAG_MAX_CAPACITY
		_expand_button.disabled = true
	else:
		_expand_button.text = "扩容（%d 金币）" % cost
		_expand_button.disabled = false
	# 道具列表
	for child in _item_box.get_children():
		_item_box.remove_child(child)
		child.queue_free()
	if items.is_empty():
		var empty := Label.new()
		empty.text = "背包空空如也"
		_item_box.add_child(empty)
		return
	for item_id in items:
		var cfg: Dictionary = Data.ITEMS.get(item_id, {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_label := Label.new()
		name_label.text = str(cfg.get("name", str(item_id)))
		name_label.custom_minimum_size = Vector2(200, 0)
		var count_label := Label.new()
		count_label.text = "× %d" % int(items[item_id])
		row.add_child(name_label)
		row.add_child(count_label)
		_item_box.add_child(row)
