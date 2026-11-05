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

module Snake (
    Mode (..),
    GameState (..),
    initGame,
    gameStep,
    isDead,
    startBodyRam,
) where

import BFS
import Clash.Prelude
import LFSR
import Types

-- ============================================================================
-- Estado do jogo, atualizado por 'gameStep' a cada ciclo de clock, sempre
-- mexendo em UMA célula por vez.
--
-- O corpo da cobra é um buffer circular guardado numa BLOCK RAM (ver Top.hs):
-- só precisamos ler a CAUDA (para liberá-la) e escrever a nova CABEÇA. A
-- posição da cabeça fica em registrador (gsHead). A leitura da cauda chega
-- como entrada de 'gameStep' (latência de 1 ciclo; o endereço só muda a cada
-- movimento, milhões de ciclos antes do próximo, então o dado é sempre válido).
--
-- Modos:
--   MInit k : escreve a k-ésima célula do corpo inicial na RAM
--   MApple  : sorteia (1 candidato por ciclo) uma célula livre para a maçã
--   MThink  : roda o BFS; no tick, move a cobra
--   MDead   : pausa de game over, depois reinicia
-- ============================================================================

data Mode = MInit (Index 3) | MApple | MThink | MDead
    deriving (Generic, NFDataX, Eq, Show)

data GameState = GameState
    { gsOcc :: Cells Bool -- ocupação (corpo da cobra) p/ colisão O(1)
    , gsHead :: Coord
    , gsHeadPtr :: CIdx -- posição da cabeça no buffer circular
    , gsTailPtr :: CIdx -- posição da cauda no buffer circular
    , gsLen :: Index (NCells + 1)
    , gsApple :: Coord
    , gsMode :: Mode
    , gsTimer :: Unsigned 26 -- contagem regressiva da pausa de "game over"
    , gsBfs :: BfsState
    , gsRng :: BitVector 16
    , gsAte :: Bool -- pulso de 1 ciclo: "comeu a maçã agora"
    , gsWr :: Maybe (CIdx, Coord) -- escrita pendente na RAM do corpo (1 ciclo)
    }
    deriving (Generic, NFDataX)

isDead :: GameState -> Bool
isDead gs = gsMode gs == MDead

-- | Conteúdo inicial da RAM do corpo (o corpo real é escrito em MInit).
startBodyRam :: Vec NCells Coord
startBodyRam = repeat (Coord 0 0)

-- Corpo inicial: índice 0 = cauda, 2 = cabeça.
startCell :: Index 3 -> Coord
startCell 0 = Coord 8 7
startCell 1 = Coord 9 7
startCell _ = Coord 10 7

startOcc :: Cells Bool
startOcc = setC (setC (setC (repeat False) (Coord 10 7) True) (Coord 9 7) True) (Coord 8 7) True

-- ~0.5s a 50MHz
deadPauseCycles :: Unsigned 26
deadPauseCycles = 25_000_000

initGame :: BitVector 16 -> GameState
initGame seed =
    GameState
        { gsOcc = startOcc
        , gsHead = Coord 10 7
        , gsHeadPtr = 2
        , gsTailPtr = 0
        , gsLen = 3
        , gsApple = Coord 0 0
        , gsMode = MInit 0
        , gsTimer = 0
        , gsBfs = initBfs
        , gsRng = if seed == 0 then 0xACE1 else seed
        , gsAte = False
        , gsWr = Nothing
        }

{- | Passo único de clock. 'tick' é o pulso lento de movimento; 'tailC' é a
saída (registrada) da RAM do corpo, lida no endereço gsTailPtr.
-}
gameStep :: GameState -> Bool -> Coord -> GameState
gameStep gs tick tailC = case gsMode gs of
    MInit k ->
        base
            { gsWr = Just (resize k, startCell k)
            , gsMode = if k == maxBound then MApple else MInit (k + 1)
            }
    MDead ->
        if gsTimer gs == 0
            then initGame rng'
            else base{gsTimer = gsTimer gs - 1}
    MApple
        | gsLen gs == maxBound -> die -- tabuleiro cheio: acabou
        | otherwise ->
            let c = coordFromRng (gsRng gs)
             in if getC (gsOcc gs) c
                    then base -- ocupada, tenta o próximo valor do LFSR
                    else base{gsApple = c, gsMode = MThink, gsBfs = seedStart}
    MThink
        | bPhase (gsBfs gs) /= BDone ->
            base{gsBfs = bfsStep (gsOcc gs) (gsHead gs) (gsApple gs) (gsBfs gs)}
        | not tick -> base
        | otherwise -> case decide (gsBfs gs) of
            Nothing -> die -- cabeça totalmente cercada
            Just dir -> case neighbor (gsHead gs) dir of
                Nothing -> die -- defensivo
                Just nh
                    | getC (gsOcc gs) nh -> die -- defensivo
                    | otherwise -> move nh
  where
    rng' = lfsrNext (gsRng gs)
    base = gs{gsRng = rng', gsAte = False, gsWr = Nothing}
    die = base{gsMode = MDead, gsTimer = deadPauseCycles}

    move nh =
        let ate = nh == gsApple gs
            occ1 = if ate then gsOcc gs else setC (gsOcc gs) tailC False
            occ2 = setC occ1 nh True
            hp = incIdx (gsHeadPtr gs)
         in base
                { gsOcc = occ2
                , gsHead = nh
                , gsHeadPtr = hp
                , gsTailPtr = if ate then gsTailPtr gs else incIdx (gsTailPtr gs)
                , gsLen = if ate then gsLen gs + 1 else gsLen gs
                , gsWr = Just (hp, nh)
                , gsAte = ate
                , gsMode = if ate then MApple else MThink
                , gsBfs = if ate then initBfs else seedStart
                }
