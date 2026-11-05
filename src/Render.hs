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
    pixelColor,
) where

import Clash.Prelude
import Snake
import Types
import VGA

-- ============================================================================
-- Renderização propositalmente simples: sem sprites, sem antialiasing,
-- sem textura — cada célula do tabuleiro vira um quadrado sólido de cor
-- única (preto = vazio, verde = corpo da cobra, branco = cabeça,
-- vermelho = maçã), com uma linha de grade 1px mais escura entre células
-- só para dar noção visual do tabuleiro. Em "game over" a tela pisca em
-- vermelho.
-- ============================================================================

cellPx :: Unsigned 10
cellPx = 32 -- 640/20 = 32, 480/15 = 32 -> bate certinho com Cols/Rows

-- | Saída típica de placas didáticas (Basys3/Nexys): 4 bits por canal.
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

pixelToCoord :: Unsigned 10 -> Unsigned 10 -> Coord
pixelToCoord h v = Coord x y
  where
    x = fromIntegral (h `div` cellPx)
    y = fromIntegral (v `div` cellPx)

isGridLine :: Unsigned 10 -> Unsigned 10 -> Bool
isGridLine h v = (h `mod` cellPx == 0) || (v `mod` cellPx == 0)

pixelColor :: GameState -> VgaOut -> Bool -> Rgb444
pixelColor gs vga blinkOn
    | not (vgaVisible vga) = black
    | gsPhase gs == Dead = if blinkOn then red else black
    | otherwise =
        let h = vgaHCount vga
            v = vgaVCount vga
            c = pixelToCoord h v
         in if c == gsApple gs
                then red
                else
                    if getG (gsOcc gs) c
                        then if c == headOf gs then brightWhite else green
                        else
                            if isGridLine h v
                                then darkGray
                                else black
