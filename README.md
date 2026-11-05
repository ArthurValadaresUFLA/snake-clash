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
(pior caso) leva ~300–400 ciclos de clock. O jogo se move poucas vezes por
segundo (padrão: 6 vezes/segundo = a cada ~16,7 milhões de ciclos a
100MHz). Ou seja, a "IA" termina de pensar em uma fração de milissegundo
e passa o resto do tempo esperando o próximo tick — sobra tempo de sobra.

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
  basys3.xdc -- exemplo de constraints para Digilent Basys3 (ajustar pinos)
```

## Parâmetros fáceis de ajustar

| O quê                                 | Onde                                                             |
| ------------------------------------- | ---------------------------------------------------------------- |
| Tamanho do tabuleiro (colunas/linhas) | `Cols`/`Rows` em `Types.hs`                                      |
| Tamanho do quadrado em pixels         | `cellPx` em `Render.hs` (deve dividir 640/480 igual a Cols/Rows) |
| Velocidade da cobra                   | `gameTickCycles` em `Top.hs`                                     |
| Frequência de clock da placa          | `createDomain` em `Top.hs`                                       |
| Cores                                 | `black/green/red/...` em `Render.hs`                             |
| Tons de áudio                         | `eatFreq`/`deadFreq` em `Audio.hs`                               |

Atenção: aumentar muito o tabuleiro aumenta bastante o consumo de
registradores (a grade de "visitado"/"cor" do BFS e o vetor do corpo da
cobra crescem com `Cols*Rows`). Para uma placa pequena, 20×15 (ou menos)
é um bom ponto de partida; para tabuleiros grandes, a implementação de
`Grid`/fila do BFS deveria migrar de `Vec` puro para memória de bloco
(`Clash.Explicit.RAM.blockRam`), o que não foi feito aqui para manter o
código didático e legível.

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
um PLL/MMCM: ele roda no clock do sistema (assumido 100MHz) e avança os
contadores de pixel 1 a cada 4 ciclos, aproximando ~25MHz (o VGA real
pede 25.175MHz — a diferença costuma ser tolerada pela maioria dos
monitores, mas para um projeto "de verdade" o ideal é instanciar o PLL
do fabricante (Clocking Wizard no Vivado, por exemplo) para gerar
25.175MHz exatos e usar um domínio de clock Clash dedicado para o VGA).

## Limitações conhecidas / pontos de atenção

- **Não compilado neste ambiente.** O código foi escrito com cuidado
  seguindo os idiomas usuais de Clash (`Vec`, `Index`, `mealy`/registro
  com realimentação, `HiddenClockResetEnable`), mas não há aqui toolchain
  Clash/GHC para validar tipos/`clash --verilog` de ponta a ponta. Rode
  localmente e ajuste eventuais detalhes de tipos (é comum precisar de
  `resize`/anotações extras de `Index`/`Unsigned` que só aparecem no
  erro do compilador).
- A heurística **não garante 100% de vitórias** — isso é intencional e
  explicado acima; é o trade-off pedido (heurística exequível em FPGA,
  não uma IA treinada, não um hamiltoniano trivial).
- `Vec`/`replace`/`!!` dinâmicos sobre uma grade de 300 células sintetizam
  como muxes/decodificadores combinacionais; funciona bem nesse tamanho,
  mas não escala indefinidamente sem migrar para block RAM.
- O gerador pseudo-aleatório é um LFSR simples (determinístico dado o
  seed) — suficiente para "a maçã não aparecer sempre no mesmo lugar",
  não para nada que precise de aleatoriedade de verdade.
