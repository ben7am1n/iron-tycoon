## TransformedFootprint — composite return value for GridSystem.get_transformed_cells().
##
## Carries the world-space (anchor-offset) footprint cells, world-space access
## cells, and the post-rotation declared bounding box size (W,H) produced by
## rotating an equipment definition's canonical (0 degree) cells around a
## SINGLE shared declared bounding box (GDD D.1 / D.5, TR-GS-012/013/014).
##
## This is a plain data-transfer object -- it holds no logic and performs no
## further transforms. It exists (rather than a bare Dictionary) so callers
## get static-typed fields instead of string-keyed lookups, and so the API
## shape itself is the first line of defense for GridSystem's single
## highest-risk rule: footprint and access cells are ALWAYS computed together
## from the same (W,H), never as two independent calls that could each derive
## their own local bounding box (see grid_system.gd's get_transformed_cells()
## doc comment and GDD Core Rule 4).
##
## Usage example:
##   var result: TransformedFootprint = grid_system.get_transformed_cells(
##       [Vector2i(0, 0), Vector2i(0, 1)], [Vector2i(0, 2)],
##       Vector2i(3, 3), GridSystem.Rotation.R90
##   )
##   for cell in result.footprint_cells:
##       # cell is already anchor-offset, world-space
##       pass
##   print(result.new_size)  # Vector2i(3, 1) -- W/H swapped at 90 degrees
class_name TransformedFootprint extends RefCounted

## World-space (anchor-offset) footprint cells after rotation.
var footprint_cells: Array[Vector2i] = []

## World-space (anchor-offset) access cells after rotation.
var access_cells: Array[Vector2i] = []

## The (width, height) of the rotated declared bounding box. Equal to
## declared_bounds()'s (W,H) at 0deg/180deg; W and H swapped at 90deg/270deg.
var new_size: Vector2i = Vector2i.ZERO
