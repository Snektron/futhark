-- Properly check uniqueness of return values when calling
-- higher-order functions.
-- ==
-- error:

let cons (f: () -> *[2]i32) : *[2]i32 =
  f () with [0] = 1

let main (x: [2]i32) : *[2]i32 =
  let f () : []i32 = x
  in cons f
