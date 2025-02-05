-- ==
-- input { 3 [1,2,3] } output { [0,0,1] }
-- compiled input { 0 [1,2,3] } error: division by zero
-- structure gpu { SegMap/Apply 1 /Apply 1 }

let f (x: i32) (y: i32) = x / y

let g (x: i32) (y: i32) = #[noinline] f x y

let main y = map (\x -> #[noinline] g x y)
