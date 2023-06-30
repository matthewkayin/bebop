extends Camera3D

var enemy = null

func _process(_delta):
    if enemy == null:
        enemy = get_node_or_null("../enemy")
        if enemy == null:
            return

    look_at(enemy.position)
