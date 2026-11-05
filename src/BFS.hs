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

module BFS (
    BfsPhase (..),
    BfsState (..),
    initBfs,
    seedStart,
    bfsStep,
    decide,
) where

import Clash.Prelude
import Types

-- ============================================================================
-- O "cérebro" da cobra.
--
-- IDEIA (heurística, não é IA treinada nem caminho hamiltoniano):
--
-- 1) A partir da CABEÇA da cobra, olhamos as até 4 células vizinhas livres
--    (N/E/S/W). Cada uma recebe uma "cor" (a própria direção).
-- 2) Fazemos UMA busca em largura (BFS) multi-fonte a partir dessas 4
--    sementes, simultaneamente, por todo o tabuleiro livre (ignorando
--    paredes e o corpo da cobra). Cada célula nova visitada herda a cor
--    de quem a alcançou primeiro (BFS = por camadas, então isso ainda
--    representa a menor distância a partir de cada vizinho inicial).
-- 3) Durante essa busca:
--      a) contamos quantas células cada cor alcançou (bArea) — isto é,
--         o tamanho da região alcançável a partir daquela primeira jogada;
--      b) se a MAÇÃ for alcançada, registramos com qual cor (bAppleDir).
-- 4) Decisão final:
--      - se a maçã foi alcançada por alguma cor  -> anda naquela direção
--        (é garantidamente o primeiro passo de UM caminho mais curto até
--        a maçã, pois BFS explora em ordem de distância);
--      - senão (maçã inalcançável dado o formato atual do corpo) -> anda
--        na direção cuja região tem MAIS espaço livre (heurística de
--        sobrevivência clássica: "flood fill" / maximizar área aberta).
--        Isso evita o erro mais comum de uma IA gulosa ingênua, que é
--        se prender num corredor sem saída perseguindo a maçã.
--
-- Isso NÃO garante resolver 100% das partidas (à medida que a cobra
-- ocupa quase todo o tabuleiro, mesmo maximizar espaço pode não evitar
-- um encurralamento — provar uma solução geral exigiria, de fato, algo
-- como um ciclo hamiltoniano adaptativo ou uma IA treinada). Na prática,
-- porém, essa heurística resolve a esmagadora maioria das partidas e
-- é totalmente barata de sintetizar.
-- ============================================================================

data BfsPhase = BIdle | BSeed | BRun | BDone
    deriving (Generic, NFDataX, Eq, Show)

data BfsState = BfsState
    { bPhase :: BfsPhase
    , bVisited :: Grid Bool
    , bColor :: Grid (Maybe Dir4)
    , bQueue :: Vec NCells Coord
    , bQHead :: CIdx
    , bQTail :: CIdx
    , bQCount :: Index (NCells + 1)
    , bArea :: Vec 4 (Index (NCells + 1))
    , bAppleDir :: Maybe Dir4
    , bSeedIdx :: Index 4
    , bSeedDone :: Bool
    }
    deriving (Generic, NFDataX)

initBfs :: BfsState
initBfs =
    BfsState
        { bPhase = BIdle
        , bVisited = emptyGrid False
        , bColor = emptyGrid Nothing
        , bQueue = repeat (Coord 0 0)
        , bQHead = 0
        , bQTail = 0
        , bQCount = 0
        , bArea = repeat 0
        , bAppleDir = Nothing
        , bSeedIdx = 0
        , bSeedDone = False
        }

{- | Prepara uma nova busca (chamar quando a cabeça/ocupação mudarem, isto
é, logo após cada movimento da cobra).
-}
seedStart :: BfsState
seedStart = initBfs{bPhase = BSeed}

areaOf :: BfsState -> Dir4 -> Index (NCells + 1)
areaOf st d = bArea st !! dirToIdx d

setArea :: BfsState -> Dir4 -> Index (NCells + 1) -> BfsState
setArea st d v = st{bArea = replace (dirToIdx d) v (bArea st)}

enqueueColored :: Grid Bool -> Coord -> Dir4 -> Coord -> BfsState -> BfsState
enqueueColored occ appleC dir nc st
    | getG occ nc = st -- parede/corpo, não é alcançável
    | getG (bVisited st) nc = st -- já visitada por outra cor (chegou antes = mais perto)
    | otherwise =
        let st1 =
                st
                    { bVisited = setG (bVisited st) nc True
                    , bColor = setG (bColor st) nc (Just dir)
                    , bQueue = replace (bQTail st) nc (bQueue st)
                    , bQTail = incIdx (bQTail st)
                    , bQCount = bQCount st + 1
                    }
            st2 = setArea st1 dir (areaOf st1 dir + 1)
            st3 =
                if nc == appleC && bAppleDir st2 == Nothing
                    then st2{bAppleDir = Just dir}
                    else st2
         in st3

{- | Avança o BFS em UM ciclo de clock. Chamar continuamente enquanto
bPhase /= BDone; o resultado fica pronto bem antes do próximo "tick"
de movimento do jogo (o tabuleiro tem no máximo NCells células, então
o pior caso é NCells+4 ciclos de clock — irrisório comparado ao
período entre movimentos, que é da ordem de milhões de ciclos).
-}
bfsStep :: Grid Bool -> Coord -> Coord -> BfsState -> BfsState
bfsStep occ headC appleC st = case bPhase st of
    BIdle -> st
    BDone -> st
    BSeed ->
        let dir = idxToDir (bSeedIdx st)
            st' = case neighbor headC dir of
                Just nc -> enqueueColored occ appleC dir nc st
                Nothing -> st
            isLast = bSeedIdx st == maxBound
         in if isLast
                then
                    st'
                        { bPhase = if bQCount st' == 0 then BDone else BRun
                        , bSeedIdx = 0
                        }
                else st'{bSeedIdx = bSeedIdx st' + 1}
    BRun ->
        if bQCount st == 0
            then st{bPhase = BDone}
            else
                let cur = bQueue st !! bQHead st
                    mCol = getG (bColor st) cur
                    col = case mCol of Just c -> c; Nothing -> North -- nunca Nothing na prática
                    st1 = st{bQHead = incIdx (bQHead st), bQCount = bQCount st - 1}
                    st2 =
                        foldl
                            ( \acc d -> case neighbor cur d of
                                Just nc -> enqueueColored occ appleC col nc acc
                                Nothing -> acc
                            )
                            st1
                            allDirs -- foldl aqui é o de Clash.Sized.Vector, não o de listas
                 in st2

{- | Depois que bPhase == BDone, extrai a direção escolhida.
Nothing só acontece se a cabeça estiver completamente cercada
(nenhum vizinho livre) -> fim de jogo.
-}
decide :: BfsState -> Maybe Dir4
decide st = case bAppleDir st of
    Just d -> Just d
    Nothing -> pickBestArea (bArea st)

pickBestArea :: Vec 4 (Index (NCells + 1)) -> Maybe Dir4
pickBestArea areas =
    let indexed = zip allDirs areas -- Vec 4 (Dir4, Index ...)
        best = foldl1 pickBigger indexed -- foldl1 de Clash.Sized.Vector, Vec 4 = Vec (3+1)
        pickBigger a@(_, va) b@(_, vb) = if vb > va then b else a
     in if snd best == 0 then Nothing else Just (fst best)
