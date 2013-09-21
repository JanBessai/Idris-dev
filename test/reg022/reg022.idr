module Main

mkList : Integer -> List Integer -> List Integer
mkList x xs = if x == 1 then (x :: xs) else mkList (x - 1) (x::xs)

main : IO ()
main = print $ foldr (+) (fromInteger 0) (mkList (fromInteger 1000000) [])


