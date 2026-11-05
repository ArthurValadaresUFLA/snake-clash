{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoStarIsType #-}
{-# OPTIONS_GHC -fplugin=GHC.TypeLits.Extra.Solver -fplugin=GHC.TypeLits.Normalise -fplugin=GHC.TypeLits.KnownNat.Solver #-}

module Render (
    Rgb444 (..),
    renderGen,
) where

import Clash.Prelude
import Snake
import Types
import VGA

-- ============================================================================
-- Renderização simples: cada célula (32x32 px) vira um quadrado sólido
-- (preto = vazio, verde = corpo, branco = cabeça, vermelho = maçã), com uma
-- linha de grade escura. Em "game over" a tela pisca em vermelho.
--
-- Pipeline de 2 estágios (cores, HSYNC e VSYNC saem registrados e atrasados
-- igualmente):
--   estágio 1: pixel -> coordenada/índice da célula (shift de 5 bits, sem
--              divisão) e flags;
--   estágio 2: consulta ocupação/maçã/cabeça e escolhe a cor.
-- ============================================================================

-- | Saída: 4 bits por canal.
data Rgb444 = Rgb444
    { rR :: Unsigned 4
    , rG :: Unsigned 4
    , rB :: Unsigned 4
    }
    deriving (Generic, NFDataX, Eq)

black, darkGray, green, brightWhite, red :: Rgb444
black = Rgb444 0 0 0
darkGray = Rgb444 0x2 0x2 0x2
green = Rgb444 0x1 0xC 0x1
brightWhite = Rgb444 0xF 0xF 0xF
red = Rgb444 0xF 0x1 0x1

data Pre = Pre
    { pCell :: Coord
    , pIdx :: CIdx
    , pGrid :: Bool
    , pVis :: Bool
    , pHs :: Bool
    , pVs :: Bool
    }
    deriving (Generic, NFDataX)

pre0 :: Pre
pre0 = Pre (Coord 0 0) 0 False False True True

stage1 :: VgaOut -> Pre
stage1 v = Pre c (toIdx c) grid vis (vgaHSync v) (vgaVSync v)
  where
    h = vgaHCount v
    vv = vgaVCount v
    vis = vgaVisible v
    -- 32 px por célula: divisão = shift de 5 bits
    c =
        if vis
            then Coord (fromIntegral (h `shiftR` 5)) (fromIntegral (vv `shiftR` 5))
            else Coord 0 0
    grid = (h .&. 31) == 0 || (vv .&. 31) == 0

stage2 :: GameState -> Bool -> Pre -> (Rgb444, Bool, Bool)
stage2 gs blinkOn p = (col, pHs p, pVs p)
  where
    col
        | not (pVis p) = black
        | isDead gs = if blinkOn then red else black
        | pCell p == gsApple gs = red
        | gsOcc gs !! pIdx p = if pCell p == gsHead gs then brightWhite else green
        | pGrid p = darkGray
        | otherwise = black

-- | (R/G/B, HSYNC, VSYNC), já registrados.
renderGen ::
    forall dom.
    (HiddenClockResetEnable dom) =>
    Signal dom GameState ->
    Signal dom VgaOut ->
    Signal dom Bool ->
    (Signal dom Rgb444, Signal dom Bool, Signal dom Bool)
renderGen gs vga blink = unbundle out
  where
    p1 :: Signal dom Pre
    p1 = register pre0 (stage1 <$> vga)
    out :: Signal dom (Rgb444, Bool, Bool)
    out = register (black, True, True) (stage2 <$> gs <*> blink <*> p1)
