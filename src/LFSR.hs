{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoStarIsType #-}
{-# OPTIONS_GHC -fplugin=GHC.TypeLits.Extra.Solver -fplugin=GHC.TypeLits.Normalise -fplugin=GHC.TypeLits.KnownNat.Solver #-}

module LFSR (
    lfsrNext,
    coordFromRng,
) where

import Clash.Prelude
import Types

-- ============================================================================
-- LFSR de Fibonacci de 16 bits (polinômio x^16+x^14+x^13+x^11+1, período
-- máximo 65535). Não é criptograficamente aleatório nem precisa ser: só
-- precisamos de uma sequência "embaralhada o bastante" para não repetir
-- sempre a mesma posição de maçã. Ele avança 1x por ciclo de clock,
-- continuamente, então quando a maçã precisa reaparecer o valor já
-- "andou" bastante desde o último uso.
-- ============================================================================
lfsrNext :: BitVector 16 -> BitVector 16
lfsrNext s = shiftL s 1 .|. fb
  where
    b0 = testBit s 15
    b1 = testBit s 13
    b2 = testBit s 12
    b3 = testBit s 10
    fbBit = b0 `xor` b1 `xor` b2 `xor` b3
    fb = if fbBit then 1 else 0

{- | Deriva uma coordenada "pseudo-aleatória" (não necessariamente livre!)
a partir do estado do LFSR. Cols=20 cabe em 5 bits (0..31, tomamos mod),
Rows=15 cabe em 4 bits (0..15, tomamos mod).
-}
coordFromRng :: BitVector 16 -> Coord
coordFromRng s = Coord x y
  where
    rawX = fromIntegral (slice d4 d0 s) :: Unsigned 5 -- bits 0..4
    rawY = fromIntegral (slice d8 d5 s) :: Unsigned 4 -- bits 5..8
    x = fromIntegral (rawX `mod` fromIntegral (natToNum @Cols :: Unsigned 5))
    y = fromIntegral (rawY `mod` fromIntegral (natToNum @Rows :: Unsigned 4))
