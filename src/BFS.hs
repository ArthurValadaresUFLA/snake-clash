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

module BFS (
    BfsPhase (..),
    BfsState (..),
    initBfs,
    seedStart,
    bfsStep,
    decide,
) where

import Clash.Prelude
import Data.Maybe (isNothing)
import Types

-- ============================================================================
-- O "cérebro" da cobra (mesma heurística de antes, agora SEQUENCIAL).
--
-- IDEIA:
-- 1) A partir da CABEÇA, cada vizinho livre (N/E/S/W) recebe uma "cor" (a
--    própria direção) e entra na fronteira.
-- 2) BFS multi-fonte POR CAMADAS: varre as 300 células em ordem; cada célula
--    da fronteira atual (bCur) expande, UMA direção por ciclo, os vizinhos
--    livres e não visitados para a próxima fronteira (bNext), herdando a cor.
--    Terminada a varredura, bNext vira bCur e repete até não nascer nada.
-- 3) Conta a área alcançada por cor (bArea) e qual cor alcançou a maçã
--    primeiro (bAppleDir).
-- 4) Decisão: se a maçã foi alcançada -> anda nessa direção (primeiro passo
--    de um caminho mais curto); senão -> direção com MAIOR área alcançável.
--
-- POR QUE ASSIM: o BFS antigo mexia em grades inteiras (Vec (Vec ..)) e numa
-- fila de 300 coordenadas com `replace` dinâmico, 4 vezes por ciclo, e o
-- Clash desenrolava isso numa lógica combinacional gigante. Aqui cada ciclo
-- lê/escreve no máximo UMA célula de cada mapa (um mux 300:1 e um decodificador
-- por mapa). Custo: no pior caso ~4*300 ciclos por camada; com ~40-100 camadas
-- são < 120 mil ciclos (~2 ms), muito menos que o período de um movimento.
-- ============================================================================

data BfsPhase = BIdle | BSeed | BScan | BSwap | BDone
    deriving (Generic, NFDataX, Eq, Show)

data BfsState = BfsState
    { bPhase :: BfsPhase
    , bVisited :: Cells Bool
    , bColor :: Cells Dir4
    , bCur :: Cells Bool -- fronteira em expansão
    , bNext :: Cells Bool -- fronteira da próxima camada
    , bScan :: Coord -- célula sendo varrida
    , bDir :: Index 4 -- direção sendo tratada (semente ou vizinho)
    , bAny :: Bool -- nasceu alguma célula em bNext
    , bArea :: Vec 4 (Index (NCells + 1))
    , bAppleDir :: Maybe Dir4
    }
    deriving (Generic, NFDataX)

initBfs :: BfsState
initBfs =
    BfsState
        { bPhase = BIdle
        , bVisited = repeat False
        , bColor = repeat North
        , bCur = repeat False
        , bNext = repeat False
        , bScan = Coord 0 0
        , bDir = 0
        , bAny = False
        , bArea = repeat 0
        , bAppleDir = Nothing
        }

-- | Prepara uma nova busca (chamar logo após cada movimento da cobra).
seedStart :: BfsState
seedStart = initBfs{bPhase = BSeed}

-- | Visita um vizinho livre e ainda não visitado.
expand :: Cells Bool -> Coord -> Dir4 -> Coord -> BfsState -> BfsState
expand occ appleC col nc st
    | getC occ nc = st -- parede/corpo, não é alcançável
    | getC (bVisited st) nc = st -- já alcançada (por camada anterior ou outra cor)
    | otherwise =
        st
            { bVisited = setC (bVisited st) nc True
            , bColor = setC (bColor st) nc col
            , bNext = setC (bNext st) nc True
            , bArea = replace ci (bArea st !! ci + 1) (bArea st)
            , bAny = True
            , bAppleDir =
                if nc == appleC && isNothing (bAppleDir st)
                    then Just col
                    else bAppleDir st
            }
  where
    ci = dirToIdx col

{- | Avança o BFS em UM ciclo de clock. Chamar continuamente enquanto
bPhase /= BDone.
-}
bfsStep :: Cells Bool -> Coord -> Coord -> BfsState -> BfsState
bfsStep occ headC appleC st = case bPhase st of
    BIdle -> st
    BDone -> st
    BSeed ->
        let d = bDir st
            dir = idxToDir d
            st' = case neighbor headC dir of
                Just nc -> expand occ appleC dir nc st
                Nothing -> st
         in if d == maxBound
                then st'{bPhase = BSwap, bDir = 0}
                else st'{bDir = d + 1}
    BSwap ->
        if bAny st
            then
                st
                    { bPhase = BScan
                    , bCur = bNext st
                    , bNext = repeat False
                    , bScan = Coord 0 0
                    , bDir = 0
                    , bAny = False
                    }
            else st{bPhase = BDone}
    BScan ->
        let cur = bScan st
            d = bDir st
            active = getC (bCur st) cur
            col = getC (bColor st) cur
            st' =
                if active
                    then case neighbor cur (idxToDir d) of
                        Just nc -> expand occ appleC col nc st
                        Nothing -> st
                    else st
            cellDone = not active || d == maxBound
         in if cellDone
                then case nextCell cur of
                    Just c' -> st'{bScan = c', bDir = 0}
                    Nothing -> st'{bPhase = BSwap, bDir = 0}
                else st'{bDir = d + 1}

{- | Depois que bPhase == BDone, extrai a direção escolhida.
Nothing só acontece se a cabeça estiver completamente cercada.
-}
decide :: BfsState -> Maybe Dir4
decide st = case bAppleDir st of
    Just d -> Just d
    Nothing -> pickBestArea (bArea st)

pickBestArea :: Vec 4 (Index (NCells + 1)) -> Maybe Dir4
pickBestArea areas =
    let indexed = zip allDirs areas
        best = foldl1 pickBigger indexed
        pickBigger a@(_, va) b@(_, vb) = if vb > va then b else a
     in if snd best == 0 then Nothing else Just (fst best)
