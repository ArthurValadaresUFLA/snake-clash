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
-- Domínio de clock: assume-se um clock de placa de 100MHz (comum em
-- Basys3/Nexys A7/Arty). Ajuste createDomain se sua placa usar outra
-- frequência, e os divisores em VGA.hs / Audio.hs / gameTickCycles abaixo.
-- ============================================================================
createDomain vSystem{vName = "Dom50", vPeriod = hzToPeriod 50_000_000}

-- Quantos movimentos de cobra por segundo. 6/s é um bom valor para
-- "ver" a IA pensando; aumente para algo mais frenético.
gameTickCycles :: Unsigned 26
gameTickCycles = 50_000_000 `div` 12

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
    gs = register (initGame 0xBEEF) (gameStep <$> gs <*> tickGen)

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

    prevPhase :: Signal dom Phase
    prevPhase = register Alive (gsPhase <$> gs)

    deadEvent :: Signal dom Bool
    deadEvent = (\p pp -> p == Dead && pp == Alive) <$> (gsPhase <$> gs) <*> prevPhase
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
    colorS :: Signal dom Rgb444
    colorS = pixelColor <$> gs <*> vga <*> blink

    vgaRedS, vgaGreenS, vgaBlueS :: Signal dom (Unsigned 4)
    vgaRedS = rR <$> colorS
    vgaGreenS = rG <$> colorS
    vgaBlueS = rB <$> colorS
    vgaHSyncS, vgaVSyncS, audioPwmS :: Signal dom Bool
    vgaHSyncS = vgaHSync <$> vga
    vgaVSyncS = vgaVSync <$> vga
    audioPwmS = audioOut

    ledS :: Signal dom (BitVector 8)
    ledS = (\gl -> resize (pack gl)) <$> (gsLen <$> gs)

{- | Portas físicas: os nomes abaixo (via ANN Synthesize) precisam bater
EXATAMENTE com os usados no arquivo de constraints (ver basys3.xdc) —
sem essa anotação o Clash nomeia as portas por posição (ex.: "result_0",
"result_1", ...) e o .xdc simplesmente não encontra os pinos.

'Enable' não é exposto como porta física: a placa não tem um pino "en"
dedicado (nem faz sentido ter — nossa lógica deve ficar sempre habilitada),
então ele é amarrado internamente a 'enableGen' em vez de virar uma porta
de entrada solta e sem constraint no .xdc.
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
