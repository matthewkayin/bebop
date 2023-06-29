extends Control

@onready var velocity_label = $velocity_label
@onready var crosshair = $crosshair
@onready var crosshair_arrow = $crosshair/crosshair_arrow

var player = null

func _process(_delta):
    if player == null:
        player = get_parent().get_node_or_null("ship")
        if player == null:
            return
    
    velocity_label.text = ""
    while player.debug_display.size() != 0:
        velocity_label.text += player.debug_display[0] + "\n"
        player.debug_display.pop_front()

    crosshair.position = player.camera.unproject_position(player.weapons_target) 
    if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        crosshair_arrow.visible = player.rotation_input.length() > 0.01
        crosshair_arrow.position = Vector2(player.rotation_input.x, -player.rotation_input.y) * 128
        crosshair_arrow.rotation = crosshair_arrow.position.angle() + (PI / 2)
    else: 
        crosshair_arrow.visible = false
