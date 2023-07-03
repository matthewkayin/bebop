extends Node

func vector_component_in_vector_direction(fvector: Vector3, dvector: Vector3) -> Vector3:
    return (dvector * fvector.dot(dvector)) / dvector.length()