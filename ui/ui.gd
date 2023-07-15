extends Control

@onready var health_label = $health_label
@onready var target_label = $target_label
@onready var throttle_label = $throttle_label
@onready var crosshair = $crosshair
@onready var target = $target
@onready var target_follow_arrow = $target_follow_arrow

@onready var target_texture = load("res://ui/target.png")
@onready var target_aquiring_texture = load("res://ui/target_aquiring.png")
@onready var target_locked_texture = load("res://ui/target_locked.png")

var player = null

func _process(_delta):
    if player == null:
        player = get_parent().get_node_or_null("player")
        if player == null:
            return

    if player.target_follow_angle == null:
        target_follow_arrow.visible = false
    else:
        target_follow_arrow.visible = true
        target_follow_arrow.rotation_degrees = 90 - player.target_follow_angle
        var target_follow_angle = player.target_follow_angle
        while target_follow_angle >= 360:
            target_follow_angle -= 360
        while target_follow_angle < 0:
            target_follow_angle += 360
        var quadrant = int(target_follow_angle / 90)
        var screen_rect = get_viewport().get_visible_rect()
        var screen_center = screen_rect.size / 2
        var point
        if target_follow_angle == 0:
            point = Vector2(screen_center.x, 0)
        elif target_follow_angle == 90:
            point = Vector2(0, -screen_center.y)
        elif target_follow_angle == 180:
            point = Vector2(-screen_center.x, 0)
        elif target_follow_angle == 270:
            point = Vector2(0, screen_center.y)
        else:
            var angle = target_follow_angle - (90 * quadrant)
            var x_dist
            var y_dist
            if quadrant == 0 or quadrant == 2:
                y_dist = screen_center.y / sin(deg_to_rad(angle))
                x_dist = screen_center.x / cos(deg_to_rad(angle))
                if y_dist <= x_dist:
                    point = Vector2(y_dist * cos(deg_to_rad(angle)), screen_center.y)
                else:
                    point = Vector2(screen_center.x, x_dist * sin(deg_to_rad(angle)))
            else:
                y_dist = screen_center.y / cos(deg_to_rad(angle))
                x_dist = screen_center.x / sin(deg_to_rad(angle))
                if y_dist <= x_dist:
                    point = Vector2(y_dist * sin(deg_to_rad(angle)), screen_center.y)
                else:
                    point = Vector2(screen_center.x, x_dist * cos(deg_to_rad(angle)))
            if quadrant == 0 or quadrant == 1:
                point.y *= -1
            if quadrant == 1 or quadrant == 2:
                point.x *= -1
        target_follow_arrow.position = screen_center + (point.normalized() * (point.length() - 22))

    throttle_label.text = ""
    throttle_label.text += "\n"
    if player.boost_impulse != Vector3.ZERO:
        throttle_label.text += "Boosting!\n"
    elif not player.boost_timer.is_stopped():
        throttle_label.text += "Charging...\n"
    else:
        throttle_label.text += "Boost Ready\n"
    throttle_label.text += "S: " + str(snapped(player.velocity.length(), 0.1)) + " / " + str(snapped(player.helpers.vector_component_in_vector_direction(player.velocity, -player.mesh.transform.basis.z).length(), 0.1))

    health_label.text = "Hull: " + str(player.hull) + "\n"

    if player.target == null:
        target_label.text = ""
    else:
        target_label.text = "Hull: " + str(player.target.hull) + "\n"

    crosshair.position = player.crosshair_position
    target.visible = false
    if player.target_reticle_position != null:
        target.visible = true
        target.position = player.target_reticle_position
        if player.weapon_has_lock:
            target.texture = target_locked_texture
        elif not player.weapon_lock_timer.is_stopped():
            target.texture = target_aquiring_texture
        else:
            target.texture = target_texture
