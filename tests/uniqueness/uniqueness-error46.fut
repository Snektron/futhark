-- The result of a functional argument may alias anything (unless it's
-- unique).
-- ==
-- error: "f".*which is not consumable

let g (_: *[]i32) = true

let f (f: i32 -> []i32): i32 =
  let xs = f 1
  let xs[0] = xs[0] + 2
  in 2
