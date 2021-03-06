{-# OPTIONS --copatterns #-}
module EmptyInductiveRecord where

mutual

  data E : Set where
    e : F -> E

  record F : Set where
    inductive
    constructor c
    field f : E
open F

data ⊥ : Set where

elim : E → ⊥
elim (e (c x)) = elim x

mutual

  empty : E
  empty = e empty?

  empty? : F
  f empty? = empty

absurd : ⊥
absurd = elim empty
