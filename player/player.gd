extends CharacterBody3D

@onready var helpers = get_node("/root/Helpers")

@onready var arc_laser_scene = preload("res://projectiles/arc_laser/arc_laser.tscn")
@onready var laser_scene = preload("res://projectiles/laser/laser.tscn")

@onready var mesh_anchor = $mesh_anchor
@onready var mesh = $mesh_anchor/mesh
@onready var camera_anchor = $camera_anchor
@onready var boost_timer = $boost_timer
@onready var yaw_roll_timer = $yaw_roll_timer
@onready var camera = $camera_anchor/camera
@onready var targeting_ray = $camera_anchor/camera/targeting_ray
@onready var target_selection_ray = $camera_anchor/camera/target_selection_ray
@onready var laser_mount = $mesh_anchor/mesh/laser_mount
@onready var laser_mount2 = $mesh_anchor/mesh/laser_mount2
@onready var laser_timer = $laser_timer
@onready var weapon_lock_timer = $weapon_lock_timer

@onready var ship = preload("res://ships/hummingbird.tres")

@export var invert_pitch: bool = false
@export var sensitivity: float = 6

var CROSSHAIR_SENSITIVITY = sensitivity * 100
var rotation_input = Vector2.ZERO
var rotation_speed = Vector3.ZERO
var roll_input = 0

var crosshair_position = Vector2.ZERO

var camera_trauma_noise
var camera_trauma_noise_pos = Vector2(randi_range(1, 100), 1)
var camera_trauma = 0

var has_boost = true
var boost_impulse = Vector3.ZERO

var weapons_target
var weapon_alternator = 0
var target = null
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

var hull = 0

func _ready():
    crosshair_position = get_viewport().get_visible_rect().size / 2

    camera_trauma_noise = FastNoiseLite.new()
    camera_trauma_noise.set_noise_type(FastNoiseLite.TYPE_SIMPLEX)
    camera_trauma_noise.seed = randi()
    camera_trauma_noise.frequency = 2.0

    collision_radius = $avoidance_sphere.shape.radius
    targeting_ray.add_exception(self)
    target_selection_ray.add_exception(self)
    laser_timer.timeout.connect(laser_timer_timeout)
    weapon_lock_timer.timeout.connect(lock_target)

    hull = ship.HULL_STRENGTH

func _input(event):
    if event is InputEventMouseButton:
        if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
            Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        roll_input = 0
        if Input.is_action_pressed("yaw_roll"):
            roll_input = clamp(-event.relative.x, -1, 1)
        else:
            crosshair_position += event.relative

func _physics_process(delta):
    # misc inputs
    if Input.is_action_just_pressed("escape"):
        if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

    if not visible:
        return

    if Input.is_action_just_pressed("boost") and has_boost:
        boost()
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

    # handle joystick cursor input
    if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:  
        roll_input = 0
        if Input.is_action_pressed("yaw_roll"):
            roll_input = Input.get_action_strength("yaw_left") - Input.get_action_strength("yaw_right")
        else:
            rotation_input.x = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
            rotation_input.y = Input.get_action_strength("pitch_up") - Input.get_action_strength("pitch_down")

    # update navigator based on input
    if invert_pitch:
        rotation_input.y = -rotation_input.y
    crosshair_position += rotation_input * CROSSHAIR_SENSITIVITY * delta
    crosshair_position.x = clamp(crosshair_position.x, 0, get_viewport().get_visible_rect().size.x)
    crosshair_position.y = clamp(crosshair_position.y, 0, get_viewport().get_visible_rect().size.y)
    var crosshair_value = (crosshair_position - (get_viewport().get_visible_rect().size / 2)) / (get_viewport().get_visible_rect().size / 2)

    # slowly return navigator to screen center
    if (crosshair_position - (get_viewport().get_visible_rect().size / 2)).length() <= 2:
        crosshair_position = get_viewport().get_visible_rect().size / 2
    else:
        crosshair_position += -crosshair_value * 8

    # lookat style rotation towards target
    var rotation_lookat_target = camera.project_position(crosshair_position, 500)
    var bank_angle = (PI / 2) * -crosshair_value.x
    mesh.rotation.z = bank_angle
    var rotation_target_transform = mesh_anchor.transform.looking_at(rotation_lookat_target, mesh_anchor.transform.basis.y)
    var speed_percent = velocity.length() / ship.MAX_THROTTLE_VELOCITY
    if not (crosshair_position == get_viewport().get_visible_rect().size / 2 and abs(rad_to_deg((-mesh_anchor.transform.basis.z).signed_angle_to(rotation_lookat_target, mesh_anchor.transform.basis.y))) <= 2):
        mesh_anchor.transform = mesh_anchor.transform.interpolate_with(rotation_target_transform, (1 + (speed_percent * 3)) * delta)

    # physics-based rotation (for stuff like collisions)
    for i in range(0, 3):
        if rotation_speed[i] > 0:
            rotation_speed[i] = max(rotation_speed[i] - 0.02, 0)
        elif rotation_speed[i] < 0:
            rotation_speed[i] = min(rotation_speed[i] + 0.02, 0)
    var roll_speed = 1.5
    if roll_input > 0 and rotation_speed.x < roll_input * roll_speed:
        rotation_speed.x = roll_input * roll_speed
    elif roll_input < 0 and rotation_speed.x > roll_input * roll_speed:
        rotation_speed.x = roll_input * roll_speed
    mesh_anchor.transform.basis = mesh_anchor.transform.basis.rotated(mesh_anchor.transform.basis.z, (rotation_speed.x) * delta)
    mesh_anchor.transform.basis = mesh_anchor.transform.basis.rotated(mesh_anchor.transform.basis.x, rotation_speed.y * delta)
    mesh_anchor.transform.basis = mesh_anchor.transform.basis.rotated(mesh_anchor.transform.basis.y, rotation_speed.z * delta)
    mesh_anchor.transform.basis = mesh_anchor.transform.basis.orthonormalized()

    # update camera
    var camera_follow_speed_percent = 1
    if rotation_speed.length() > ship.MAX_ROTATION_SPEED.length():
        camera_follow_speed_percent = 1 - min((rotation_speed.length() - ship.MAX_ROTATION_SPEED.length()) / ship.MAX_ROTATION_SPEED.length(), 1)
    var camera_speed_mod = 1.5
    camera_anchor.transform = camera_anchor.transform.interpolate_with(mesh_anchor.transform, delta * camera_follow_speed_percent * camera_speed_mod)
    var desired_camera_position = camera.position 
    if not Input.is_action_pressed("yaw_roll"):
        desired_camera_position.x = crosshair_value.x * 3
        if crosshair_value.y > 0:
            desired_camera_position.y = 2 + (crosshair_value.y * 0.1)
        else:
            desired_camera_position.y = 2 - (crosshair_value.y * 0.75)
    camera.position = camera.position.lerp(desired_camera_position, delta)
    
    # camera shake
    var camera_shake_amount = camera_trauma * max(1, velocity.length() * 0.3)
    camera_anchor.transform.basis = camera_anchor.transform.basis.rotated(camera_anchor.transform.basis.z, 0.005 * camera_shake_amount * camera_trauma_noise.get_noise_2d(camera_trauma_noise_pos.x, camera_trauma_noise_pos.y))
    camera.position.x += 0.01 * camera_shake_amount * camera_trauma_noise.get_noise_2d(camera_trauma_noise_pos.x * 2, camera_trauma_noise_pos.y)
    camera.position.y += 0.01 * camera_shake_amount * camera_trauma_noise.get_noise_2d(camera_trauma_noise_pos.x * 3, camera_trauma_noise_pos.y)
    camera_trauma_noise_pos.y += 1
    camera_trauma = max(camera_trauma - 0.1, 0)

    # Check thrust inputs
    var thrust_input = Vector3.ZERO
    if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
        thrust_input.y = Input.get_action_strength("thrust_up") - Input.get_action_strength("thrust_down")
        thrust_input.x = Input.get_action_strength("thrust_right") - Input.get_action_strength("thrust_left")
        thrust_input.z = -(Input.get_action_strength("thrust_forwards") - Input.get_action_strength("thrust_backwards"))
    else:
        if Input.is_action_pressed("button_thrust_up"):
            thrust_input.y += 1
        if Input.is_action_pressed("button_thrust_down"):
            thrust_input.y -= 1
        if Input.is_action_pressed("button_thrust_right"):
            thrust_input.x += 1
        if Input.is_action_pressed("button_thrust_left"):
            thrust_input.x -= 1
        if Input.is_action_pressed("button_thrust_forwards"):
            thrust_input.z -= 1
        if Input.is_action_pressed("button_thrust_backwards"):
            thrust_input.z += 1

    # determine the max velocity in the zbasis direction
    var max_zbasis_velocity = ship.MAX_THROTTLE_VELOCITY
    # if going backwards, zbasis direction has less maximum strength
    if thrust_input.z > 0:
        max_zbasis_velocity = ship.MAX_THRUST_VELOCITY
    # if using lateral or vertical thrusters, zbasis direction has less maximum strength
    max_zbasis_velocity = sqrt(pow(max_zbasis_velocity, 2) - pow(ship.MAX_THRUST_VELOCITY * abs(thrust_input[0]), 2) - pow(ship.MAX_THRUST_VELOCITY * abs(thrust_input[1]), 2))

    # decceleration
    var thrust_basis = mesh_anchor.transform.basis.rotated(mesh_anchor.transform.basis.z, bank_angle)
    if thrust_input != Vector3.ZERO:
        for i in range(0, 3):
            var basis_velocity = helpers.vector_component_in_vector_direction(velocity, thrust_basis[i])
            var max_basis_velocity = ship.MAX_THRUST_VELOCITY
            if i == 2:
                max_basis_velocity = max_zbasis_velocity
            var positive_basis = thrust_basis[i]
            if (basis_velocity.normalized().is_equal_approx(-positive_basis) and (not thrust_input[i] < 0) or (thrust_input[i] < 0 and basis_velocity.length() > max_basis_velocity)) \
                or (basis_velocity.normalized().is_equal_approx(positive_basis) and (not thrust_input[i] > 0) or (thrust_input[i] > 0 and basis_velocity.length() > max_basis_velocity)):
                    var decel_strength = min(ship.DECELERATION * delta, basis_velocity.length())
                    velocity += -basis_velocity * decel_strength

    # thrust acceleration
    for i in range(0, 3):
        var acceleration_direction = thrust_basis[i] * thrust_input[i]
        var acceleration_strength = ship.ACCELERATION * delta

        var basis_velocity = helpers.vector_component_in_vector_direction(velocity, thrust_basis[i])
        var max_basis_velocity = ship.MAX_THRUST_VELOCITY
        if i == 2:
            max_basis_velocity = max_zbasis_velocity

        if acceleration_direction.is_equal_approx(basis_velocity.normalized()) and acceleration_strength > max_basis_velocity - basis_velocity.length():
            acceleration_strength = max_basis_velocity - basis_velocity.length()
        if acceleration_strength > 0:
            velocity += acceleration_direction * acceleration_strength

    # boost impulse doesn't care about basis velocity limits
    if boost_impulse != Vector3.ZERO:
        velocity += boost_impulse * delta

    # limit velocity
    velocity = velocity.limit_length(ship.TERMINAL_VELOCITY)

    # move and handle collisions
    var collision = move_and_collide(velocity * delta)
    if collision:
        velocity += collision.get_normal() * velocity.length() * ship.COLLISION_IMPULSE_MODIFIER * delta
        rotation_speed.x = -collision.get_normal().signed_angle_to(velocity, mesh_anchor.transform.basis.x)
        rotation_speed.y = -collision.get_normal().signed_angle_to(velocity, mesh_anchor.transform.basis.z) 
        rotation_speed.z = -collision.get_normal().signed_angle_to(velocity, mesh_anchor.transform.basis.y) 
        rotation_speed *= velocity.length() * ship.COLLISION_ROTATION_MODIFIER
        camera_trauma = max(10.0 * (velocity.length() / ship.MAX_THROTTLE_VELOCITY), camera_trauma)

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
            var direction_xbasis = helpers.vector_component_in_vector_direction(position.direction_to(target.position), mesh_anchor.transform.basis.x)
            var direction_ybasis = helpers.vector_component_in_vector_direction(position.direction_to(target.position), mesh_anchor.transform.basis.y)
            var screen_direction = Vector2(direction_xbasis.length(), direction_ybasis.length())
            if direction_xbasis.normalized().is_equal_approx(-mesh_anchor.transform.basis.x):
                screen_direction.x *= -1
            if direction_ybasis.normalized().is_equal_approx(-mesh_anchor.transform.basis.y):
                screen_direction.y *= -1
            target_follow_angle = rad_to_deg(screen_direction.angle())

    weapons_target = rotation_lookat_target
    if target_reticle_position != null and position.distance_to(target.position) >= weapon_range_min[current_weapon] and position.distance_to(target.position) <= weapon_range_max[current_weapon] and crosshair_position.distance_to(target_reticle_position) <= weapon_max_aim_distance[current_weapon]:
        if weapon_lock_duration[current_weapon] == 0:
            weapon_has_lock = true
        if weapon_has_lock: 
            pass
            # weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 50))
        elif weapon_lock_timer.is_stopped():
            weapon_lock_timer.start(weapon_lock_duration[current_weapon])
    else:
        weapon_has_lock = false
        weapon_lock_timer.stop()
    targeting_ray.look_at(weapons_target)
    targeting_ray.force_raycast_update()
    if targeting_ray.is_colliding():
        weapons_target = targeting_ray.get_collision_point()

func boost():
    has_boost = false
    var tween = get_tree().create_tween()
    tween.tween_property(self, "velocity", -mesh_anchor.transform.basis.z * velocity.length(), 0.3)
    await tween.finished
    var camera_tween = get_tree().create_tween()
    camera_tween.tween_property(camera, "fov", 115, 0.2)
    await camera_tween.finished
    boost_impulse = -mesh_anchor.transform.basis.z * ship.BOOST_IMPULSE_STRENGTH
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
        # bullet.position = laser_mount.global_position - mesh_anchor.transform.basis.z
        bullet.position = position - mesh_anchor.transform.basis.z
        weapon_alternator = 1
    else:
        bullet.position = position - mesh_anchor.transform.basis.z
        # bullet.position = laser_mount2.global_position - mesh_anchor.transform.basis.z
        weapon_alternator = 0
    bullet.add_collision_exception_with(self)
    bullet.aim(weapons_target)
    laser_timer.start(0.1)
    camera_trauma = max(1.0, camera_trauma)

func shoot_missile():
    is_shooting = true
    for i in range(0, 2):
        var bullet = arc_laser_scene.instantiate()
        get_parent().add_child(bullet)
        var skew = mesh_anchor.transform.basis.x
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

func handle_bullet(damage):
    hull -= damage
    if hull <= 0:
        visible = false
    camera_trauma = max(2.0, camera_trauma)
