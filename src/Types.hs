{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoStarIsType #-}
{-# OPTIONS_GHC -fplugin=GHC.TypeLits.Extra.Solver -fplugin=GHC.TypeLits.Normalise -fplugin=GHC.TypeLits.KnownNat.Solver #-}

module Types where

import Clash.Prelude

-- ============================================================================
-- Parâmetros do tabuleiro
-- ============================================================================
-- 640x480 dividido em blocos de 32x32 pixels -> 20 colunas x 15 linhas.
-- Alterar aqui (junto com o shift de 5 bits em Render.hs) para mudar a
-- resolução lógica do jogo.

type Cols = 20
type Rows = 15
type NCells = Rows * Cols -- 300 células

type XI = Index Cols
type YI = Index Rows

-- | Índice linear (row-major) de uma célula.
type CIdx = Index NCells

-- | Coordenada discreta de uma célula do tabuleiro (não é pixel).
data Coord = Coord
    { cx :: XI
    , cy :: YI
    }
    deriving (Generic, NFDataX, Eq, Show)

{- | As quatro direções cardeais. Também reaproveitada como "cor" no BFS
(cada uma das 4 direções iniciais a partir da cabeça vira uma cor).
-}
data Dir4 = North | East_ | South | West
    deriving (Generic, NFDataX, Eq, Show, Bounded)

dirToIdx :: Dir4 -> Index 4
dirToIdx North = 0
dirToIdx East_ = 1
dirToIdx South = 2
dirToIdx West = 3

idxToDir :: Index 4 -> Dir4
idxToDir 0 = North
idxToDir 1 = East_
idxToDir 2 = South
idxToDir _ = West

allDirs :: Vec 4 Dir4
allDirs = North :> East_ :> South :> West :> Nil

{- | Vizinho de uma coordenada numa direção, ou Nothing se cair fora do
tabuleiro (ou seja, seria colidir com a parede).
-}
neighbor :: Coord -> Dir4 -> Maybe Coord
neighbor (Coord x y) North
    | y == 0 = Nothing
    | otherwise = Just (Coord x (y - 1))
neighbor (Coord x y) South
    | y == maxBound = Nothing
    | otherwise = Just (Coord x (y + 1))
neighbor (Coord x y) West
    | x == 0 = Nothing
    | otherwise = Just (Coord (x - 1) y)
neighbor (Coord x y) East_
    | x == maxBound = Nothing
    | otherwise = Just (Coord (x + 1) y)

-- | Próxima célula em ordem row-major; Nothing depois da última.
nextCell :: Coord -> Maybe Coord
nextCell (Coord x y)
    | x /= maxBound = Just (Coord (x + 1) y)
    | y /= maxBound = Just (Coord 0 (y + 1))
    | otherwise = Nothing

-- | Coordenada -> índice linear (y * Cols + x).
toIdx :: Coord -> CIdx
toIdx (Coord x y) = fromIntegral (yy * 20 + xx)
  where
    yy = fromIntegral y :: Unsigned 9
    xx = fromIntegral x :: Unsigned 9

-- ============================================================================
-- Mapa de células achatado (um Vec de NCells). Todo acesso é a UMA célula por
-- vez (leitura por índice, escrita por índice), o que mantém a lógica gerada
-- pequena. Evite Vec (Vec ..) com replace aninhado e laços sobre o tabuleiro
-- inteiro em um único ciclo: é isso que faz o Quartus travar na síntese.
-- ============================================================================

type Cells a = Vec NCells a

getC :: Cells a -> Coord -> a
getC v c = v !! toIdx c

setC :: Cells a -> Coord -> a -> Cells a
setC v c x = replace (toIdx c) x v

incIdx :: CIdx -> CIdx
incIdx i
    | i == maxBound = 0
    | otherwise = i + 1
