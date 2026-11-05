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

module Audio (
    AudioState,
    initAudio,
    audioStep,
    audioPin,
) where

import Clash.Prelude

-- ============================================================================
-- Áudio minimalista: um único pino digital ligado a um alto-falante/buzzer
-- (com um resistor em série, ou um Pmod de áudio simples) tocando uma onda
-- quadrada. Dois eventos de 1 ciclo disparam um "beep":
--   * ateApple  -> tom agudo curto
--   * died      -> tom grave um pouco mais longo
-- Fora isso, o pino fica em silêncio (nível baixo constante).
-- Assumindo clock de 100MHz.
-- ============================================================================

clkHz :: Unsigned 32
clkHz = 50_000_000

toneHalfPeriod :: Unsigned 32 -> Unsigned 32
toneHalfPeriod freqHz = clkHz `div` (2 * freqHz)

eatFreq, deadFreq :: Unsigned 32
eatFreq = 1200
deadFreq = 220

eatDurationCycles, deadDurationCycles :: Unsigned 32
eatDurationCycles = clkHz `div` 12 -- ~83ms
deadDurationCycles = clkHz `div` 3 -- ~333ms

data AudioState = AudioState
    { asActive :: Bool
    , asHalfPer :: Unsigned 32
    , asRemain :: Unsigned 32 -- ciclos restantes de tom
    , asToggleAt :: Unsigned 32 -- contador até o próximo toggle da onda quadrada
    , asOut :: Bool
    }
    deriving (Generic, NFDataX)

initAudio :: AudioState
initAudio = AudioState False (toneHalfPeriod eatFreq) 0 0 False

-- | eatEvent/deadEvent devem ser pulsos de exatamente 1 ciclo de clock.
audioStep :: AudioState -> Bool -> Bool -> AudioState
audioStep st eatEvent deadEvent
    | deadEvent = start deadFreq deadDurationCycles
    | eatEvent = start eatFreq eatDurationCycles
    | not (asActive st) = st{asOut = False}
    | asRemain st == 0 = st{asActive = False, asOut = False}
    | asToggleAt st == 0 =
        st
            { asOut = not (asOut st)
            , asToggleAt = asHalfPer st
            , asRemain = asRemain st - 1
            }
    | otherwise =
        st
            { asToggleAt = asToggleAt st - 1
            , asRemain = asRemain st - 1
            }
  where
    start freq dur = AudioState True (toneHalfPeriod freq) dur (toneHalfPeriod freq) False

audioPin :: AudioState -> Bool
audioPin = asOut
