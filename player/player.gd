extends CharacterBody3D

@onready var helpers = get_node("/root/Helpers")

@onready var arc_laser_scene = preload("res://projectiles/arc_laser/arc_laser.tscn")
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
@onready var weapon_lock_timer = $weapon_lock_timer

@onready var ship = preload("res://ships/hummingbird.tres")

const CROSSHAIR_SENSITIVITY = 300
var rotation_input = Vector2.ZERO
var roll_input = 0
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
var is_shooting = false
var weapon_has_lock = false
var current_weapon = 0
var weapon_range_min = [5, 10]
var weapon_range_max = [30, 40]
var weapon_max_aim_distance = [128, 32]
var weapon_lock_duration = [0, 3]

var collision_radius = 0

var shields_online = true
var hull = 0
var shields = 0

func _ready():
    add_to_group("obstacles")

    crosshair_position = get_viewport().get_visible_rect().size / 2

    collision_radius = $avoidance_sphere.shape.radius
    targeting_ray.add_exception(self)
    target_selection_ray.add_exception(self)
    laser_timer.timeout.connect(laser_timer_timeout)
    weapon_lock_timer.timeout.connect(lock_target)

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
        rotation_input.x = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
        rotation_input.y = Input.get_action_strength("pitch_up") - Input.get_action_strength("pitch_down")
        roll_input = Input.get_action_strength("roll_left") - Input.get_action_strength("roll_right")

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
    if Input.is_action_just_pressed("shoot"):
        on_initial_shoot()
    if Input.is_action_just_pressed("swap_weapons"):
        laser_timer.stop()
        weapon_lock_timer.stop()
        current_weapon = (current_weapon + 1) % 2
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

    crosshair_position += rotation_input * CROSSHAIR_SENSITIVITY * delta
    crosshair_position.x = clamp(crosshair_position.x, 0, get_viewport().get_visible_rect().size.x)
    crosshair_position.y = clamp(crosshair_position.y, 0, get_viewport().get_visible_rect().size.y)

    var crosshair_value = (crosshair_position - (get_viewport().get_visible_rect().size / 2)) / (get_viewport().get_visible_rect().size / 2)
    var camera_speed = Vector2.ZERO
    if crosshair_value.length() > 0.1:
        camera_speed = crosshair_value * -1
    camera_anchor.transform.basis = camera_anchor.transform.basis.rotated(camera_anchor.transform.basis.z, roll_input * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(camera_anchor.transform.basis.z, roll_input * delta)
    camera_anchor.transform.basis = camera_anchor.transform.basis.rotated(camera_anchor.transform.basis.x, camera_speed.y * delta)
    camera_anchor.transform.basis = camera_anchor.transform.basis.rotated(camera_anchor.transform.basis.y, camera_speed.x * delta)
    # slowly return crosshair to screen center
    crosshair_position += camera_speed * 2
    camera.position.x = lerp(camera.position.x, crosshair_value.x * 4, delta)
    if crosshair_value.y > 0:
        camera.position.y = lerp(camera.position.y, 2 + (crosshair_value.y * 0.25), delta)
    else:
        camera.position.y = lerp(camera.position.y, 2 - (crosshair_value.y * 1), delta)

    var rotation_lookat_target = camera.project_position(crosshair_position, 500)
    var flipped = 1
    if crosshair_value.y > 0.5:
        flipped = -1
    mesh.transform = mesh.transform.interpolate_with(mesh.transform.looking_at(rotation_lookat_target, (flipped * camera_anchor.transform.basis.y).rotated(camera_anchor.transform.basis.x, (PI / 2) * flipped * abs(crosshair_value.x))), 0.5 * delta)

    # Check thrust inputs
    var thrust_input = Vector3.ZERO
    thrust_input.y = Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down")
    thrust_input.x = Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left")
    thrust_input.z = Input.get_action_strength("thrust_forwards") - Input.get_action_strength("thrust_backwards")
    var throttle_input = Input.get_action_strength("throttle_up") - Input.get_action_strength("throttle_down")
    if drifting:
        thrust_input.z += -throttle_input
    else:
        throttle = clamp(throttle + (throttle_input * 0.01), 0, 1)

    # decceleration
    if not drifting:
        for i in range(0, 3):
            var basis_velocity = helpers.vector_component_in_vector_direction(velocity, mesh.transform.basis[i])
            var positive_basis = mesh.transform.basis[i]
            if i == 2:
                positive_basis *= -1
            if (basis_velocity.normalized().is_equal_approx(-positive_basis) and not thrust_input[i] < 0) or (basis_velocity.normalized().is_equal_approx(positive_basis) and not (thrust_input[i] > 0 or (i == 2 and throttle > 0))):
                var decel_strength = min(ship.ACCELERATION * delta, basis_velocity.length())
                velocity += -basis_velocity * decel_strength
    # thrust acceleration
    for i in range(0, 3):
        velocity += mesh.transform.basis[i] * thrust_input[i] * ship.ACCELERATION * delta
    # throttle acceleration
    if not drifting and throttle != 0:
        var forward_velocity = helpers.vector_component_in_vector_direction(velocity, mesh.transform.basis.z)
        var desired_forward_velocity = ship.MAX_THROTTLE_VELOCITY * throttle
        # if flying backwards, accelerate
        if forward_velocity.normalized().is_equal_approx(mesh.transform.basis.z):
            velocity += -mesh.transform.basis.z * ship.ACCELERATION * delta
        # if slower than desired velocity, accelerate
        elif forward_velocity.length() < desired_forward_velocity:
            var accel_strength = min(ship.ACCELERATION * delta, desired_forward_velocity - forward_velocity.length())
            velocity += -mesh.transform.basis.z * accel_strength
        # if faster than desired velocity, decelerate
        elif forward_velocity.length() > desired_forward_velocity:
            var decel_strength = min(ship.ACCELERATION * delta, forward_velocity.length() - desired_forward_velocity)
            velocity += mesh.transform.basis.z * decel_strength

    # limit velocities
    for i in range(0, 3):
        var basis_velocity = helpers.vector_component_in_vector_direction(velocity, mesh.transform.basis[i])
        var max_basis_velocity = ship.MAX_THRUST_VELOCITY
        if i == 2:
            max_basis_velocity = ship.MAX_THROTTLE_VELOCITY
        if basis_velocity.length() > max_basis_velocity:
            velocity += -basis_velocity * (basis_velocity.length() - max_basis_velocity)
    velocity = velocity.limit_length(ship.MAX_THROTTLE_VELOCITY)

    # boost impulse doesn't care about basis velocity limits
    if boost_impulse != Vector3.ZERO:
        velocity += boost_impulse * delta

    # limit overall velocity
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
    if target_reticle_position != null and position.distance_to(target.position) >= weapon_range_min[current_weapon] and position.distance_to(target.position) <= weapon_range_max[current_weapon] and crosshair_position.distance_to(target_reticle_position) <= weapon_max_aim_distance[current_weapon]:
        if weapon_has_lock or weapon_lock_duration[current_weapon] == 0:
            weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 50))
        elif weapon_lock_timer.is_stopped():
            weapon_lock_timer.start(weapon_lock_duration[current_weapon])
    else:
        weapon_has_lock = false
        weapon_lock_timer.stop()
    targeting_ray.look_at(weapons_target)
    targeting_ray.force_raycast_update()
    if targeting_ray.is_colliding():
        weapons_target = targeting_ray.get_collision_point()
    
    # crosshair_position = camera.unproject_position(weapons_target)

    # update shields
    if shield_timer.is_stopped():
        var shield_recharge_rate = ship.SHIELD_RECHARGE_RATE
        if not shields_online:
            shield_recharge_rate *= 2
        shields = min(ship.SHIELD_STRENGTH, shields + (shield_recharge_rate * delta))
        if not shields_online and shields == ship.SHIELD_STRENGTH:
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
        shoot_laser()

func lock_target():
    weapon_has_lock = true

func on_initial_shoot():
    if current_weapon == 0:
        if laser_timer.is_stopped():
            shoot_laser()
    elif current_weapon == 1:
        if not is_shooting:
            shoot_missile()

func shoot_laser():
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

func shoot_missile():
    is_shooting = true
    for i in range(0, 2):
        var bullet = arc_laser_scene.instantiate()
        get_parent().add_child(bullet)
        var skew = mesh.transform.basis.x
        if weapon_alternator == 0:
            bullet.position = laser_mount.global_position
            weapon_alternator = 1
        else:
            skew *= -1
            bullet.position = laser_mount2.global_position
            weapon_alternator = 0
        bullet.add_collision_exception_with(self)
        var bullet_target = null
        if weapon_has_lock:
            bullet_target = target
        bullet.aim(bullet_target, weapons_target, skew)
    is_shooting = false

func handle_bullet(energy_damage, physical_damage):
    if shields_online:
        shields -= energy_damage
        if shields <= 0:
            shields_online = false
            shield_timer.start(5)
    else:
        hull -= physical_damage
    if hull <= 0:
        visible = false
