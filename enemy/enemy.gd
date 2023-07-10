extends CharacterBody3D

@onready var helpers = get_node("/root/Helpers")

@onready var mesh = $mesh
@onready var boost_timer = $boost_timer
@onready var laser_mount = $mesh/laser_mount
@onready var laser_mount2 = $mesh/laser_mount2
@onready var laser_timer = $laser_timer
@onready var targeting_ray = $mesh/targeting_ray
@onready var shield_timer = $shield_timer

@onready var laser_scene = preload("res://projectiles/laser/laser.tscn")

@onready var ship = preload("res://ships/hummingbird.tres")

var rotation_input = Vector3(0, 0, 0)
var rotation_speed = Vector3(0, 0, 0)

var throttle = 0
var thrust_input = Vector3.ZERO

var has_boost = true
var boost_impulse = Vector3.ZERO
var collision_impulse = Vector3.ZERO
var drifting = false

var weapons_target = null
var weapon_alternator = 0
var target = null
var number = 0

var collision_radius = 0

var shields_online = true
var hull = 0
var shields = 0

func _ready():
    add_to_group("obstacles")
    add_to_group("targets")
    collision_radius = $avoidance_sphere.shape.radius
    targeting_ray.add_exception(self)

    hull = ship.HULL_STRENGTH
    shields = ship.SHIELD_STRENGTH

func _physics_process(delta):
    if target == null:
        target = get_node_or_null("../player")

    # pathfinding
    throttle = 0
    rotation_input = Vector3.ZERO
    thrust_input = Vector3.ZERO

    if target != null:
        # set initial direction towards target
        var direction = position.direction_to(target.position + (target.velocity * 2))

        # obstacle avoidance
        var collision_eminent = false
        for obstacle in get_tree().get_nodes_in_group("obstacles"):
            if obstacle == self:
                continue
            # calculate avoidance radius 
            var relative_velocity = helpers.vector_component_in_vector_direction(velocity - obstacle.velocity, position.direction_to(obstacle.position))
            var stop_distance = ((relative_velocity.length() * relative_velocity.length()) / ship.ACCELERATION) + obstacle.collision_radius
            var collision_distance = position.distance_to(obstacle.position) - obstacle.collision_radius 
            if collision_distance <= stop_distance:
                # calculate and apply avoidance
                var collision_angle = rad_to_deg((-mesh.transform.basis.z).angle_to(position.direction_to(obstacle.position)))
                var avoidance_strength = ((1 - (collision_angle / 180)) * 0.5) + ((1 - (collision_distance / stop_distance)) * 0.5)
                # used further down in the code to cause the ship to hit the brakes if it's too close to a collision
                if collision_distance / stop_distance >= 0.75:
                    collision_eminent = true
                var avoidance = -position.direction_to(obstacle.position) * avoidance_strength * 2
                direction += avoidance
        direction = direction.normalized()

        # determine rotation inputs
        var direction_xbasis = helpers.vector_component_in_vector_direction(direction, mesh.transform.basis.x)
        var direction_ybasis = helpers.vector_component_in_vector_direction(direction, mesh.transform.basis.y)
        if direction_xbasis.length() > 0.3:
            if direction_xbasis.normalized() == mesh.transform.basis.x:
                rotation_input.x = -1
            elif direction_xbasis.normalized() == -mesh.transform.basis.x:
                rotation_input.x = 1
        if direction_xbasis.length() <= 0.3 and direction_xbasis.length() > 0.05:
            if direction_xbasis.normalized() == mesh.transform.basis.x:
                rotation_input.z = -1
            elif direction_xbasis.normalized() == -mesh.transform.basis.x:
                rotation_input.z = 1
        if direction_ybasis.length() > 0.2:
            if direction_ybasis.normalized() == mesh.transform.basis.y:
                rotation_input.y = 1
            elif direction_ybasis.normalized() == -mesh.transform.basis.y:
                rotation_input.y = -1
        if direction_xbasis.length() < 0.3 and rad_to_deg((-mesh.transform.basis.z).angle_to(position.direction_to(target.position))) > 45 and position.distance_to(target.position) <= 15:
            thrust_input.y = -rotation_input.y

        # determine throttle and thrust inputs
        if direction_xbasis.length() > 0.3 or direction_ybasis.length() > 0.3:
            throttle = 0.45
        else:
            var desired_vf = target.velocity.length()
            var desired_follow_distance = 15
            # var time_to_deccel = abs(desired_vf - velocity.length()) / ship.ACCELERATION
            # var distance_to_deccel = position.distance_to(target.position) - desired_follow_distance - (velocity.length() * time_to_deccel) - (0.5 * ship.ACCELERATION * (time_to_deccel * time_to_deccel))
            # if distance_to_deccel <= 0:
                # throttle = desired_vf / ship.MAX_THROTTLE_VELOCITY
            if position.distance_to(target.position) <= desired_follow_distance:
                throttle = desired_vf / ship.MAX_THROTTLE_VELOCITY
            else:
                throttle = 1

            if collision_eminent or (position.distance_to(target.position) <= desired_follow_distance and velocity.length() > desired_vf):
                thrust_input.z = 1

    # flight assist rotation correction
    if not drifting:
        for i in range(0, 3):
            if rotation_speed[i] > 0:
                rotation_speed[i] -= 0.02
            elif rotation_speed[i] < 0:
                rotation_speed[i] += 0.02

    var speed_percent = 1 - (abs((velocity.length() / ship.TERMINAL_VELOCITY) - 0.45) / 2.0)
    if boost_impulse != Vector3.ZERO or drifting:
        speed_percent = 1
    for i in range(0, 3):
        if rotation_input[i] > 0 and rotation_speed[i] < speed_percent * ship.MAX_ROTATION_SPEED[i]:
            rotation_speed[i] = min(rotation_speed[i] + rotation_input[i], speed_percent * ship.MAX_ROTATION_SPEED[i])
        elif rotation_input[i] < 0 and rotation_speed[i] > speed_percent * -ship.MAX_ROTATION_SPEED[i]:
            rotation_speed[i] = max(rotation_speed[i] + rotation_input[i], speed_percent * -ship.MAX_ROTATION_SPEED[i])

    # Perform flight rotation
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.z, rotation_speed.x * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.x, rotation_speed.y * delta)
    mesh.transform.basis = mesh.transform.basis.rotated(mesh.transform.basis.y, rotation_speed.z * delta)
    mesh.transform.basis = mesh.transform.basis.orthonormalized()
    $camera_anchor.transform = mesh.transform

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
    collision_impulse = Vector3.ZERO
    if collision:
        collision_impulse = collision.get_normal() * velocity.length() * ship.COLLISION_IMPULSE_MODIFIER * delta
        rotation_speed[0] = collision.get_normal().signed_angle_to(velocity, Vector3.FORWARD)
        rotation_speed[1] = collision.get_normal().signed_angle_to(velocity, Vector3.UP)
        rotation_speed[2] = collision.get_normal().signed_angle_to(velocity, Vector3.RIGHT)
        rotation_speed *= velocity.length() * ship.COLLISION_ROTATION_MODIFIER

    # try to lock on to target
    weapons_target = null
    # note: max range is handled by the ray length
    if target != null and position.distance_to(target.position) >= 5 and position.distance_to(target.position) <= 25 and rad_to_deg((-mesh.transform.basis.z).angle_to(position.direction_to(target.position))) <= 30:
        weapons_target = target.position + (target.velocity * (position.distance_to(target.position) / 50))
        targeting_ray.look_at(weapons_target)
        targeting_ray.force_raycast_update()
        if targeting_ray.is_colliding():
            weapons_target = targeting_ray.get_collision_point()

    # shoot target
    if weapons_target != null:
        if laser_timer.is_stopped():
            pass
            # shoot()

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
    boost_impulse = -mesh.transform.basis.z * ship.BOOST_IMPULSE_STRENGTH
    boost_timer.start(ship.BOOST_IMPULSE_DURATION)
    await boost_timer.timeout
    boost_impulse = Vector3.ZERO
    boost_timer.start(10)
    await boost_timer.timeout
    has_boost = true

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

func handle_bullet(damage):
    if shields_online:
        shields -= damage
        if shields <= 0:
            shields_online = false
            shield_timer.start(5)
    else:
        hull -= damage
    if hull <= 0:
        queue_free()
