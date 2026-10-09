# MysticLands Smart Contracts

[![Game](https://img.shields.io/badge/game-mysticlands.online-2ea44f?style=flat-square)](https://mysticlands.online)
[![Network](https://img.shields.io/badge/network-Polygon%20mainnet-8247e5?style=flat-square&logo=polygon&logoColor=white)](https://polygonscan.com)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636?style=flat-square&logo=solidity)](https://soliditylang.org)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5-4e5ee4?style=flat-square&logo=openzeppelin&logoColor=white)](https://openzeppelin.com/contracts)
[![Chainlink](https://img.shields.io/badge/Chainlink-VRF%20v2.5%20%2B%20POL%2FUSD-375bd2?style=flat-square&logo=chainlink&logoColor=white)](https://docs.chain.link)
[![Tests](https://img.shields.io/badge/tests-38%20passing-brightgreen?style=flat-square)](test)
[![License](https://img.shields.io/badge/license-BUSL--1.1-blue?style=flat-square)](LICENSE)

Solidity contracts behind [MysticLands](https://mysticlands.online), an NFT farming game on **Polygon**.
Inside the game everything runs on **Light Energy (LE)**; outside it, on **POL**.

The source is public so that players, auditors and partners can verify exactly what runs on-chain.
This repository only contains the contracts the game uses today.

> **Status:** live on Polygon mainnet, source verified on Polygonscan, unit-tested (including attack tests), **not externally audited yet**.

## Deployed contracts (Polygon mainnet, chainId 137)

| Contract | Address |
|---|---|
| [`MysticPlant`](src/MysticPlant.sol) | [`0xCa9d11FED6AE3648995debcD1370E6410CFa4353`](https://polygonscan.com/address/0xCa9d11FED6AE3648995debcD1370E6410CFa4353) |
| [`MysticLand`](src/MysticLand.sol) | [`0xC4C3f702CBf10397f54Ec124A8e0cABbd763D632`](https://polygonscan.com/address/0xC4C3f702CBf10397f54Ec124A8e0cABbd763D632) |
| [`MysticNftShop`](src/MysticNftShop.sol) | [`0x2AeFDD1ed933cdB85c640F44A00a795e910522a4`](https://polygonscan.com/address/0x2AeFDD1ed933cdB85c640F44A00a795e910522a4) |
| [`MysticMarketPol`](src/MysticMarketPol.sol) | [`0x7F73A683a7f58FE33e4f3aFc27Ade3b71d1C3d0E`](https://polygonscan.com/address/0x7F73A683a7f58FE33e4f3aFc27Ade3b71d1C3d0E) |
| [`MysticRewardPool`](src/MysticRewardPool.sol) | [`0xE4BB51b46595a982dc6851525dD492bC155Cddba`](https://polygonscan.com/address/0xE4BB51b46595a982dc6851525dD492bC155Cddba) |
| [`MysticRevenueSplitter`](src/MysticRevenueSplitter.sol) | [`0xF5E7aEBe00ec396d2aE9933D326410c6cC952390`](https://polygonscan.com/address/0xF5E7aEBe00ec396d2aE9933D326410c6cC952390) |
| [`MysticLEShop`](src/MysticLEShop.sol) | [`0x57a6f6e3A1a9F73503cD225BCCeF69800C52EdCf`](https://polygonscan.com/address/0x57a6f6e3A1a9F73503cD225BCCeF69800C52EdCf) |

Owner of all contracts: `0xba7ee74892A8AEa45a64e3ce611B96a136D59352` · Treasury: `0x428333A2a4cb5ed98298f2bD1eaEf9FFbDdF7dCF`

## What each contract does

| Contract | Standard | Role |
|---|---|---|
| `MysticPlant` | ERC-721 | Plant (species 0-39) and Mother Tree (species 90-93) NFTs. Species, variant, rarity and DNA stored on-chain. Capped supply. |
| `MysticLand` | ERC-721 | Land NFTs on a 201 × 201 map. Every cell can only be owned once. Capped at 10,000 lands. |
| `MysticNftShop` | Chainlink VRF v2.5 + Data Feed | Sells seeds, starter kits, lands and bundles for POL. Prices are set in US dollars and charged in POL through the Chainlink POL/USD feed. Seeds **germinate for 24 hours before anything is drawn**: the purchase only records the order and `germinate()` asks Chainlink VRF for the random word afterwards, so nobody can know the result early, not even by reading the chain. NFTs are minted on `claim`. Mother Trees are never sold directly: each seed has a 1% chance (`motherBps`). Seeds earned in the game are redeemed with server-signed vouchers (EIP-712, daily limit). |
| `MysticMarketPol` | — | Fixed-price, non-custodial marketplace paid in POL. Fee capped at 10% and locked per listing. If a seller's wallet refuses POL, the amount is held for the seller to `withdraw`. |
| `MysticRevenueSplitter` | — | Every POL payment from the shops and the marketplace lands here and is split on arrival: 60% treasury / 40% Reward Pool (pool share bounded between 20% and 60%). Holds nothing. |
| `MysticRewardPool` | EIP-712 | Holds the POL used for in-game rewards. Players exchange LE for POL with a claim signed by the game server. At most `dailyBps` of the balance (1%, never above 5%) can be paid per UTC day, plus a per-wallet daily limit. |
| `MysticLEShop` | Chainlink Data Feed | Players buy LE (in-game currency) with POL. Price per 10,000 LE set in US dollars. POL goes to the splitter. |
| `GameNFT` | — | Shared base: supply cap, `MINTER_ROLE`, irreversible `freezeMinters()`. |

```
 Player ── POL ──► MysticNftShop ── 24h ──► germinate() ──► Chainlink VRF ──► claim() ──► MysticPlant / MysticLand
   │                     │
   ├── POL ──► MysticLEShop                 (all POL payments)
   │                     │                         │
   └── POL ──► MysticMarketPol (5% fee) ───────────┤
                                                   ▼
                                       MysticRevenueSplitter
                                        60% │          │ 40%
                                            ▼          ▼
                                        Treasury   MysticRewardPool ──► LE → POL rewards (server-signed claims)
```

## Rewards are variable and limited by the Pool

The Reward Pool only pays out what it holds, never more than 1% of its balance per day, with a per-wallet cap.
When demand is high, the game server lowers the LE → POL rate for the next day. Rewards can decrease or stop.
MysticLands is a game: nothing here is an investment or a promise of gains.

## Security design

| Risk | How MysticLands handles it |
|---|---|
| Predictable randomness lets attackers pick rare NFTs | Chainlink VRF v2.5 with request → fulfil → claim. Late or duplicate answers are ignored; buyers can retry after 24 h. |
| Owner mints unlimited rare NFTs | Only game shops hold `MINTER_ROLE`; supply caps; `freezeMinters()` locks minters forever. |
| Wrong prices from a stale oracle | Purchases revert on stale (> 1 day) or invalid Chainlink answers. |
| Marketplace fee changed for open sales | Hard cap of 10% and fee locked into each listing. |
| Seller blocks purchases by refusing POL | Payment is held in the contract for the seller to withdraw. |
| Reentrancy on purchases | `ReentrancyGuard` on every payable entry point (covered by attack tests). |
| Reward Pool drained in one day | Daily budget fixed at the first claim of the day (max 5% in code), per-wallet limit, single-use nonces, expiring EIP-712 signatures. |
| Stolen owner key empties the Pool | `emergencyWithdraw` can only send to the treasury fixed at deployment (immutable). Moving the Pool elsewhere needs a public 7-day notice. |

### Owner powers

- **NFT Shop:** prices, products, Mother Tree chance (max 10%), treasury, VRF config, voucher signer, pause.
- **Market:** fee (max 10%), treasury, allowed collections, pause.
- **Reward Pool:** signer, daily limits (max 5%/day), pause, `emergencyWithdraw` (only to the fixed treasury), migration with 7-day notice.
- **Splitter:** treasury, pool and pool share (20%–60%).

## Development

```bash
npm install
npm test            # 38 tests (including attack tests)
npm run coverage    # coverage report
```

## License

[BUSL-1.1](LICENSE). Security reports: see [SECURITY.md](SECURITY.md).
