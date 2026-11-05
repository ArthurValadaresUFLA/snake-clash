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

module Types where

import Clash.Prelude

-- ============================================================================
-- Parâmetros do tabuleiro
-- ============================================================================
-- 640x480 dividido em blocos de 32x32 pixels -> 20 colunas x 15 linhas.
-- Alterar aqui (junto com o CELL_PX em Render.hs) para mudar a resolução
-- lógica do jogo. Quanto maior o tabuleiro, mais registradores a busca
-- (BFS.hs) consome — ver aviso no README.

type Cols = 20
type Rows = 15
type NCells = Rows * Cols -- 300 células, usado como capacidade da fila do BFS

type XI = Index Cols
type YI = Index Rows

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

-- índice 0..3 <-> direção, evitando depender de Enum/toEnum em hardware
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

-- ============================================================================
-- Grade genérica Rows x Cols de qualquer coisa (ocupação, "cor" do BFS, etc)
-- ============================================================================

type Grid a = Vec Rows (Vec Cols a)

emptyGrid :: a -> Grid a
emptyGrid v = repeat (repeat v)

getG :: Grid a -> Coord -> a
getG g (Coord x y) = (g !! y) !! x

setG :: Grid a -> Coord -> a -> Grid a
setG g (Coord x y) v = replace y (replace x v (g !! y)) g

-- | Achata a grade em ordem row-major, casando com NCells = Rows * Cols.
flattenG :: Grid a -> Vec NCells a
flattenG = concat

-- Índice linear auxiliar (usado para ponteiros de fila circular do BFS)
type CIdx = Index NCells

incIdx :: CIdx -> CIdx
incIdx i
    | i == maxBound = 0
    | otherwise = i + 1

-- | Tamanho máximo teórico da cobra: o tabuleiro inteiro.
type MaxLen = NCells
