## PlacementCheckResult — composite return value for GridSystem.can_place().
##
## Carries the verdict of a placement validation: whether the placement is
## legal, which of the 5 FailCode values rejected it (if it failed), and the
## specific cell that caused the failure (for UI highlighting, e.g. showing
## the exact wall cell or occupied cell the player's ghost outline is on).
##
## This is a plain data-transfer object — it holds no logic and performs no
## validation itself. The FailCode values it carries live on GridSystem
## (GridSystem.FailCode), mirroring how TransformedFootprint is a DTO that
## carries data produced by GridSystem.
##
## Usage example:
##   var result: PlacementCheckResult = grid_system.can_place(
##       [Vector2i(0, 0)], [Vector2i(0, 1)], Vector2i(3, 3), GridSystem.Rotation.R0
##   )
##   if not result.valid:
##       print("rejected: %d at %s" % [result.fail_code, result.fail_cell])
class_name PlacementCheckResult extends RefCounted

## Whether the placement is legal. False when any footprint/access check
## failed, OR when can_place() was called in an unusable state (before
## init(), empty footprint input, illegal rotation) — see can_place()'s
## guard documentation for the safe-default contract on those paths.
var valid: bool = false

## The GridSystem.FailCode value that rejected the placement. Only
## meaningful when valid == false; when valid == true this is
## GridSystem.FailCode.VALID (0).
var fail_code: int = 0

## The specific cell that caused the failure (for UI highlighting).
## Unspecified (Vector2i.ZERO) when valid == true — no cell failed.
var fail_cell: Vector2i = Vector2i.ZERO
