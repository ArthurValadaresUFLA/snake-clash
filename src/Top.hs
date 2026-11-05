{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoStarIsType #-}
{-# OPTIONS_GHC -fplugin=GHC.TypeLits.Extra.Solver -fplugin=GHC.TypeLits.Normalise -fplugin=GHC.TypeLits.KnownNat.Solver #-}

module Top (
    topEntity,
) where

import Audio
import Clash.Annotations.TopEntity (PortName (..), TopEntity (Synthesize))
import Clash.Prelude
import Render
import Snake
import Types
import VGA

-- ============================================================================
-- Domínio de clock: clock de placa de 50MHz (DE10-Lite). Ajuste createDomain
-- se usar outra frequência, e os divisores em VGA.hs / Audio.hs /
-- gameTickCycles abaixo.
--
-- O KEY0 da DE10-Lite é ativo em nível baixo: apertar leva o pino a 0. Com
-- 'ActiveLow', o domínio e o HDL gerado já interpretam 'rst' nessa
-- polaridade, sem precisar de um inversor externo no topEntity.
-- ============================================================================
createDomain
    vSystem
        { vName = "Dom50"
        , vPeriod = hzToPeriod 50_000_000
        , vResetPolarity = ActiveLow
        }

-- Ciclos entre movimentos da cobra: 12 movimentos/s (50_000_000 / 12).
-- Literal para não gerar divisor.
gameTickCycles :: Unsigned 26
gameTickCycles = 4_166_667

tickGen :: forall dom. (HiddenClockResetEnable dom) => Signal dom Bool
tickGen = tick
  where
    cnt :: Signal dom (Unsigned 26)
    cnt = register (0 :: Unsigned 26) next
    next :: Signal dom (Unsigned 26)
    next = mux (cnt .==. pure (gameTickCycles - 1)) (pure 0) (cnt + 1)
    tick :: Signal dom Bool
    tick = cnt .==. pure 0

blinkGen :: forall dom. (HiddenClockResetEnable dom) => Signal dom Bool
blinkGen = fmap (`testBit` (23 :: Int)) cnt
  where
    cnt :: Signal dom (Unsigned 24)
    cnt = register (0 :: Unsigned 24) (cnt + 1)

gameSignal :: forall dom. (HiddenClockResetEnable dom) => Signal dom GameState
gameSignal = gs
  where
    gs :: Signal dom GameState
    gs = register (initGame 0xBEEF) (gameStep <$> gs <*> tickGen <*> tailC)

    -- Corpo da cobra (buffer circular) em block RAM: lê a cauda no endereço
    -- gsTailPtr e grava a nova cabeça quando gsWr for Just.
    tailC :: Signal dom Coord
    tailC = blockRam startBodyRam (gsTailPtr <$> gs) (gsWr <$> gs)

{- | Corpo do circuito, escrito no estilo "clock/reset/enable implícitos"
(idiomático em Clash) e depois exposto explicitamente em 'topEntity'.
-}
go ::
    forall dom.
    (HiddenClockResetEnable dom) =>
    ( Signal dom (Unsigned 4)
    , Signal dom (Unsigned 4)
    , Signal dom (Unsigned 4)
    , Signal dom Bool
    , Signal dom Bool
    , Signal dom Bool
    , Signal dom (BitVector 8)
    )
go = (vgaRedS, vgaGreenS, vgaBlueS, vgaHSyncS, vgaVSyncS, audioPwmS, ledS)
  where
    gs :: Signal dom GameState
    gs = gameSignal
    vga :: Signal dom VgaOut
    vga = vgaGen

    dead :: Signal dom Bool
    dead = isDead <$> gs
    prevDead :: Signal dom Bool
    prevDead = register False dead

    deadEvent :: Signal dom Bool
    deadEvent = (\d pd -> d && not pd) <$> dead <*> prevDead
    -- Usa o pulso gsAte vindo do próprio gameStep em vez de inferir o evento
    -- comparando a posição da maçã entre ciclos: essa comparação disparava
    -- um "beep" de comer falso tanto no power-on quanto a cada reinício
    -- pós game-over (a nova maçã aleatória quase sempre difere da antiga).
    eatEvent :: Signal dom Bool
    eatEvent = gsAte <$> gs

    audioSt :: Signal dom AudioState
    audioSt = register initAudio (audioStep <$> audioSt <*> eatEvent <*> deadEvent)
    audioOut :: Signal dom Bool
    audioOut = audioPin <$> audioSt

    blink :: Signal dom Bool
    blink = blinkGen
    -- cor, HSYNC e VSYNC já registrados e alinhados (pipeline de 2 ciclos)
    colorS :: Signal dom Rgb444
    vgaHSyncS, vgaVSyncS :: Signal dom Bool
    (colorS, vgaHSyncS, vgaVSyncS) = renderGen gs vga blink

    vgaRedS, vgaGreenS, vgaBlueS :: Signal dom (Unsigned 4)
    vgaRedS = rR <$> colorS
    vgaGreenS = rG <$> colorS
    vgaBlueS = rB <$> colorS
    audioPwmS :: Signal dom Bool
    audioPwmS = audioOut

    ledS :: Signal dom (BitVector 8)
    ledS = resize . pack . gsLen <$> gs

{- | Portas físicas: os nomes abaixo (via ANN Synthesize) precisam bater
EXATAMENTE com os usados no arquivo de constraints
(constraints/de10lite.qsf) — sem essa anotação o Clash nomeia as portas
por posição (ex.: "result_0", "result_1", ...) e o .qsf simplesmente não
encontra os pinos.

'Enable' não é exposto como porta física: a placa não tem um pino "en"
dedicado (nem faz sentido ter — nossa lógica deve ficar sempre habilitada),
então ele é amarrado internamente a 'enableGen' em vez de virar uma porta
de entrada solta e sem constraint no .qsf.
-}
{-# ANN
    topEntity
    ( Synthesize
        { t_name = "topEntity"
        , t_inputs = [PortName "clk", PortName "rst"]
        , t_output =
            PortProduct
                ""
                [ PortName "vgaRed"
                , PortName "vgaGreen"
                , PortName "vgaBlue"
                , PortName "vgaHSync"
                , PortName "vgaVSync"
                , PortName "audioPwm"
                , PortName "led"
                ]
        }
    )
    #-}
topEntity ::
    Clock Dom50 ->
    Reset Dom50 ->
    ( Signal Dom50 (Unsigned 4) -- vgaRed
    , Signal Dom50 (Unsigned 4) -- vgaGreen
    , Signal Dom50 (Unsigned 4) -- vgaBlue
    , Signal Dom50 Bool -- vgaHSync
    , Signal Dom50 Bool -- vgaVSync
    , Signal Dom50 Bool -- audioPwm
    , Signal Dom50 (BitVector 8) -- led (tamanho da cobra)
    )
topEntity clk rst = withClockResetEnable clk rst enableGen go
{-# NOINLINE topEntity #-}
