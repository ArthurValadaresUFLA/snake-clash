PROJ        := snake-clash
TOP         := Top
SRC_DIR     := src
VHDL_DIR    := vhdl-out
VERILOG_DIR := verilog-out

# Ajuste se o Clash/Cabal forem chamados de outra forma (ex.: stack run clash --)
CLASH       ?= clash
CABAL       ?= cabal
HS_SRC      := $(wildcard $(SRC_DIR)/*.hs)
VHDL_OUT    := $(VHDL_DIR)/$(TOP).topEntity/topEntity.vhdl
VERILOG_OUT := $(VERILOG_DIR)/$(TOP).topEntity/topEntity.v

# Na primeira execução (sem .ghc.environment.*), garante que o cabal
# resolva as dependências antes de chamar o Clash.
ifeq ($(wildcard .ghc.environment.*),)
CLASH_PREREQ := build
endif

.DEFAULT_GOAL := help
.PHONY: help build vhdl verilog check-reset lint fmt clean-verilog clean-vhdl clean

help:            ## Lista os alvos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  %-15s %s\n",$$1,$$2}'

build:           ## Compila a biblioteca e grava o ambiente GHC para o Clash
	$(CABAL) build --write-ghc-environment-files=always

vhdl: $(CLASH_PREREQ) $(VHDL_OUT)  ## Gera VHDL com o Clash

$(VHDL_OUT): $(HS_SRC) $(PROJ).cabal
	$(CLASH) -i$(SRC_DIR) $(SRC_DIR)/$(TOP).hs --vhdl -outputdir $(VHDL_DIR)

verilog: $(CLASH_PREREQ) $(VERILOG_OUT)  ## Gera o Verilog com o Clash
	@$(MAKE) --no-print-directory check-reset

$(VERILOG_OUT): $(HS_SRC) $(PROJ).cabal
	$(CLASH) -i$(SRC_DIR) $(SRC_DIR)/$(TOP).hs --verilog -outputdir $(VERILOG_DIR)

check-reset: $(VERILOG_OUT)  ## Falha se o Verilog gerado não usar reset ativo em baixo
	@if grep -qE 'posedge[[:space:]]+rst' $(VERILOG_OUT); then \
	  echo "ERRO: $(VERILOG_OUT) usa reset ativo em ALTO (posedge rst)."; \
	  echo "      Dom50 deve ser ActiveLow (KEY0 da DE10-Lite); rode 'make verilog'."; \
	  exit 1; \
	fi
	@grep -qE 'negedge[[:space:]]+rst' $(VERILOG_OUT) || { \
	  echo "ERRO: não encontrei 'negedge rst' em $(VERILOG_OUT)."; \
	  exit 1; \
	}
	@echo "OK: reset ativo em baixo (negedge rst) em $(VERILOG_OUT)"

lint:            ## Roda hlint
	hlint $(SRC_DIR)

fmt:             ## Formata o código Haskell
	fourmolu --mode inplace $(HS_SRC)

clean-vhdl:      ## Remove a saída do Clash para VHDL
	rm -rf $(VHDL_DIR)

clean-verilog:   ## Remove a saída do Clash para Verilog
	rm -rf $(VERILOG_DIR)

clean: clean-verilog clean-vhdl ## Remove todas as saídas do Clash
