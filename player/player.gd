extends CharacterBody3D

@onready var helpers = get_node("/root/Helpers")

@onready var laser_scene = preload("res://projectiles/laser/laser.tscn")

@onready var mesh = $mesh
@onready var camera_anchor = $camera_anchor
@onready var boost_timer = $boost_timer
@onready var yaw_roll_timer = $yaw_roll_timer
@onready var camera = $camera_anchor/camera
@onready var targeting_ray = $camera_anchor/camera/targeting_ray
@onready var target_selection_ray = $camera_anchor/camera/target_selection_ray
@onready var laser_mount = $mesh/laser_mount
@onready var laser_mount2 = $mesh/laser_mount2
@onready var laser_timer = $laser_timer
@onready var shield_timer = $shield_timer

@onready var ship = preload("res://ships/hummingbird.tres")

enum YawRoll {
    OFF,
    ON_INITIAL_ROLL,
    ON_LOW_ROLL
}

var rotation_type: YawRoll = YawRoll.ON_LOW_ROLL
var rotation_input = Vector3.ZERO
var rotation_speed = Vector3.ZERO

var throttle = 0

var has_boost = true
var boost_impulse = Vector3.ZERO
var drifting = false

var weapons_target
var weapon_alternator = 0
var target = null
var crosshair_position = Vector2.ZERO
var target_reticle_position = null
var target_follow_angle

var collision_radius = 0

var shields_online = true
var hull = 0
var shields = 0

func _ready():
    add_to_group("obstacles")

    collision_radius = $avoidance_sphere.shape.radius
    targeting_ray.add_exception(self)
    target_selection_ray.add_exception(self)
    laser_timer.timeout.connect(laser_timer_timeout)

    hull = ship.HULL_STRENGTH
    shields = ship.SHIELD_STRENGTH

func _input(event):
    if event is InputEventMouseButton:
        if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        rotation_input.y += event.relative.y * 0.01
        if Input.is_action_pressed("yaw_roll"):
            rotation_input.z += event.relative.x * 0.01
        else:
            var prev_rotation_input = rotation_input.x
            rotation_input.x += event.relative.x * 0.01
            if Vector2(prev_rotation_input, 0).normalized() != Vector2(rotation_input.x, 0).normalized():
                yaw_roll_timer.start(0.25)
    if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
        var prev_roll_input = rotation_input.x
        rotation_input.x = Input.get_action_strength("roll_left") - Input.get_action_strength("roll_right")
        rotation_input.y = Input.get_action_strength("pitch_up") - Input.get_action_strength("pitch_down")
        rotation_input.z = Input.get_action_strength("yaw_left") - Input.get_action_strength("yaw_right")

        if rotation_type == YawRoll.ON_INITIAL_ROLL and yaw_roll_timer.is_stopped() and prev_roll_input == 0 and rotation_input.x != 0:
            yaw_roll_timer.start(0.25)

func _physics_process(delta):
    if not visible:
        return
    # misc inputs
    if Input.is_action_just_pressed("escape"):
        if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
            rotation_input = Vector3.ZERO

    if Input.is_action_just_pressed("boost") and has_boost:
        boost()
    if Input.is_action_just_pressed("flight_assist"):
        drifting = not drifting
    if Input.is_action_pressed("shoot"):
        if laser_timer.is_stopped():
            shoot()
    if Input.is_action_just_pressed("target"):
        target = null
        for _target in get_tree().get_nodes_in_group("targets"):
            if target != null:
                break
            if camera.is_position_behind(_target.position):
                continue
            var target_screen_position = camera.unproject_position(_target.position)
            if (target_screen_position - crosshair_position).length() <= 30:
                target_selection_ray.look_at(_target.position)
                target_selection_ray.force_raycast_update()
                if target_selection_ray.is_colliding() and target_selection_ray.get_collider() == _target:
                    target = _target

    # Flight rotation
    for i in range(0, 3):
        if abs(rotation_input[i]) <= 0.01:
            rotation_input[i] = 0
            if i == 0:
                yaw_roll_timer.stop()

        if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            if rotation_input[i] > 0:
                rotation_input[i] -= 0.01
            elif rotation_input[i] < 0:
                rotation_input[i] += 0.01
            # Limit input
            rotation_input[i] = clamp(rotation_input[i], -3, 3)

    # flight assist rotation correction
    for i in range(0, 3):
        if rotation_speed[i] > 0:
            rotation_speed[i] -= 0.02
        elif rotation_speed[i] < 0:
            rotation_speed[i] += 0.02

    var roll = rotation_input.x
    var yaw = rotation_input.z
    if rotation_type == YawRoll.ON_INITIAL_ROLL and not yaw_roll_timer.is_stopped():
        yaw += roll
    elif rotation_type == YawRoll.ON_LOW_ROLL and abs(rotation_input.x) > 0.3:
        yaw += rotation_input.x

    var rotation_acceleration = Vector3(roll, rotation_input.y, yaw)
    var speed_percent = 1 - abs((velocity.length() / ship.TERMINAL_VELOCITY) - 0.45)
    if boost_impulse != Vector3.ZERO or drifting:
        speed_percent = 1
    for i in range(0, 3):
        if rotation_acceleration[i] > 0 and rotation_speed[i] < speed_percent * ship.MAX_ROTATION_SPEED[i]:
            rotation_speed[i] = min(rotation_speed[i] + rotation_acceleration[i], speed_percent * ship.MAX_ROTATION_SPEED[i])
        elif rotation_acceleration[i] < 0 and rotation_speed[i] > speed_percent * -ship.MAX_ROTATION_SPEED[i]:
            rotation_speed[i] = max(rotation_speed[i] + rotation_acceleration[i], speed_percent * -ship.MAX_ROTATION_SPEED[i])

    # Perform flight rotation
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.z, rotation_speed.x * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.x, rotation_speed.y * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.y, rotation_speed.z * delta)
    mesh.transform.basis = mesh.transform.basis.orthonormalized()

    # camera rotation
    var camera_follow_speed_percent = 1
    if rotation_speed.length() > ship.MAX_ROTATION_SPEED.length():
        camera_follow_speed_percent = 1 - min((rotation_speed.length() - ship.MAX_ROTATION_SPEED.length()) / ship.MAX_ROTATION_SPEED.length(), 1)
    var camera_speed_mod = 1.5 + abs(rotation_speed.x * 0.5)
    camera_anchor.transform = camera_anchor.transform.interpolate_with(mesh.transform, delta * camera_follow_speed_percent * camera_speed_mod)

    # Check thrust inputs
    var thrust_input = Vector3.ZERO
    thrust_input.y = Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down")
    thrust_input.x = Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left")
    var z_input = Input.get_action_strength("thrust_forwards") - Input.get_action_strength("thrust_backwards")
    if drifting:
        thrust_input.z = -z_input
    else:
        throttle = clamp(throttle + (z_input * 0.01), 0, 1)

    # acceleration and decceleration
    var acceleration = Vector3.ZERO
    var decceleration = Vector3.ZERO
    for i in range(0, 3):
        acceleration += mesh.transform.basis[i] * thrust_input[i] * ship.ACCELERATION

    if not drifting:
        for i in range(0, 3):
            var velocity_component_in_basis_direction = helpers.vector_component_in_vector_direction(velocity, mesh.transform.basis[i])
            if not drifting and i == 2 and throttle != 0:
                if velocity_component_in_basis_direction.normalized() == mesh.transform.basis[i]:
                    acceleration += -mesh.transform.basis[i] * ship.ACCELERATION
                elif velocity_component_in_basis_direction.normalized() == -mesh.transform.basis[i] and velocity_component_in_basis_direction.length() > (ship.MAX_THROTTLE_VELOCITY * throttle) + 5:
                    decceleration += mesh.transform.basis[i] * ship.DECELERATION
                elif velocity_component_in_basis_direction.length() < ship.MAX_THROTTLE_VELOCITY * throttle:
                    acceleration += -mesh.transform.basis[i] * ship.ACCELERATION
            elif thrust_input[i] == 0 and velocity_component_in_basis_direction.length() >= ship.ACCELERATION * delta: 
                decceleration += -velocity_component_in_basis_direction.normalized() * ship.DECELERATION

    if boost_impulse != Vector3.ZERO:
        velocity += boost_impulse * delta
    else:
        velocity += (acceleration + decceleration) * delta

    # velocity
    velocity = velocity.limit_length(ship.TERMINAL_VELOCITY)
    if thrust_input == Vector3.ZERO and (throttle == 0 and not drifting) and velocity.length() <= 0.1:
        velocity = Vector3.ZERO

    # move and handle collisions
    var collision = move_and_collide(velocity * delta)
    if collision:
        velocity += collision.get_normal() * velocity.length() * ship.COLLISION_IMPULSE_MODIFIER * delta
        rotation_speed.x = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.x)
        rotation_speed.y = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.z) 
        rotation_speed.z = -collision.get_normal().signed_angle_to(velocity, mesh.transform.basis.y) 
        rotation_speed *= velocity.length() * ship.COLLISION_ROTATION_MODIFIER

    # set camera fov
    if boost_impulse == Vector3.ZERO:
        var desired_camera_fov = 75 + (32 * (velocity.length() / ship.TERMINAL_VELOCITY))
        camera.fov = lerp(camera.fov, desired_camera_fov, delta)

    # set weapons target
    target_reticle_position = null
    target_follow_angle = null
    if target != null: 
        if not camera.is_position_behind(target.position):
            target_reticle_position = camera.unproject_position(target.position)
            if not get_viewport().get_visible_rect().has_point(target_reticle_position):
                target_reticle_position = null
        if target_reticle_position == null:
            var direction_xbasis = helpers.vector_component_in_vector_direction(position.direction_to(target.position), mesh.transform.basis.x)
            var direction_ybasis = helpers.vector_component_in_vector_direction(position.direction_to(target.position), mesh.transform.basis.y)
            var screen_direction = Vector2(direction_xbasis.length(), direction_ybasis.length())
            if direction_xbasis.normalized().is_equal_approx(-mesh.transform.basis.x):
                screen_direction.x *= -1
            if direction_ybasis.normalized().is_equal_approx(-mesh.transform.basis.y):
                screen_direction.y *= -1
            target_follow_angle = rad_to_deg(screen_direction.angle())

    weapons_target = $mesh/target.to_global($mesh/target.position)
    # note: max range is handled by the ray length
    if target_reticle_position != null and position.distance_to(target.position) >= 5 and position.distance_to(target.position) <= 25 and rad_to_deg((-mesh.transform.basis.z).angle_to(position.direction_to(target.position))) <= 30:
        weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 50))
    targeting_ray.look_at(weapons_target)
    targeting_ray.force_raycast_update()
    if targeting_ray.is_colliding():
        weapons_target = targeting_ray.get_collision_point()
    
    crosshair_position = camera.unproject_position(weapons_target)

    # update shields
    if shield_timer.is_stopped():
        shields = min(ship.SHIELD_STRENGTH, shields + (ship.SHIELD_RECHARGE_RATE * delta))
        if not shields_online and shields >= int(ship.SHIELD_STRENGTH / 2.0):
            shields_online = true

func boost():
    has_boost = false
    var tween = get_tree().create_tween()
    tween.tween_property(self, "velocity", -mesh.transform.basis.z * velocity.length(), 0.3)
    await tween.finished
    var camera_tween = get_tree().create_tween()
    camera_tween.tween_property(camera, "fov", 115, 0.2)
    await camera_tween.finished
    boost_impulse = -mesh.transform.basis.z * ship.BOOST_IMPULSE_STRENGTH
    boost_timer.start(ship.BOOST_IMPULSE_DURATION)
    await boost_timer.timeout
    boost_impulse = Vector3.ZERO
    boost_timer.start(10)
    await boost_timer.timeout
    has_boost = true

func laser_timer_timeout():
    if Input.is_action_pressed("shoot"):
        shoot()

func shoot():
    var bullet = laser_scene.instantiate()
    get_parent().add_child(bullet)
    if weapon_alternator == 0:
        bullet.position = laser_mount.global_position
        weapon_alternator = 1
    else:
        bullet.position = laser_mount2.global_position
        weapon_alternator = 0
    bullet.add_collision_exception_with(self)
    bullet.aim(weapons_target)
    laser_timer.start(0.05)

func handle_bullet():
    if shields_online:
        shields -= 1
        if shields <= 0:
            shields_online = false
            shield_timer.start(5)
    else:
        hull -= 1
    if hull <= 0:
        visible = false
