{-# OPTIONS --copatterns #-}

open import Common.Prelude
open import Common.MAlonzo using (mainPrint)

record R : Set where
  field
    f1 : Nat
    f2 : String

r : R
R.f1 r = 5
R.f2 r = "yes"

main = mainPrint (R.f2 r)
