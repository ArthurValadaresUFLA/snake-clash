PROJ        := snake-clash
TOP         := Top
SRC_DIR     := src
BUILD_DIR   := build
HDL_DIR     := $(BUILD_DIR)/vhdl
VERILOG_DIR := $(BUILD_DIR)/verilog
SOF         := output_files/$(PROJ).sof

# Ajuste se o Clash for chamado de outra forma (ex.: stack run clash --)
CLASH    ?= clash
HS_SRC   := $(wildcard $(SRC_DIR)/*.hs)
VHDL_OUT := $(HDL_DIR)/$(TOP).topEntity/topEntity.vhdl

.DEFAULT_GOAL := help
.PHONY: help vhdl bitstream program lint fmt clean-verilog clean-vhdl clean

help:            ## Lista os alvos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  %-15s %s\n",$$1,$$2}'

vhdl: $(VHDL_OUT)  ## Gera VHDL com o Clash

$(VHDL_OUT): $(HS_SRC) $(PROJ).cabal
	$(CLASH) -i$(SRC_DIR) $(SRC_DIR)/$(TOP).hs --vhdl -outputdir $(HDL_DIR)

verilog: $(VERILOG_DIR)  ## Gera o Verilog com o Clash

$(VERILOG_DIR): $(HS_SRC) $(PROJ).cabal
	$(CLASH) -i$(SRC_DIR) $(SRC_DIR)/$(TOP).hs --verilog -outputdir $(VERILOG_DIR)

lint:            ## Roda hlint
	hlint $(SRC_DIR)

fmt:             ## Formata o código Haskell
	fourmolu --mode inplace $(HS_SRC)

clean-vhdl:      ## Remove saída do Clash para VHDL
	rm -rf $(HDL_DIR)

clean-verilog:   ## Remove saída do Clash para Verilog
	rm -rf $(VERILOG_DIR)

clean: clean-verilog clean-vhdl ## Remove todas as saídas do Clash
