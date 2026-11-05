# ==============================================================================
# Constraints de timing para a DE10-Lite (TimeQuest / Quartus).
# Equivalente ao 'create_clock' que, no Vivado, ficava dentro do próprio
# .xdc — no Quartus isso é convencionalmente um arquivo .sdc separado.
#
# 50MHz -> período de 20ns. NÃO confundir com os 10ns (100MHz) do
# basys3.xdc original.
# ==============================================================================

create_clock -name clk -period 20.000 [get_ports {clk}]

derive_pll_clocks
derive_clock_uncertainty
