{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoStarIsType #-}
{-# OPTIONS_GHC -fplugin=GHC.TypeLits.Extra.Solver -fplugin=GHC.TypeLits.Normalise -fplugin=GHC.TypeLits.KnownNat.Solver #-}

module VGA (
    VgaOut (..),
    vgaGen,
) where

import Clash.Prelude

-- ============================================================================
-- Temporização VGA 640x480 @ ~60Hz, pixel clock ~25.175MHz.
--
-- SIMPLIFICAÇÃO DIDÁTICA: em vez de exigir um domínio de clock separado
-- (via PLL/MMCM do fabricante — normalmente necessário numa placa real,
-- ver README), este módulo roda no MESMO clock do sistema e só faz os
-- contadores de pixel avançarem 1 a cada N ciclos, aproximando ~25MHz.
-- Isso é uma técnica comum em projetos didáticos de VGA em FPGA; para
-- produção, prefira um PLL real (25.175MHz exato) para evitar bater na
-- tolerância dos monitores.
--
-- N depende do clock do sistema: /4 para 100MHz (Basys3/Nexys), /2 para
-- 50MHz (DE10-Lite e outras placas Intel/MAX10). Este arquivo está
-- configurado para /2 (50MHz) — se portar para uma placa de 100MHz,
-- troque vsDiv para Unsigned 2 e as comparações abaixo para 3.
-- ============================================================================

hVisible, hFront, hSync, hBack, hTotal :: Unsigned 10
hVisible = 640
hFront = 16
hSync = 96
hBack = 48
hTotal = hVisible + hFront + hSync + hBack -- 800

vVisible, vFront, vSync, vBack, vTotal :: Unsigned 10
vVisible = 480
vFront = 10
vSync = 2
vBack = 33
vTotal = vVisible + vFront + vSync + vBack -- 525

data VgaOut = VgaOut
    { vgaHCount :: Unsigned 10 -- posição horizontal do pixel atual (0..799)
    , vgaVCount :: Unsigned 10 -- posição vertical do pixel atual   (0..524)
    , vgaHSync :: Bool -- ativo em nível baixo (True = pulso de sync)
    , vgaVSync :: Bool
    , vgaVisible :: Bool -- True quando (hCount,vCount) está na área visível
    , vgaPixelEn :: Bool -- pulso de 1 ciclo: "esse é um pixel novo"
    }
    deriving (Generic, NFDataX)

data VgaState = VgaState
    { vsDiv :: Unsigned 1 -- divisor de clock (0..1) -> gera pixelEn 1/2 do tempo (50MHz -> ~25MHz)
    , vsH :: Unsigned 10
    , vsV :: Unsigned 10
    }
    deriving (Generic, NFDataX)

initVga :: VgaState
initVga = VgaState 0 0 0

vgaStep :: VgaState -> VgaState
vgaStep st
    | vsDiv st /= 1 = st{vsDiv = vsDiv st + 1}
    | otherwise =
        let h' = if vsH st == hTotal - 1 then 0 else vsH st + 1
            v' =
                if vsH st == hTotal - 1
                    then (if vsV st == vTotal - 1 then 0 else vsV st + 1)
                    else vsV st
         in st{vsDiv = 0, vsH = h', vsV = v'}

toOut :: VgaState -> VgaOut
toOut st =
    VgaOut
        { vgaHCount = vsH st
        , vgaVCount = vsV st
        , vgaHSync = not (vsH st >= hVisible + hFront && vsH st < hVisible + hFront + hSync)
        , vgaVSync = not (vsV st >= vVisible + vFront && vsV st < vVisible + vFront + vSync)
        , vgaVisible = vsH st < hVisible && vsV st < vVisible
        , vgaPixelEn = vsDiv st == 1
        }

{- | Instancie dentro de um bloco com domínio de clock/reset implícito
(HiddenClockResetEnable) para obter o sinal de saída.
-}
vgaGen :: forall dom. (HiddenClockResetEnable dom) => Signal dom VgaOut
vgaGen = toOut <$> st
  where
    st :: Signal dom VgaState
    st = register initVga (vgaStep <$> st)
