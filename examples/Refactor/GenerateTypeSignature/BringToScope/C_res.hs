module Refactor.GenerateTypeSignature.BringToScope.C where

import Refactor.GenerateTypeSignature.BringToScope.B
import qualified Refactor.GenerateTypeSignature.BringToScope.A as AAA (S)
import Refactor.GenerateTypeSignature.BringToScope.A(T)

g :: T -> AAA.S
g = f
