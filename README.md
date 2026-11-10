# Snake auto-jogável em Clash (VGA + áudio)

Jogo da cobrinha descrito em Haskell/Clash, sintetizável para Verilog/VHDL,
que **se joga sozinho**: a cada movimento, um pequeno mecanismo de busca em
hardware decide a próxima direção. Sem gráficos sofisticados — cada célula
do tabuleiro é um quadrado sólido de cor (fundo preto, corpo verde, cabeça
branca, maçã vermelha).

## Por que não um caminho hamiltoniano?

Um ciclo hamiltoniano fixo (a cobra percorre uma rota que visita todas as
células, sempre na mesma ordem) _sempre_ vence o jogo, mas é uma solução
enganosa: ignora completamente onde está a maçã, é previsível e extremamente
lento (na pior das hipóteses, percorre o tabuleiro inteiro para comer uma
maçã que está ao lado da cabeça). Não é isso que se pede quando se fala em
"a cobra se direciona para a maçã".

## A heurística usada (sem treinar nenhuma IA)

Implementada em `src/BFS.hs`. A cada movimento:

1. A partir da cabeça, olhamos as até 4 células vizinhas livres
   (Norte/Leste/Sul/Oeste). Cada uma vira uma "semente" com uma cor
   (a própria direção).
2. Fazemos **uma única busca em largura (BFS) multi-fonte**, simultânea, a
   partir dessas sementes, por todo o tabuleiro livre (paredes e corpo da
   cobra são obstáculos). Cada célula nova herda a cor de quem chegou
   primeiro — como BFS expande em camadas, isso ainda corresponde à menor
   distância a partir de cada vizinho inicial.
3. Durante a busca guardamos, por cor: (a) quantas células aquela cor
   alcançou (tamanho da região) e (b) se a **maçã** foi alcançada por ela.
4. Decisão:
   - se alguma cor alcançou a maçã → anda nessa direção (é o primeiro
     passo de um caminho mais curto até a maçã);
   - senão (maçã cercada/inalcançável dado o formato atual do corpo) →
     anda na direção cuja região tem **mais espaço livre** (flood fill /
     maximizar área aberta — a heurística clássica de sobrevivência de IAs
     de Snake, que evita o erro mais comum de perseguir a maçã cegamente
     e se prender num corredor sem saída).

Isso é, na prática, o mesmo tipo de heurística usada em implementações
populares de "Snake AI" (BFS até o alvo + flood-fill como critério de
desempate/sobrevivência). **Não garante resolver 100% das partidas**: à
medida que a cobra ocupa a maior parte do tabuleiro, mesmo maximizar
espaço pode não evitar um encurralamento eventual — isso exigiria algo
como um ciclo hamiltoniano _adaptativo_ (bem mais caro/complexo) ou uma
IA de fato treinada, o que foge do escopo de "heurística executável em
FPGA". Na prática, essa heurística vence a esmagadora maioria das
partidas antes de eventualmente se encurralar quando a cobra já está bem
grande — e é isso que se observa no vídeo: movimento visivelmente
direcionado, não uma rota fixa decorada.

### Por que é viável em hardware

O tabuleiro é pequeno (20×15 = 300 células por padrão). A busca inteira
(pior caso) leva cerca de 120 mil ciclos de clock (aproximadamente 2,4 ms a
50 MHz). O jogo se move 12 vezes por segundo (padrão: `gameTickCycles =
4_166_667` a 50 MHz, ou seja, cerca de 83 ms entre movimentos). Ou seja, a
"IA" termina de pensar em poucos milissegundos e passa o resto do tempo
esperando o próximo tick — sobra tempo de sobra.

## Estrutura do projeto

```text
snake-clash.cabal
src/
  Types.hs   -- tabuleiro, coordenadas, direções, tipos genéricos de grade
  LFSR.hs    -- gerador pseudo-aleatório (posição da maçã)
  BFS.hs     -- o "cérebro": busca multi-fonte + flood-fill (heurística de IA)
  Snake.hs   -- estado do jogo: movimento, colisão, crescer, maçã, game over
  VGA.hs     -- temporização VGA 640x480@60Hz
  Render.hs  -- pixel -> cor (sem gráficos, blocos sólidos)
  Audio.hs   -- beep (onda quadrada) ao comer maçã / morrer
  Top.hs     -- entidade de topo, liga tudo, expõe os pinos físicos
constraints/
  de10lite.qsf -- pinos e configuração da Terasic DE10-Lite (Quartus)
  de10lite.sdc -- constraints de timing (clock de 50 MHz)
```

## Parâmetros fáceis de ajustar

| O quê                                 | Onde                                                                           |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| Tamanho do tabuleiro (colunas/linhas) | `Cols`/`Rows` em `Types.hs`                                                    |
| Tamanho da célula em pixels           | 32×32 (shift de 5 bits em `Render.hs`; deve dividir 640/480 por `Cols`/`Rows`) |
| Velocidade da cobra                   | `gameTickCycles` em `Top.hs`                                                   |
| Frequência de clock da placa          | `createDomain` em `Top.hs`                                                     |
| Cores                                 | `black/green/red/...` em `Render.hs`                                           |
| Tons de áudio                         | `eatHalf`/`deadHalf` e `eatDurationCycles`/`deadDurationCycles` em `Audio.hs`  |

Atenção: aumentar muito o tabuleiro aumenta bastante o consumo de
registradores (a grade de "visitado"/"cor" do BFS e o vetor do corpo da
cobra crescem com `Cols*Rows`). Para uma placa pequena, 20×15 (ou menos)
é um bom ponto de partida; para tabuleiros grandes, as grades do BFS
(`Cells`) deveriam migrar de `Vec` puro para memória de bloco
(`Clash.Explicit.RAM.blockRam`). O corpo da cobra já usa block RAM em
`Top.hs`; a busca não, para manter o código didático e legível.

## Build e simulação

Este projeto segue o layout padrão dos "clash-starters": uma `library` que
depende de `clash-prelude`. **O compilador Clash em si (`clash-ghc`) não é
uma dependência desse `.cabal` nem um alvo de `cabal run` deste projeto** —
ele é uma ferramenta separada, instalada globalmente, parecida com o
próprio GHC. É por isso que `cabal run -- clash ...` falha com
"it is not in this project": não existe executável `clash` declarado
em `snake-clash.cabal`.

### Passo 1 — instalar o compilador Clash (uma vez só, globalmente)

```bash
cabal update
cabal install clash-ghc --overwrite-policy=always
```

Isso instala um binário `clash` (tipicamente em `~/.cabal/bin` ou
`~/.local/state/cabal/bin`, dependendo da versão do cabal). Garanta que
esse diretório esteja no seu `PATH`:

```bash
export PATH="$HOME/.cabal/bin:$PATH"
clash --version   # deve funcionar de qualquer diretório agora
```

(Alternativas: `ghcup` também consegue instalar `clash-ghc`; ou usar o
Nix/Docker oficial do projeto Clash, que evita todo esse passo — ver
<https://clash-lang.org/>.)

### Passo 2 — resolver as dependências do projeto (uma vez por projeto)

```bash
cd snake-clash
cabal build --write-ghc-environment-files=always
```

Isso baixa/compila `clash-prelude` e os plugins de resolução de tipos
(`ghc-typelits-natnormalise`, `ghc-typelits-extra`,
`ghc-typelits-knownnat` — o Clash precisa deles para provar igualdades
como `Rows * Cols` em tipos) e, mais importante, **grava um arquivo de
ambiente do GHC** (`.ghc.environment.*`) na pasta do projeto. É esse
arquivo que faz o `clash`, quando chamado diretamente no próximo passo,
enxergar essas dependências — sem ele, dá exatamente o erro
`Could not find module 'GHC.TypeLits.KnownNat.Solver'`, porque o `clash`
não tem como saber, sozinho, quais pacotes o seu `.cabal` pede.

(Se sua versão do `cabal` já escreve esse arquivo por padrão, o flag
`--write-ghc-environment-files=always` é inofensivo; inclua-o sempre
para não depender da configuração local.)

### Passo 3 — gerar Verilog/VHDL

De dentro da mesma pasta (para o `clash` continuar enxergando o arquivo
de ambiente gerado no passo anterior):

```bash
clash -isrc src/Top.hs --verilog -outputdir verilog-out
# ou, para VHDL:
clash -isrc src/Top.hs --vhdl -outputdir vhdl-out
```

`-isrc` diz ao Clash/GHC onde procurar os módulos do projeto (`Types`,
`BFS`, `Snake`, etc.).

Se estiver usando o `Makefile`, os mesmos passos viram:

```bash
make build    # Passo 2: cabal build + .ghc.environment.*
make verilog  # gera em verilog-out/
make vhdl     # gera em vhdl-out/
```

O `make` chama `cabal build` automaticamente na primeira vez (quando ainda
não existe `.ghc.environment.*`) e usa os arquivos gerados em
`verilog-out/`/`vhdl-out/` como alvos, então só regenera quando o código
muda. `make clean` remove as duas saídas.

Se preferir manter tudo dentro do fluxo do `cabal` (sem instalar nada
globalmente), a alternativa é adicionar `clash-ghc` como pacote do
`cabal.project` deste repositório e então usar
`cabal run clash -- --verilog src/Top.hs -isrc`; isso funciona, mas é
mais lento (o `cabal` reconstrói o compilador Clash inteiro na primeira
vez) e mais sensível a combinações de versões — por isso a instalação
global do Passo 1 é o caminho recomendado para começar.

### Passo 4 — simular a lógica pura (sem gerar hardware)

Útil para depurar `BFS`/`Snake` isoladamente, sem VGA nem síntese:

```bash
cabal repl   # aqui sim é o cabal normal, carregando a library deste projeto
ghci> import Snake
ghci> import BFS
-- inspecione gameStep/bfsStep aplicando manualmente sobre um GameState
```

### Sobre o clock de pixel

Para simplicidade, `VGA.hs` **não** usa um domínio de clock separado nem
um PLL/MMCM: ele roda no clock do sistema (50MHz na DE10-Lite) e avança os
contadores de pixel 1 a cada 2 ciclos, aproximando ~25MHz (o VGA real
pede 25.175MHz — a diferença costuma ser tolerada pela maioria dos
monitores, mas para um projeto "de verdade" o ideal é instanciar o PLL
do fabricante (Clocking Wizard no Quartus, por exemplo) para gerar
25.175MHz exatos e usar um domínio de clock Clash dedicado para o VGA).

## Síntese no Quartus (DE10-Lite)

O projeto usa o fluxo **Verilog** do Clash. O `constraints/de10lite.qsf` já
declara os dois arquivos necessários (`VERILOG_FILE` apontando para
`../verilog-out/Top.topEntity/topEntity.v` e `SDC_FILE de10lite.sdc`),
assumindo que o `.qpf` fica na pasta `constraints/`. Se o seu projeto
estiver em outro diretório, ajuste esses caminhos (ou adicione os arquivos
pelo GUI em _Project > Add/Remove Files_).

Sempre regenere o HDL com `make verilog` antes de compilar — **não** use
saídas antigas de `build/`. O `make verilog` termina com `make check-reset`,
que falha se o Verilog gerado usar reset ativo em alto (`posedge rst`);
com `Dom50` em `ActiveLow` (KEY0 da DE10-Lite) o correto é `negedge rst`.

Diagnóstico rápido se o monitor mostrar "sem sinal":

- **LEDs**: `led` mostra `gsLen` em binário (começa em 3, `LEDR0`+`LEDR1`
  acesos) e deve **aumentar** em segundos conforme a cobra come maçãs. Se
  ficar parado em 3, o design não está rodando (reset preso ou clock morto),
  não é problema do monitor.
- **HSync (pino N3)**: deve oscilar em ~31,25kHz. Nível fixo em 3,3V indica
  reset assertado (o pipeline mantém HS/VS inativos durante o reset).
- **Timing Analyzer > Clocks**: `clk` deve aparecer com período de 20ns.

## Limitações conhecidas / pontos de atenção

- **Validado localmente com GHC 9.10.3 + Clash.** O projeto compila
  (`cabal build`) e gera HDL (`make verilog`/`make vhdl`); ao alterar
  parâmetros de tipo (`Cols`, `Rows`, etc.), rode novamente e ajuste
  eventuais `resize`/anotações extras de `Index`/`Unsigned` que só
  aparecem no erro do compilador.
- A heurística **não garante 100% de vitórias** — isso é intencional e
  explicado acima; é o trade-off pedido (heurística exequível em FPGA,
  não uma IA treinada, não um hamiltoniano trivial).
- `Vec`/`replace`/`!!` dinâmicos sobre uma grade de 300 células sintetizam
  como muxes/decodificadores combinacionais; funciona bem nesse tamanho,
  mas não escala indefinidamente sem migrar para block RAM.
- O gerador pseudo-aleatório é um LFSR simples (determinístico dado o
  seed) — suficiente para "a maçã não aparecer sempre no mesmo lugar",
  não para nada que precise de aleatoriedade de verdade.
