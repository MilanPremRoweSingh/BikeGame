extends Resource
class_name BikeGearData

@export_group("Gear")
@export var min_effective_speed: float = 4
@export var max_effective_speed: float = 6
@export var max_speed: float = 8
# acceleartion added per full rotation, the higher, the more resistance 
#@export var pedal_resistance: float = 0.5
#@export var transfer_multiplier: float = 0.5
func get_resistance(speed : float, slowdown_ramp : float) -> float:
    if speed < min_effective_speed:
        return 1 / (pow(slowdown_ramp, speed - min_effective_speed))

    return clamp((max_speed - speed) / (max_speed - min_effective_speed), 1e-3, 1)

func get_transfer(speed : float, smoothing_factor : float) -> float:
    #TODO: Make a transfer window (and resistance window) that is constant, the "effective zone"
    var x = speed
    var k = max(0.001, abs(smoothing_factor))
    var i = max_effective_speed
    var j = max_speed

    if x < i:
        return 1

    var t0 = exp(k*(x-i)/(j-i))
    var t1 = exp(k)
    var t2 = 1-exp(k)
    return clamp((t0 - t1)/t2, 0, 1)