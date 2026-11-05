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
    Phase (..),
    GameState (..),
    initGame,
    gameStep,
    headOf,
) where

import BFS
import Clash.Prelude
import Data.Maybe (fromMaybe)
import LFSR
import Types

-- ============================================================================
-- Estado completo do jogo. Um único registrador grande, atualizado por
-- 'gameStep' a cada ciclo de clock. A "cadência" do jogo (velocidade da
-- cobra) é controlada de fora, por um pulso 'tick' de 1 ciclo que chega
-- bem mais devagar que o clock do sistema (ver Top.hs).
-- ============================================================================

data Phase = Alive | Dead
    deriving (Generic, NFDataX, Eq, Show)

data GameState = GameState
    { gsOcc :: Grid Bool -- ocupação (corpo da cobra) p/ colisão O(1)
    , gsBody :: Vec MaxLen Coord -- índice 0 = cabeça; usa-se só até gsLen-1
    , gsLen :: Index (MaxLen + 1)
    , gsApple :: Coord
    , gsPhase :: Phase
    , gsTimer :: Unsigned 26 -- contagem regressiva da pausa de "game over"
    , gsBfs :: BfsState
    , gsRng :: BitVector 16
    , gsAte :: Bool -- pulso de 1 ciclo: "comeu a maçã agora"
    }
    deriving (Generic, NFDataX)

headOf :: GameState -> Coord
headOf gs = gsBody gs !! (0 :: Index MaxLen)

-- Duração da pausa de "fim de jogo" antes de reiniciar, em ciclos de tick
-- de jogo (ver GAME_HZ em Top.hs) — aqui contamos em ciclos de CLOCK
-- diretamente para simplificar; ~2s a 100MHz.
deadPauseCycles :: Unsigned 26
deadPauseCycles = 50_000_000 `div` 2 -- ~0.5s a 100MHz (ajuste livre)

startBody :: Vec MaxLen Coord
startBody = c0 :> c1 :> c2 :> repeat (Coord 0 0)
  where
    c0 = Coord 10 7
    c1 = Coord 9 7
    c2 = Coord 8 7

startOcc :: Grid Bool
startOcc = setG (setG (setG (emptyGrid False) (Coord 10 7) True) (Coord 9 7) True) (Coord 8 7) True

initGame :: BitVector 16 -> GameState
initGame seed =
    GameState
        { gsOcc = startOcc
        , gsBody = startBody
        , gsLen = 3
        , gsApple = firstFreeFrom seed startOcc
        , gsPhase = Alive
        , gsTimer = 0
        , gsBfs = seedStart
        , gsRng = if seed == 0 then 0xACE1 else seed
        , gsAte = False
        }

{- | Tenta algumas coordenadas pseudo-aleatórias sucessivas (avançando o
LFSR internamente); se nenhuma estiver livre, cai para uma varredura
determinística "primeira célula livre" — assim SEMPRE existe uma maçã
válida enquanto houver pelo menos uma célula livre no tabuleiro.
-}
firstFreeFrom :: BitVector 16 -> Grid Bool -> Coord
firstFreeFrom seed occ = go seed (4 :: Unsigned 4)
  where
    go _ 0 = firstFreeScan occ
    go s n =
        let c = coordFromRng s
         in if not (getG occ c) then c else go (lfsrNext s) (n - 1)

firstFreeScan :: Grid Bool -> Coord
firstFreeScan occ = fromMaybe (Coord 0 0) (foldr (<|>) Nothing candidates)
  where
    candidates :: Vec NCells (Maybe Coord)
    candidates = flattenG grid
    grid :: Grid (Maybe Coord)
    grid = imap (\y row -> imap (\x occCell -> if occCell then Nothing else Just (Coord x y)) row) occ

-- ============================================================================
-- Passo único de clock. Combina:
--   * avanço contínuo do LFSR (para ter entropia pronta quando precisar);
--   * avanço do BFS enquanto ele não estiver pronto (BDone);
--   * na chegada de um 'tick' de jogo com o BFS já pronto: aplica o
--     movimento, checa colisão/maçã, e já dispara a PRÓXIMA busca;
--   * lógica de fim de jogo / reinício.
-- ============================================================================
gameStep :: GameState -> Bool -> GameState
gameStep gs tick =
    let rng' = lfsrNext (gsRng gs)
     in case gsPhase gs of
            Dead ->
                if gsTimer gs == 0
                    then initGame rng'
                    else gs{gsTimer = gsTimer gs - 1, gsRng = rng', gsAte = False}
            Alive
                | bPhase (gsBfs gs) /= BDone ->
                    gs
                        { gsBfs = bfsStep (gsOcc gs) (headOf gs) (gsApple gs) (gsBfs gs)
                        , gsRng = rng'
                        , gsAte = False
                        }
                | not tick ->
                    gs{gsRng = rng', gsAte = False} -- resposta do BFS já pronta, só aguardando o próximo tick
                | otherwise ->
                    case decide (gsBfs gs) of
                        Nothing ->
                            -- cabeça totalmente cercada: não há movimento seguro -> fim de jogo
                            gs{gsPhase = Dead, gsTimer = deadPauseCycles, gsRng = rng', gsAte = False}
                        Just dir ->
                            case neighbor (headOf gs) dir of
                                Nothing ->
                                    -- defensivo: BFS nunca deveria escolher uma direção que bate
                                    -- na parede, mas se acontecer, tratamos como game over.
                                    gs{gsPhase = Dead, gsTimer = deadPauseCycles, gsRng = rng', gsAte = False}
                                Just newHead
                                    | getG (gsOcc gs) newHead ->
                                        -- defensivo: idem, não deveria colidir com o corpo.
                                        gs{gsPhase = Dead, gsTimer = deadPauseCycles, gsRng = rng', gsAte = False}
                                    | otherwise ->
                                        let ateApple = newHead == gsApple gs
                                            tailIdx = resize (gsLen gs - 1) :: Index MaxLen
                                            tailC = gsBody gs !! tailIdx -- célula que sai (se não crescer)
                                         in if ateApple
                                                then
                                                    let newBody = newHead +>> gsBody gs
                                                        newOcc = setG (gsOcc gs) newHead True
                                                        newLen = if gsLen gs == maxBound then gsLen gs else gsLen gs + 1
                                                        newApple = firstFreeFrom rng' newOcc
                                                     in gs
                                                            { gsBody = newBody
                                                            , gsOcc = newOcc
                                                            , gsLen = newLen
                                                            , gsApple = newApple
                                                            , gsBfs = seedStart
                                                            , gsRng = rng'
                                                            , gsAte = True
                                                            }
                                                else
                                                    let occNoTail = setG (gsOcc gs) tailC False
                                                        newOcc = setG occNoTail newHead True
                                                        newBody = newHead +>> gsBody gs
                                                     in gs
                                                            { gsBody = newBody
                                                            , gsOcc = newOcc
                                                            , gsBfs = seedStart
                                                            , gsRng = rng'
                                                            , gsAte = False
                                                            }
