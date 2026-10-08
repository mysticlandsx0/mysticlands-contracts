# Auditoria dos contratos de referência (Plant vs Undead)

Revisão manual feita em 2026-10-06 dos contratos nas pastas `PVU-SEED-NFT-master`, `PVU-LAND-NFT-master` e
`PVU-token-smartcontract-master`. **Não substitui uma auditoria profissional** antes de lançar na mainnet.

> Esses contratos **não fazem parte** deste repositório. Os contratos do MysticLands foram escritos do zero em
> [`contracts/`](../README.md) e a tabela "Security design" de lá mostra como cada item abaixo foi resolvido.

## Como funcionam

| Contrato | O que faz |
|---|---|
| `PvUToken` (PVUToken.sol, Solidity 0.5.17) | Token BEP20 com 300.000.000 unidades, todas criadas na carteira do dono no deploy. Tem queima (`burn`) e o dono pode **pausar todas as transferências**. Não existe mint depois do deploy. |
| `PlantCore` (Seed.sol, ^0.6.0) | NFT das plantas. `createPlant` cobra `price` em token e sorteia um `plantId` de uma lista (`rangeOfId`) que o dono preenche; o ID sai da lista ao ser sorteado. Também tem mint por "fazenda" (`createPlantFromFarm`), por pacote (`createBundlePlant`) e por "swap" (`mintPlantFromSwap`), cada um liberado para um endereço escolhido pelo dono. `burnPlant` queima a NFT e devolve `rate`% do preço atual. `createSaleAuction` coloca a NFT à venda no leilão. |
| `LandCore` (LandNFT.sol, ^0.6.0) | Mesma lógica da planta, para terrenos (`createLand`, `createBundleLand`). |
| `FarmBundle` (FarmBundle.sol) | Vende pacotes: 2.999 tokens = 21 plantas + 1 terreno; 10.000 tokens = 88 plantas + 3 terrenos. |
| `SaleClockAuction` (SaleClockAuction.sol / SaleLand.sol) | Marketplace em formato de leilão com preço que varia no tempo. A NFT fica em custódia no contrato; quem compra paga em token, o vendedor recebe o valor menos a taxa (`ownerCut`) e o dono saca as taxas acumuladas. |

## Problemas encontrados

### Críticos
1. **Sorteio previsível e manipulável** (`_randomPlantId`, `_randomSeedFarm`, `_randomLandId`).
   `blockhash(block.number)` sempre retorna 0; sobram só `block.timestamp` e um `nonce`, ambos públicos.
   Um contrato atacante pode chamar `createPlant`, ver qual planta saiu e **reverter a transação se não for rara**,
   repetindo até conseguir a NFT que quer, pagando só o gás. Correção: Chainlink VRF (sorteio em duas etapas:
   pedido e revelação, que combina com a mecânica de semente do jogo).
2. **Mint ilimitado nas mãos do dono.** `mintPlantFromSwap` cria qualquer planta, sem limite, para o endereço
   `swapAddress`; `createPlantFromFarm` e `createBundle*` idem para `farmAddr`/`bundleAddr`. Como o dono escolhe
   esses endereços, ele pode apontá-los para a própria carteira e criar NFTs raras de graça. Correção: limites de
   supply, papéis separados (AccessControl), carteira multisig (Safe) e timelock.

### Altos
3. **Leilão com preço decrescente nunca funciona** (`_computeCurrentPrice`): `_endingPrice.sub(_startingPrice)`
   com SafeMath reverte quando o preço final é menor que o inicial (o caso normal), então ninguém consegue comprar
   até o fim da duração.
4. **Pausa não bloqueia compras:** `SaleClockAuction.bid` sobrescreve a função sem `whenNotPaused`.
5. **`ClockAuction.bid` (versão base) não cobra pagamento:** se o contrato errado for publicado, qualquer pessoa leva
   NFTs de graça usando o saldo do contrato. O `SaleClockAuction` corrige isso, mas o risco existe no código.
6. **Bug em `LandCore.addLandId`:** grava `i` em vez de `_landId[i]`; os IDs de terreno cadastrados ficam errados.
7. **Token congelável:** o dono pode pausar todas as transferências de todos os usuários. Scanners e corretoras
   costumam marcar isso como risco.
8. **Taxa do marketplace alterável a qualquer momento até 100%** (`changeCut`), inclusive com vendas abertas.
9. **Endereços fixos da BSC sem como alterar** em `FarmBundle` (`tokenAddress`, `plantNFTAddress`, `landNFTAddress`)
   e no token de pagamento dos outros contratos: não funcionam na Polygon sem reescrever.

### Médios
10. Transferências de token sem `SafeERC20`; o reembolso de `burnPlant` ignora falhas e depende do saldo do contrato,
    que o dono pode sacar inteiro com `withdrawBalance`.
11. Compiladores antigos (0.5.17 e 0.6.x) e cópia manual e modificada do ERC721 do OpenZeppelin.
12. Uma única chave de dono controla tudo (sem multisig e sem timelock).
13. `createPlant` aceita pagamento acima do preço sem devolver a diferença.
14. Pacote de 88 plantas cunhadas num único loop: transação muito cara em gás.

### Informativos
- A lista de IDs restantes é pública (`getRangeId`), o que, junto com o sorteio previsível, facilita a manipulação.
- O nome do token ainda é "Plant vs Undead Token" e há comentários de outra rede (KAI).
- A NFT só guarda `plantId` e data de nascimento; tipo, raridade e atributos ficam fora da blockchain.

## Recomendação

**Não reaproveitar esses contratos.** Reescrever para o MysticLands com:
- Solidity 0.8.x + OpenZeppelin 5 (ERC20, ERC721, AccessControl, Pausable só para emergência, SafeERC20).
- Chainlink VRF v2.5 para sementes, caixas e pacotes.
- Marketplace de preço fixo (listar, cancelar, comprar) com taxa máxima fixa no código.
- Supply máximo por tipo de NFT, papéis separados e carteira multisig (Safe) com timelock para funções de admin.
- Testes automatizados (Hardhat ou Foundry), deploy primeiro na **Polygon Amoy** (testnet) e auditoria externa antes
  da mainnet.
