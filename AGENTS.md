# STBL Protocol (`agentarena-stbl`) — Codebase Context for Security Auditing

> **Purpose.** A context pack for an AI agent (or human auditor) reviewing `alextianyushi/agentarena-stbl` — a scope-collection repository for the **STBL Protocol** security research program. It covers what the repo actually contains, the protocol architecture, trust boundaries, flows, invariants, and a prioritised set of leads.
>
> Items marked **hypothesis** are unconfirmed leads from static reading. §12 lists what the repo is missing and §13 lists live-state reads.

| Field | Value |
|---|---|
| Repository | `https://github.com/alextianyushi/agentarena-stbl` |
| Commits | 1 (`f4e8ab2`, "first commit") |
| Repo contents | 19 Solidity files (downloaded artifacts), 1 download script, 1 program document |
| Total Solidity | 7,985 lines across 19 files — but only **~4,698 lines unique** (see §1.2) |
| Unique contracts | **11** |
| Solidity version | `^0.8.20` throughout |
| Networks | Ethereum mainnet (17 targets), BNB Smart Chain (2 targets) |
| Program reviewed | 2026-09-06 |
| Reward range | $200 (Low) – **$20,000 (Critical)** |

---

## 1. What this repository actually is

**This is not a protocol source repository.** It is a **bug-bounty scope package**: a script that pulls verified implementation source from Etherscan/BscScan for 19 proxy addresses, plus a platform-neutral adaptation of STBL's public program terms. There is no build system, no test suite, no dependencies, no `foundry.toml`/`hardhat.config`, and no deployment scripts.

```
agentarena-stbl/
├── security-research-program.md      # program terms, scope table, rewards
├── scripts/download-contracts.mjs    # Etherscan v2 API downloader
└── audit-scope/
    ├── ethereum/   (17 .sol files)
    └── bsc/        (2 .sol files)
```

### 1.1 How the source was obtained — and what that omits

`scripts/download-contracts.mjs` does, per target:

1. `getsourcecode` on the **proxy** address.
2. Reads `result[0].Implementation`; throws if absent or malformed.
3. `getsourcecode` on the **implementation** address.
4. Parses the standard-JSON `sources` map (handling the `{{...}}` wrapper).
5. **Writes only `mainSource(...)`** — the single file whose basename matches the contract name, or the first file containing `contract <Name>`.

> **Critical limitation for any agent reading this repo.** Step 5 keeps exactly **one file per contract**. Every `import` target is discarded. So the repo contains **none** of:
>
> - `../interfaces/*` — `ISTBL_Register`, `ISTBL_Core`, `ISTBL_USST`, `ISTBL_YLD`, `ISTBL_PT1_AssetOracle`, `ISTBL_LT1_AssetOracle`, `ISTBL_*_AssetVault`, `ISTBL_*_AssetIssuer`, `ISTBL_*_AssetYieldDistributor`
> - `../lib/*` — **`STBL_AssetDefinitionLib`**, **`STBL_Decoder`**, **`STBL_OracleLib`**, **`DecimalConverter`**, `STBL_Errors`, `STBL_PT1_Asset_Errors`, `STBL_LT1_Asset_Errors`
> - The `AssetDefinition`, `VaultStruct`, `YLD_Metadata`, and `AssetStatus` type definitions
> - The **price oracles** — which are not in the scope table either (see §12)
> - OpenZeppelin upgradeable base contracts
> - **The proxy contracts themselves** (only implementations were saved, despite `-Proxy.sol` filenames)
>
> Files are named `X-Proxy.sol` but contain the **implementation** source. Do not mistake them for proxy code.
>
> **Consequence:** none of these files compile as-is, and the fee/haircut math (`calculateDepositFees`, `calculateYieldFee`), the role helpers (`isIssuer`, `isVault`, `isActive`), decimal conversion, and all oracle pricing are **invisible**. Several leads below cannot be closed without them. Re-fetch the full `sources` map before doing real work — the script already parses it; only `mainSource` throws it away.

### 1.2 Deduplication — 19 files, 11 unique contracts

Verified byte-identical:

| Group | Files | Status |
|---|---|---|
| `STBL_Token` Ethereum vs BSC | 2 | **identical** |
| `STBL_USST` Ethereum vs BSC | 2 | **identical** |
| `LT1_Issuer` OUSG vs USDY | 2 | **identical** |
| `LT1_Vault` OUSG vs USDY | 2 | **identical** |
| `LT1_YieldDistributor` OUSG vs USDY | 2 | **identical** |
| `PT1_Issuer` OUSG vs USDY | 2 | **identical** |
| `PT1_Vault` OUSG vs USDY | 2 | **identical** |
| `PT1_YieldDistributor` OUSG vs USDY | 2 | **identical** |

The OUSG and USDY variants are **the same implementation code** parameterised only by the `assetID` passed to `initialize`. Audit each once; then verify per-instance that the *configuration* differs correctly (§13).

**Read these 11 files, in this order:**

| File | Lines | Role |
|---|---|---|
`STBL_Register-Proxy.sol` | 740 | Asset registry, roles, fee/duration config, deposit accounting |
`STBL_PT1_Vault-USDY-Proxy.sol` | 503 | PT1 custody, fees, yield distribution, emergency drain |
`STBL_LT1_Issuer-USDY-Proxy.sol` | 501 | LT1 deposit/withdraw **+ `withdrawExpired`** |
`STBL_LT1_Vault-USDY-Proxy.sol` | 500 | LT1 custody |
`STBL_PT1_Issuer-USDY-Proxy.sol` | 450 | PT1 deposit/withdraw |
`STBL_YLD-Proxy.sol` | 370 | Yield NFT (ERC-721) |
`STBL_USST-Proxy.sol` | 365 | Stable-principal token (ERC-20) |
`STBL_LT1_YieldDistributor-USDY-Proxy.sol` | 331 | LT1 reward index |
`STBL_PT1_YieldDistributor-USDY-Proxy.sol` | 330 | PT1 reward index |
`STBL_Token-Proxy.sol` | 307 | STBL governance token |
`STBL_Core-Proxy.sol` | 301 | Mint/burn orchestration hub |

---

## 2. What the protocol is

STBL is a **stablecoin protocol that separates stable principal from yield on-chain**, backed by tokenised real-world assets. A user deposits an RWA token (Ondo's **USDY** or **OUSG**) and receives two instruments:

- **USST** — a fungible ERC-20 representing the **stable principal**, minted at the deposit's net USD value.
- **YLD** — a non-fungible ERC-721 carrying the position's full metadata and the **claim on yield**.

**STBL** is a separate governance/value token with a `MAX_CAP` of `10**28`.

Two product lines wrap the same underlying assets with different maturity semantics:

| Line | Withdrawal window | Distinctive behaviour |
|---|---|---|
| **PT1** | `depositTimestamp + yieldDuration` onward, **no upper bound** | Perpetual — withdraw any time after the yield lock |
| **LT1** | `[depositTimestamp + yieldDuration, depositTimestamp + duration]` | **Expires.** Miss the window and only the treasury can withdraw, via `withdrawExpired` |

Four assets exist as (line × collateral) pairs: PT1-USDY, PT1-OUSG, LT1-USDY, LT1-OUSG. Each has its own Issuer, Vault, and YieldDistributor triple, plus an oracle.

### In-scope addresses

**Ethereum**

| Contract | Address |
|---|---|
| STBL_Token | `0xb3116013c55d49f575ace3cb0d123f3dbf6cac35` |
| STBL_USST | `0xf9d82660828d8f5d121b14a9dc9c677d91f60065` |
| STBL_YLD | `0xd33c37a90155be8fcab769e38a563e74bfd70e0b` |
| STBL_Register | `0xa58b634c10df2665a3de1680675d5bb9065847d2` |
| STBL_Core | `0x3c316bcf47c991ba09622d4c2f40f786ab4f46db` |
| PT1_Issuer-USDY | `0xa0e2b352118f9983f3a75ddc9abd996983c93764` |
| PT1_Vault-USDY | `0xd238e964b557bd8f39feba8c2c93d6f428007232` |
| PT1_YieldDistributor-USDY | `0x97fb98a7a7400bc651dec6a02640a36f8bdfaa0b` |
| LT1_Issuer-USDY | `0x916442ebaa1cef4b3f5cd9b7a62170b50c3305c1` |
| LT1_Vault-USDY | `0x5766b5d21bea4de3dda1b935f1740d194babab1f` |
| LT1_YieldDistributor-USDY | `0xcc14f2eddeae2a3c450c7afe328fd7331355dd73` |
| PT1_Issuer-OUSG | `0xf8acf255854c8d36010c849f1702eb350c8c4087` |
| PT1_Vault-OUSG | `0x64bef4478942d8fd62be281707076442aa2d055e` |
| PT1_YieldDistributor-OUSG | `0x447a8f3608fb2002c1aa8e44b076b7d62b6fa618` |
| LT1_Issuer-OUSG | `0xbac1f4f20847669ba12841a534b2aa053d65373c` |
| LT1_Vault-OUSG | `0x0437ee84ca723ceb7052a8cc73360e21427c42ea` |
| LT1_YieldDistributor-OUSG | `0x50eda4294d9a57b35a9d836faaeb88d1c4fab6c9` |

**BNB Smart Chain**

| Contract | Address |
|---|---|
| STBL_Token | `0x8dedf84656fa932157e27c060d8613824e7979e3` |
| STBL_USST | `0x1171ce10262a60c17507580a3b70b956f20a35de` |

BSC has **only the tokens** — no Core, Register, Issuer, Vault, or Distributor. Cross-chain USST supply is bridged via `BRIDGE_ROLE` (§6.2).

---

## 3. Architecture

```
                          ┌──────────────────────────────────────┐
                          │  STBL_Register  (UUPS)               │
                          │  • assetData[id] -> AssetDefinition  │
   REGISTER_ROLE ────────>│  • assetDeposits[id]                 │
   DEFAULT_ADMIN ────────>│  • roles: hasRole() for whole system  │
                          │  • treasury, Core, USST, YLD addrs   │
                          └───────┬────────────────┬─────────────┘
                                  │ fetchAssetData │ hasRole
        ┌─────────────────────────┴───┐            │
        v                             v            v
┌──────────────────┐        ┌────────────────────────────────┐
│  STBL_Core       │        │  Per-asset triple (×4 assets)  │
│  (UUPS)          │        │                                │
│  put()  -> mint  │<───────┤  Issuer  ── deposit/withdraw    │<── User
│  exit() -> burn  │        │     │                           │
│  isValidIssuer   │        │     ├──> Vault  (custody, fees) │
└───┬──────────┬───┘        │     │       │                   │
    │ MINTER   │ MINTER     │     │       └─> Oracle (!! NOT  │
    v          v            │     │            IN SCOPE)     │
┌────────┐ ┌────────┐       │     └──> YieldDistributor       │
│ USST   │ │  YLD   │       │            (rewardIndex)        │
│ ERC-20 │ │ ERC-721│       └────────────────────────────────┘
└────────┘ └────────┘
    ^                        ┌──────────────┐
    │ BRIDGE_ROLE            │  STBL_Token  │  MAX_CAP 1e28
    └── BSC USST             │  ERC-20      │  BRIDGE_ROLE -> BSC
                             └──────────────┘
```

**The Register is the hub for everything.** Every other contract calls back into it for `fetchAssetData`, `hasRole`, `fetchCore`, `fetchTreasury`, `fetchYLDToken`, and `trustedForwarder`. Notably, the Issuers, Vaults, and Distributors do **not** maintain their own `AccessControl` — they delegate role checks to `registry.hasRole(...)`. Compromise of the Register's `DEFAULT_ADMIN_ROLE` is compromise of the entire system.

### Common patterns across all 11 contracts

- **UUPS upgradeable**, `Initializable`, `constructor() { _disableInitializers(); }` with `@custom:oz-upgrades-unsafe-allow constructor`.
- **`uint256[64] private __gap`** in every contract.
- **`_authorizeUpgrade`** either `onlyRole(UPGRADER_ROLE)` (Core, Register, USST, YLD, Token) or `registry.hasRole(UPGRADER_ROLE, _msgSender())` (Issuers, Vaults, Distributors).
- **`_version` incremented inside `_authorizeUpgrade`** — a state write during upgrade authorisation.
- **ERC-2771 meta-transactions** via `ERC2771ContextUpgradeable`, with `_msgSender`/`_msgData`/`_contextSuffixLength` overrides in all 11.
- **Custom errors** (`STBL_*`), no revert strings.
- **No `ReentrancyGuard` anywhere.** Confirmed by grep across all 11 files.

---

## 4. Roles and trust model

All roles live on the **Register** (or on the token contracts for token-local roles).

| Role | Held where | Powers | Blast radius |
|---|---|---|---|
| **`DEFAULT_ADMIN_ROLE`** | Register, Core, USST, YLD, Token | Grant/revoke every role; `setCore`, `setTreasury`, `updateTrustedForwarder`, `YLD.disableNFT`, `YLD.setBaseURI` | **Total loss.** Can self-grant MINTER/UPGRADER/BRIDGE |
| **`UPGRADER_ROLE`** | Register | Upgrade **any** of the 11 implementations | **Total loss.** UUPS, no timelock |
| **`REGISTER_ROLE`** | Register | `addAsset`, `setupAsset`, `setFees`, `setCut`, `setLimit`, `setDurations`, `setOracle`, `setAdditionalBuffer`, `disableAsset`, `enableAsset`, **`emergenyStopAsset`** | **Can set the oracle to any address**, can change fees on live assets, can permanently freeze an asset |
| **`MINTER_ROLE`** | USST, YLD, Token | `mint(to, amt)`, **`burn(from, amt)` with no allowance check** | Unlimited USST mint; burn any holder's USST |
| **`BRIDGE_ROLE`** | USST, Token (both chains) | `bridgeMint`, `bridgeBurn` | **Unlimited USST/STBL mint on either chain** |
| **`SPLITTER_ROLE`** | Register | Issuer `enableYield` / `disableYield` on **any** tokenID | See H-2 — yield-share inflation and withdrawal bricking |
| **`YIELD_DISTRIBUTION_ROLE`** | Register | `Vault.distributeYield()` | Controls when yield is realised |
| **`PAUSE_ROLE`** | USST, YLD, Token | `pause` / `unpause` | Halts transfers, mints, burns |
| **`LIST_MANAGER_ROLE`** | USST | `enableBlacklist` / `disableBlacklist` | Freeze any USST holder |
| **Treasury** (address, not role) | Register | Receives all fees; **sole caller of LT1 `withdrawExpired`**; recipient of `emergencyWithdraw` | Receives expired LT1 collateral and all emergency drains |
| **Asset Issuer** (per-asset address in `AssetDefinition`) | — | `Core.put` (mint USST+YLD with **self-declared value**), `Core.exit` (burn), `Vault.depositERC20`/`withdrawERC20` | **Can mint arbitrary USST** — see H-6 |

### The central trust assumption

`Core.put(_to, _metadata)` mints `USST` equal to `_metadata.stableValueNet`, a value **supplied entirely by the caller** (the registered Issuer). Core performs no independent valuation, no oracle read, and no check that any collateral was actually deposited. The only guard is `isValidIssuer(_metadata.assetID)`.

Therefore: **any address registered as an Issuer for an active asset can mint unlimited USST.** The honest Issuers happen to call `Vault.depositERC20` first, but Core does not require it. `REGISTER_ROLE` can register a new Issuer via `setupAsset`. This is the protocol's root of value.

---

## 5. Storage layout

Each contract's own variables, before the `__gap`. Base-contract slots (AccessControl, ERC20/721, Pausable, ERC2771, UUPS) precede these.

**`STBL_Register`** — `_version`, `assetCtr`, `USST`, `YLD`, `Core`, `treasury`, `assetData` (mapping), `assetDeposits` (mapping), `trustedForwarderAddress`, `uint256[64] __gap`

**`STBL_Core`** — `_version`, `registry`, `USST`, `YLD`, `trustedForwarderAddress`, `uint256[64] __gap`

**`STBL_YLD`** — `MINTER_ROLE`/`PAUSE_ROLE`/`UPGRADER_ROLE` (constants), `nftCtr`, metadata mapping, `uint256[64] __gap`

**`STBL_Token`** — `MAX_CAP = 10**28` (constant), `uint256[64] __gap`

**Issuer / Vault / Distributor** — `assetID`, `registry`, `_version`, plus `VaultData` (Vault) or `rewardIndex`/`totalSupply`/`previousDistribution`/`stakingData` (Distributor), `uint256[64] __gap`

All are UUPS-upgradeable, so **the `__gap` sizing is load-bearing**. A future upgrade that appends variables without reducing `__gap` from 64 grows the reserved footprint; one that inserts variables before existing ones corrupts state. Verify with the OZ upgrades validator against the current on-chain implementations before accepting any upgrade.

---

## 6. Flows

### 6.1 Deposit (PT1 and LT1, identical)

```
User ──approve(Issuer, amount)──> USDY/OUSG
User ──deposit(assetValue)──────> Issuer
  iDeposit(assetValue, sender)   [modifier isSetupDone: AssetData.isActive()]
    ├─ require(assetValue != 0)
    ├─ MetaData = generateMetaData(assetValue)
    │    ├─ normalizeToDecimals18(assetValue, tokenDecimals)
    │    ├─ snapshot depositFee, withdrawFee, cut(haircut), insuranceFee,
    │    │            duration, yieldDuration        ← frozen at deposit
    │    ├─ stableValueGross = oracle.fetchForwardPrice(assetValue)
    │    ├─ MetaData.calculateDepositFees()           ← in missing lib
    │    ├─ haircutAmountAssetValue = oracle.fetchInversePrice(haircutAmount)
    │    └─ stableValueNet = stableValueGross
    │                        - (depositfee + haircut + insurancefee)
    ├─ Vault.depositERC20(sender, MetaData)           [isValidIssuer]
    │    ├─ safeTransferFrom(sender → vault, assetValue @ native decimals)
    │    ├─ VaultData.assetDepositGross += assetValue
    │    ├─ VaultData.assetDepositNet   += assetValue - (depositFee + insuranceFee) [asset units]
    │    ├─ VaultData.depositValueUSD   += stableValueNet + haircutAmount
    │    ├─ VaultData.depositFees / insuranceFees += ...
    │    └─ VaultData.cumilativeHairCutValue += haircutAmount
    ├─ Core.put(sender, MetaData)                     [isValidIssuer]
    │    ├─ require(!registry.isDepositLimitReached(assetID, stableValueNet))
    │    ├─ registry.incrementAssetDeposits(assetID, stableValueNet)
    │    ├─ USST.mint(sender, stableValueNet)
    │    └─ nftID = YLD.mint(sender, MetaData)
    └─ Distributor.enableStaking(nftID, stableValueNet + haircutAmount)   [isIssuer]
         ├─ _updateRewards(nftID)   → rewardIndex snapshot (no historical claim)
         ├─ stakingData[nftID].balance += value
         └─ totalSupply += value
```

The **haircut** (`cut`) is the protocol's over-collateralisation buffer: USST is minted for `stableValueNet` but yield accrues on `stableValueNet + haircutAmount`, and the vault tracks `depositValueUSD` at the larger figure.

### 6.2 Withdraw — PT1

```
User ──withdraw(_tokenID)──> Issuer.iWithdraw(_tokenID, _msgSender())
  [isSetupDone]
  ├─ MetaData = YLD.getNFTData(_tokenID)
  ├─ require(MetaData.assetID == assetID)
  ├─ require(YLD.ownerOf(_tokenID) == _sender)
  ├─ require(!MetaData.isDisabled)
  ├─ require(depositTimestamp + yieldDuration <= block.timestamp)   // lock elapsed
  ├─ Distributor.claim(_tokenID)          ← EXTERNAL TRANSFER #1 (reward → owner)
  ├─ Vault.withdrawERC20(_sender, MetaData)  ← EXTERNAL TRANSFER #2 (principal → user)
  │    ├─ require(oracle.fetchForwardPrice(assetDepositNet) >= depositValueUSD)  // solvency
  │    ├─ withdrawFee = calculateWithdrawFees(MetaData, AssetData.withdrawFees)
  │    ├─ withdrawAssetValue = oracle.fetchInversePrice(
  │    │        (stableValueNet + haircutAmount) - withdrawFee)
  │    ├─ safeTransfer(_to, withdrawAssetValue @ native decimals)
  │    ├─ VaultData.withdrawFees += withdrawFeeAssetValue
  │    └─ VaultData.depositValueUSD -= stableValueNet + haircutAmount
  ├─ Distributor.disableStaking(_tokenID, stableValueNet + haircutAmount)
  └─ Core.exit(assetID, _sender, _tokenID, MetaData.stableValueNet)
       ├─ USST.burn(_sender, stableValueNet)      ← requires user still HOLDS the USST
       ├─ YLD.burn(_sender, _tokenID)
       └─ registry.decrementAssetDeposits(assetID, stableValueNet)
```

> **Note the ordering.** Both external token transfers (`claim`, `withdrawERC20`) execute **before** `disableStaking` and `exit`. Throughout both transfers the NFT still exists, is still owned by `_sender`, and is still staked. There is no reentrancy guard anywhere in the call chain. See **H-1**.

The user must **re-acquire the USST** to withdraw, since USST is freely transferable and burning happens from `_sender`. That is the intended principal/yield separation, but it means a user who sold their USST cannot withdraw their collateral.

### 6.3 Withdraw — LT1, and the expiry mechanism

LT1's `iWithdraw` is identical **plus** an upper bound:

```
  ├─ require(depositTimestamp + duration >= block.timestamp)   // NOT expired
  │      (reverts STBL_Asset_WithdrawDurationNotReached — misleading error name)
  └─ require(depositTimestamp + yieldDuration <= block.timestamp)
```

Once `duration` elapses, only the treasury can act:

```
Treasury ──withdrawExpired(_tokenID)──> LT1_Issuer   [isSetupDone]
  ├─ require(MetaData.assetID == assetID)
  ├─ require(registry.fetchTreasury() == msg.sender)
  ├─ require(depositTimestamp + duration < block.timestamp)   // IS expired
  ├─ if (!MetaData.isDisabled) Distributor.claim(_tokenID)     // pays the USER
  ├─ Vault.withdrawERC20(treasury, MetaData)      ← collateral → TREASURY
  ├─ Distributor.disableStaking(_tokenID, stableValueNet + haircutAmount)
  └─ emit withdrawAssetTreasury(...)
      ⚠ NO Core.exit()  — see H-3
```

**Boundary check (verified, no gap or overlap):** at exactly `t = depositTimestamp + duration`, `iWithdraw`'s `duration < t` is false (allowed) and `withdrawExpired`'s `duration >= t` is true (reverts). The user owns the boundary block. Clean.

### 6.4 Yield distribution

```
YIELD_DISTRIBUTION_ROLE ──distributeYield()──> Vault
  ├─ differentialUSD = iCalculatePriceDifferentiation()   // computed BEFORE role check
  ├─ require(registry.hasRole(YIELD_DISTRIBUTION_ROLE, _msgSender()))
  └─ if (differentialUSD > 0):
       ├─ (yield, yieldFee) = AssetData.calculateYieldFee(differentialUSD)   [missing lib]
       ├─ VaultData.yieldFees += oracle.fetchInversePrice(yieldFee)
       ├─ token.approve(rewardDistributor, yieldAssetValue)   ← plain approve, not forceApprove
       ├─ VaultData.assetDepositNet -= yieldAssetValue + yieldFeeAssetValue
       └─ Distributor.distributeReward(yieldAssetValue)
            ├─ require(AssetData.isActive())
            ├─ require(previousDistribution + yieldDuration < block.timestamp)
            ├─ require(AssetData.isVault(msg.sender))
            ├─ safeTransferFrom(vault → distributor, reward)
            ├─ rewardIndex += (reward * MULTIPLIER) / totalSupply   ← ÷0 if totalSupply == 0
            └─ previousDistribution = block.timestamp
```

Claiming is a standard index-delta accumulator:

```
_calculateRewards(id) = stakingData[id].balance * (rewardIndex - stakingData[id].rewardIndex) / MULTIPLIER
_updateRewards(id)    { earned += _calculateRewards(id); rewardIndex = global rewardIndex; }

claim(id) external                        ← NO ACCESS CONTROL
  ├─ require(AssetData.isActive())
  ├─ require(!YLD.getNFTData(id).isDisabled)
  ├─ _updateRewards(id)
  └─ if (earned > 0) { earned = 0; safeTransfer(YLD.ownerOf(id), reward); }
```

`claim` pays **`ownerOf(id)` at call time**. Since YLD is a transferable ERC-721 and no transfer hook settles rewards, the entire accrued `earned` balance follows the NFT to its new owner. For a yield-bearing NFT that is defensible design — but it should be confirmed as intentional, and it means NFT marketplaces must price unclaimed yield.

### 6.5 Asset lifecycle in the Register

```
addAsset(name, desc, ...)          [REGISTER_ROLE]  → ++assetCtr, status = ?
setupAsset(id, fees, cut, addrs,   [REGISTER_ROLE]  → one-shot (STBL_SetupAlreadyDone)
           durations, oracle)                          validates all fees ≤ FEES_CONSTANT,
                                                        all addresses != 0,
                                                        yieldDuration <= duration
─────────────────────────────────────────────────────────────────────
        ┌──────────┐  disableAsset   ┌───────────┐
        │ ENABLED  │ ──────────────> │ DISABLED  │
        │          │ <────────────── │           │
        └────┬─────┘  enableAsset    └─────┬─────┘
             │                             │
             │  emergenyStopAsset          │  emergenyStopAsset
             v                             v
        ┌──────────────────────────────────────┐
        │        EMERGENCY_STOP                │  ← TERMINAL. No exit.
        └──────────────────────────────────────┘
```

`enableAsset` requires status `== DISABLED`; `disableAsset` requires `== ENABLED`. **Nothing transitions out of `EMERGENCY_STOP`.** See H-4.

---

## 7. Prioritised audit leads

Program severities: Critical $20k, High $5k, Medium $2k, Low $200. Note the exclusions — **theoretical issues without a working PoC are ineligible, and "reports generated with AI without a runnable proof of concept are not eligible."** Every lead below needs a Foundry PoC against a mainnet fork.

### H-1 — No reentrancy protection anywhere; both token transfers precede state finalisation
**Provisional: Critical (if any callback exists)** · `*_Issuer.iWithdraw`

`grep -c nonReentrant` across all 11 contracts returns **zero**. In `iWithdraw`, the order is:

```
1. Distributor.claim(_tokenID)              → safeTransfer(reward token → owner)
2. Vault.withdrawERC20(_sender, MetaData)   → safeTransfer(collateral → user)
3. Distributor.disableStaking(...)          → balance/totalSupply decrement
4. Core.exit(...)                           → burn USST, burn YLD, decrement deposits
```

At the moment of transfers (1) and (2), the NFT still exists, `ownerOf == _sender`, `isDisabled == false`, staking is still enabled, and the duration check still passes. A reentrant call to `withdraw(_tokenID)` would satisfy every precondition again.

*What's needed for exploitation:* a callback during either transfer. `safeTransfer` on a plain ERC-20 gives none. So this hinges on the actual behaviour of **USDY and OUSG** — both are Ondo tokens with **upgradeable proxies, transfer allowlists, and rebasing/rate mechanics**. Determine whether either can invoke recipient code. Also check the recipient side: if `_sender` is a contract, does anything call back into it?

*Method:* fork mainnet, deploy a malicious recipient, attempt double-withdraw. If no callback exists, downgrade to Low/Informational but still report the CEI violation, because it becomes exploitable the moment a collateral token with hooks is onboarded via `setupAsset`. Note `disableStaking`'s `balance -= value` would underflow-revert on the second pass — so the *specific* double-withdraw may self-block, which is why the PoC must target the ordering, e.g. claiming rewards twice before `earned` is zeroed, or interleaving with `enableYield` (H-2) to inflate `balance` first so the underflow doesn't fire.

### H-2 — `enableYield` / `disableYield` are unguarded, non-idempotent, and asset-agnostic
**Provisional: Critical** · `*_Issuer.enableYield`, `*_Issuer.disableYield`

```solidity
function enableYield(uint256 _tokenID) external {
    if (!registry.hasRole(SPLITTER_ROLE, _msgSender())) revert STBL_UnauthorizedCaller();
    AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
    YLD_Metadata memory MetaData = iSTBL_YLD(registry.fetchYLDToken()).getNFTData(_tokenID);
    iSTBL_..._AssetYieldDistributor(AssetData.rewardDistributor)
        .enableStaking(_tokenID, MetaData.stableValueNet + MetaData.haircutAmount);
}
```

Three defects in eight lines:

1. **No idempotency guard.** There is no "is currently staked" flag anywhere. `enableStaking` does `stakingData[id].balance += value; totalSupply += value;`. Calling `enableYield(id)` **N times** multiplies that NFT's yield weight by N+1 (it was already staked at deposit) with **no additional collateral**, diluting every other holder pro rata.
2. **No `assetID` check.** Unlike `iWithdraw`, neither function verifies `MetaData.assetID == assetID`. A `SPLITTER_ROLE` holder can pass an **OUSG NFT's tokenID to the USDY Issuer**, staking it in the wrong distributor and inflating `totalSupply` there against collateral that lives in a different vault.
3. **`disableYield` bricks withdrawals.** `disableStaking` does `balance -= value`. Calling `disableYield(id)` once on an already-unstaked-or-single-staked NFT drives `balance` to zero; the subsequent `iWithdraw` → `disableStaking` then **underflow-reverts permanently**. The user's collateral is locked forever with no admin recovery path.

*Method:* PoC (1) repeated `enableYield` and show the yield share multiply and other holders' `calculateRewardsEarned` fall; PoC (3) `disableYield` then `withdraw` and show the permanent revert. Both need a `SPLITTER_ROLE` signer — check on-chain who holds it (§13). If it is a single EOA, severity is Critical; if it is a multisig, argue High on the basis that it is a **lower-privilege role than admin** yet grants unbounded yield inflation and irreversible fund locking, which is almost certainly outside its intended authority.

### H-3 — LT1 `withdrawExpired` never burns USST or the YLD NFT
**Provisional: Critical (protocol insolvency)** · `STBL_LT1_Issuer.withdrawExpired`

`withdrawExpired` transfers the collateral to the treasury and disables staking, but **does not call `Core.exit`**. Compare `iWithdraw`, which does. Consequences:

1. **USST is not burned.** The user keeps `stableValueNet` of freely transferable USST while the treasury holds the collateral that backed it. **USST becomes unbacked one-for-one with every expired LT1 position.** This is a direct hit on the protocol's core solvency claim.
2. **The YLD NFT is not burned** and `isDisabled` is not set. It remains in the user's wallet with intact metadata, permanently unwithdrawable (the `duration` check now always fails), and still tradeable to an unwitting buyer.
3. **`registry.decrementAssetDeposits` is never called.** `assetDeposits[assetID]` stays inflated forever, permanently consuming headroom against `AssetData.limit` and eventually blocking all new deposits for that asset via `isDepositLimitReached`.
4. **Replay is blocked only by accident.** Nothing marks the token consumed. A second `withdrawExpired(_tokenID)` passes every check and re-transfers the same collateral to the treasury — it reverts only because `disableStaking`'s `balance -= value` underflows, and that happens **after** the vault transfer in the same tx so it rolls back. **Chain this with H-2:** call `enableYield(id)` a few times first to inflate `stakingData[id].balance`, and `withdrawExpired` becomes **replayable**, draining the vault to the treasury repeatedly.

*Method:* fork; deposit into LT1; warp past `duration`; call `withdrawExpired` as treasury; assert `USST.balanceOf(user)` unchanged, `YLD.ownerOf(tokenID) == user`, `registry.fetchDeposits(assetID)` unchanged. Then chain H-2 and demonstrate the replay. Item 4 is the strongest Critical in this document because it needs only `SPLITTER_ROLE` + treasury, not admin.

### H-4 — `EMERGENCY_STOP` is terminal and `emergencyWithdraw` is permissionless
**Provisional: Critical** · `STBL_Register.emergenyStopAsset` + `*_Vault.emergencyWithdraw`

```solidity
function emergencyWithdraw() external {                    // ← NO access control
    AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
    address treasury = registry.fetchTreasury();
    if (treasury == address(0)) revert STBL_InvalidTreasury();
    if (AssetData.status != AssetStatus.EMERGENCY_STOP) revert STBL_AssetActive();
    uint256 balance = IERC20(AssetData.token).balanceOf(address(this));
    IERC20(AssetData.token).safeTransfer(treasury, balance);
    emit EmergencyFundsWithdraw(balance);
}
```

The full chain:

1. `REGISTER_ROLE` calls `emergenyStopAsset(id)` → status `EMERGENCY_STOP`.
2. **No function transitions out of `EMERGENCY_STOP`** — `enableAsset` requires `DISABLED`, `disableAsset` requires `ENABLED`. Terminal.
3. Every user exit path is now dead: the Issuer's `isSetupDone` requires `isActive()`, and `Distributor.claim` (called unconditionally by `iWithdraw`) requires `isActive()`.
4. **Anyone** — not just an admin — calls `emergencyWithdraw()`, moving **the entire vault balance** to the treasury.

Result: all user principal permanently at the treasury, all users still holding USST and YLD, no recovery path short of a UUPS upgrade.

Two supporting defects: the function **does not decrement `VaultData.assetDepositNet`** despite its docstring claiming *"Reduces the net asset deposit tracking by the withdrawn amount"* — so all vault accounting is left stale; and `emergenyStopAsset` is misspelled (see H-11).

Also note **`withdrawFees()` has no access control either.** Funds go to the treasury, so impact is limited to griefing (forcing a sweep, zeroing counters, and reverting if the balance is short), but it is a second missing-modifier instance in the same file — evidence of a systematic pattern rather than a one-off.

*Method:* the whole chain is demonstrable on a fork with a `REGISTER_ROLE` signer. Report the **permissionless `emergencyWithdraw`** and the **terminal state** as separate findings if the program prefers granularity; the combination is what makes it Critical. Recommend: gate `emergencyWithdraw`, and add an `EMERGENCY_STOP → DISABLED` transition.

### H-5 — `deposit(uint256, address)` lets anyone force a deposit from any approver
**Provisional: High** · `*_Issuer.deposit(uint256,address)`

```solidity
function deposit(uint256 assetValue, address _sender) external returns (uint256) {
    return iDeposit(assetValue, _sender);   // ← no check that msg.sender == _sender
}
```

`iDeposit` → `Vault.depositERC20(_sender, MetaData)` → `safeTransferFrom(_sender, vault, amount)`.

Any address with an outstanding USDY/OUSG approval to the Issuer — which every legitimate depositor must grant — can have that allowance spent by **any caller**, at any time, for any amount up to the allowance.

The victim does receive the USST and the YLD NFT, so this is not theft. It is a **forced position**: their collateral is locked for `yieldDuration` (and for LT1, subject to expiry to the treasury under H-3), they involuntarily pay `depositFee + insuranceFee + haircut`, and their allowance is consumed. An attacker can repeat this until the allowance is exhausted, timed to the worst oracle price. Under the program's eligible classes this is "unauthorized transactions" and "business-logic flaws that violate intended protocol behavior."

*Method:* fork; approve the Issuer as victim; call `deposit(amount, victim)` from an unrelated EOA; assert the transfer and the lock. Then demonstrate the amplification: repeat until allowance is zero, and for LT1 show the position can expire into the treasury.

*Note the asymmetry:* the withdrawal equivalent, `iWithdraw`, correctly requires `ownerOf(_tokenID) == _sender`. Only the deposit path is open.

### H-6 — Registered Issuers can mint unbacked USST; Core validates nothing
**Provisional: High (centralisation, by design)** · `STBL_Core.put`, `STBL_Core.exit`

`put` mints `USST` for a caller-declared `_metadata.stableValueNet` with no oracle read, no collateral check, and no cross-check against the Vault. `exit` is worse:

```solidity
function exit(uint256 _assetID, address _from, uint256 _tokenID, uint256 _value)
    external isValidIssuer(_assetID)
{
    USST.burn(_from, _value);
    YLD.burn(_from, _tokenID);
    registry.decrementAssetDeposits(_assetID, _value);
}
```

Three unvalidated relationships:

1. **`_value` is not checked against `YLD.getNFTData(_tokenID).stableValueNet`.** An Issuer can burn a small amount of USST while destroying an NFT representing a large position.
2. **`_tokenID` is not checked to belong to `_assetID`.** An Issuer for asset A can burn an NFT belonging to asset B, while decrementing A's deposit counter — corrupting per-asset accounting across the protocol.
3. **`USST.burn` requires only `MINTER_ROLE`, with no allowance check**, so Core can burn from any address. `_from` is Issuer-supplied.

The honest Issuers pass consistent values, but `REGISTER_ROLE` can register any address as an Issuer via `setupAsset`. Also note `decrementAssetDeposits` uses checked `-=`, so an inconsistent `_value` can underflow-revert and **permanently brick redemptions for an asset** once the counter drifts.

*Report as:* a documented centralisation risk **plus** concrete missing-validation findings (1) and (2), which are cheap to fix and independently demonstrable. The program excludes "concerns about the authority of documented permissioned roles acting within it" — so lead with the missing cross-validation, not with "the admin is powerful."

### H-7 — `withdraw(uint256, address)` is an empty function that silently succeeds
**Provisional: Medium** · both Issuers

```solidity
function withdraw(uint256 _tokenID, address _sender) external {}
```

Present in **both** `STBL_PT1_Issuer` (line 164) and `STBL_LT1_Issuer` (line 162), with a full NatSpec block describing behaviour it does not implement. A user or integrator calling this overload gets a **successful transaction with zero effect** — no revert, no event, no state change.

Impact: a front-end or contract integrator that resolves to this overload silently fails to withdraw. Users may believe funds were withdrawn. For LT1 this is materially worse: repeated "successful" no-op withdrawals through the expiry window end with the position expiring into the treasury under H-3.

*Method:* trivial to demonstrate. Note that ABI-level overload resolution means anyone generating bindings from the ABI sees two `withdraw` functions with no indication that one is a stub.

### H-8 — Oracle-based solvency check bricks all withdrawals on a price decline
**Provisional: High** · `*_Vault.withdrawERC20`

```solidity
if (oracle.fetchForwardPrice(VaultData.assetDepositNet) < VaultData.depositValueUSD)
    revert STBL_Asset_InsufficientVaultValue(...);
```

This is a **global, per-asset** gate evaluated on every individual withdrawal. If the collateral's USD price falls enough that the vault's net holdings are worth less than the cumulative USD value issued, **every user's withdrawal reverts simultaneously** — including users who are individually fully collateralised.

Since USDY and OUSG are yield-bearing and their price generally rises, the intended steady state is `forwardPrice > depositValueUSD`. But the check is unconditional and has no admin bypass, no partial-withdrawal mode, and no haircut allowance. Any oracle misconfiguration, a `setOracle` to a stale feed, a decimal mismatch in `fetchForwardPrice`, or a genuine NAV decline produces a **total withdrawal freeze** for that asset.

*Method:* fork; deposit; manipulate or mock the oracle downward; assert every `withdraw` reverts. Then check whether `distributeYield`'s `assetDepositNet -= yieldAssetValue + yieldFeeAssetValue` can push the vault into this state **on its own** — that would be a self-inflicted freeze with no external price move, which is the strongest version of this finding.

### H-9 — `distributeReward` divides by `totalSupply` with no zero guard
**Provisional: Medium** · `*_YieldDistributor.distributeReward`

```solidity
rewardIndex += (reward * MULTIPLIER) / totalSupply;
```

If every position has exited, `totalSupply == 0` and this panics (0x12). The `safeTransferFrom` precedes it, so the whole tx reverts and nothing is lost — but yield distribution is blocked for an empty asset, and `previousDistribution` is not advanced.

Two follow-ups worth checking in the same function: `previousDistribution + yieldDuration >= block.timestamp` reverts, meaning **distributions are rate-limited to once per `yieldDuration`** — verify that `REGISTER_ROLE` shortening `yieldDuration` via `setDurations` cannot be used to distribute repeatedly and inflate `rewardIndex`. And `rewardIndex` uses integer division, so `reward * MULTIPLIER < totalSupply` rounds the whole distribution to **zero** while the tokens have already been transferred in — permanently stranding them in the distributor. That second point is a genuine loss-of-funds path for small distributions against a large `totalSupply`; size `MULTIPLIER` (in the missing lib) to judge reachability.

### H-10 — `claim` is permissionless and rewards follow the NFT with no settlement on transfer
**Provisional: Medium (verify intent)** · `*_YieldDistributor.claim`

`claim(uint256 id) external` has no caller check and pays `YLD.ownerOf(id)`. Anyone can trigger anyone's claim. Since the payee is the rightful owner this is not theft, but:

- `stakingData[id].earned` accrues against the NFT, and **no ERC-721 transfer hook calls `_updateRewards`**. The full unclaimed balance transfers with the token.
- A seller can `claim` in the same block as a sale; a buyer can `claim` immediately after. Whoever calls last-before/first-after captures the accrual.
- Forced claims interfere with tax/accounting assumptions and let a third party choose the timing of a user's realisation.

*Method:* establish with the team whether yield-follows-NFT is intended (it probably is, for a tokenised-yield product). If so, report the **missing settlement-on-transfer** as the finding, since it makes YLD unsafe to trade without off-chain accounting, and check whether `STBL_YLD._update`/`_beforeTokenTransfer` should call into the distributor.

### H-11 — Wrong error selectors, typos, and docstring/code mismatches
**Provisional: Low / Informational**

- **`STBL_Register.emergenyStopAsset`** — misspelled. Permanent in an immutable-ish ABI; breaks any integrator searching for `emergencyStopAsset`.
- **`STBL_LT1_Issuer.iWithdraw`** uses `revert STBL_Asset_InvalidAsset(MetaData.assetID)` for the **owner** check, where PT1 correctly uses `STBL_Asset_IncorrectOwner(_tokenID, _sender)`. Copy-paste; misleads debugging and any client that branches on the selector.
- **`STBL_LT1_Issuer.iWithdraw`** uses `STBL_Asset_WithdrawDurationNotReached` for the *expired* case — semantically inverted.
- **`Vault.emergencyWithdraw`** docstring claims it "Reduces the net asset deposit tracking by the withdrawn amount"; it does not (H-4).
- **`Vault.distributeYield`** docstring says "Restricted to protocol treasury address for security"; it is actually gated on `YIELD_DISTRIBUTION_ROLE`.
- **`Vault.distributeYield`** computes `iCalculatePriceDifferentiation()` **before** the role check — harmless but wasteful and a code smell.
- **`Vault.distributeYield`** uses plain `IERC20.approve` rather than `forceApprove`/`safeIncreaseAllowance`. For a token that reverts on non-zero→non-zero approval changes this breaks distribution; and any unspent allowance persists.
- **`withdrawExpired` NatSpec** references `Pi_Asset_InvalidAsset`, `Pi_InvalidTreasury`, `Pi_Asset_WithdrawDurationNotReached` — leftover names from a prior protocol ("Pi"), suggesting this code was forked and renamed. **Worth chasing:** find the predecessor and diff, the way the Balancer and CapyFi cases showed value in comparing against upstream.

### H-12 — ERC-2771 sender resolution is inconsistent between authorisation paths
**Provisional: Medium (verify)** · all contracts

Every contract wires up `ERC2771ContextUpgradeable` and overrides `_msgSender`, yet authorisation is inconsistent:

| Site | Uses |
|---|---|
| `Core.isValidIssuer` | **`msg.sender`** |
| `Register.incrementAssetDeposits` / `decrementAssetDeposits` | **`msg.sender`** |
| `Vault.isValidIssuer` | **`msg.sender`** |
| `Distributor.isIssuer` | **`msg.sender`** |
| `Distributor.distributeReward` (isVault) | **`msg.sender`** |
| `LT1_Issuer.withdrawExpired` (treasury check) | **`msg.sender`** |
| `Issuer._authorizeUpgrade` | **`_msgSender()`** |
| `Issuer.enableYield` / `disableYield` | **`_msgSender()`** |
| `Vault.distributeYield` | **`_msgSender()`** |
| `Core.initialize` (grants DEFAULT_ADMIN) | **`_msgSender()`** |
| `USST`/`YLD`/`Token` `onlyRole` (via AccessControl) | **`_msgSender()`** |

Using raw `msg.sender` for contract-to-contract checks is the safe choice and probably deliberate. But the mix means **a compromised or malicious trusted forwarder can impersonate any address for every `_msgSender()`-gated path** — including `UPGRADER_ROLE` on the Issuers/Vaults/Distributors, `SPLITTER_ROLE`, and `YIELD_DISTRIBUTION_ROLE` — while the `msg.sender` paths stay safe.

`trustedForwarderAddress` is settable by `DEFAULT_ADMIN_ROLE` on Register/Core/USST/YLD/Token, and the Issuers/Vaults/Distributors read `registry.trustedForwarder()`. **Note `Core.initialize` sets it to `address(0)`** — so meta-transactions start disabled. Check the live value (§13). If any forwarder is set, its correctness becomes a Critical dependency for upgrade authority.

*Method:* read `trustedForwarder()` on all 11 live contracts. If non-zero, audit the forwarder (which is **not in scope** — see §12) and report the dependency. If zero everywhere, report as a latent risk gated on a single admin call.

### H-13 — Upgrade surface: 11 UUPS proxies, one `UPGRADER_ROLE`, no timelock
**Provisional: High (centralisation)**

`UPGRADER_ROLE` on the Register authorises upgrades for the Issuers, Vaults, and Distributors (which check `registry.hasRole(...)`), and the same role name gates Core, Register, USST, YLD, and Token locally. No timelock, no delay, no guardian. `_version` increments inside `_authorizeUpgrade`, so version numbers are a weak audit trail but no constraint.

Per the program's exclusions, "concerns about the authority of documented permissioned roles acting within it" are ineligible — so state this as a **risk-model note** rather than a submission, and focus submissions on the `__gap` and layout-compatibility angle: verify with the OZ upgrades validator that each live implementation's storage layout is compatible with its predecessor, and that `__gap[64]` was reduced when variables were appended. A layout incompatibility *is* a concrete finding.

---

## 8. Invariants to test and fuzz

There is no test suite in the repo. Everything below needs to be written from scratch against a mainnet fork.

### Solvency (the core claim)
1. `USST.totalSupply()` on Ethereum + BSC == Σ over all live YLD NFTs of `stableValueNet`. **H-3 breaks this** — this is the invariant to weaponise.
2. For each asset: `oracle.fetchForwardPrice(VaultData.assetDepositNet) >= VaultData.depositValueUSD`.
3. For each asset: `registry.fetchDeposits(assetID)` == Σ `stableValueNet` of that asset's live NFTs. **H-3 breaks this.**
4. For each vault: `token.balanceOf(vault) >= assetDepositNet + depositFees + withdrawFees + yieldFees + insuranceFees` (in comparable units).
5. `registry.fetchDeposits(assetID) <= assetData[assetID].limit` after every deposit.
6. `VaultData.cumilativeHairCutValue` is monotonically consistent with the sum of live positions' `haircutAmount`.

### Deposit / withdraw round-trip
7. `deposit` then `withdraw` after `yieldDuration` returns the user's principal minus exactly `depositFee + insuranceFee + haircut + withdrawFee` — never more.
8. A round-trip can never return **more** collateral than was deposited (rounding always favours the protocol) across all decimal combinations of USDY (18) and OUSG (18).
9. `deposit(v)` then immediate `withdraw` reverts with `WithdrawDurationNotReached`.
10. For LT1: withdrawal succeeds at exactly `depositTimestamp + yieldDuration` and at exactly `depositTimestamp + duration`, and reverts at `duration + 1`.
11. For LT1: `withdrawExpired` reverts at exactly `depositTimestamp + duration` and succeeds at `+1`. (Boundary verified by reading; pin it with a test.)
12. `withdrawExpired` can be called **at most once** per tokenID. **Currently fails under H-2 + H-3.**

### Yield accounting
13. Σ over all ids of `calculateRewardsEarned(id)` <= reward tokens held by the distributor.
14. `totalSupply` == Σ `stakingData[id].balance` over all staked ids. **H-2 breaks this.**
15. `enableStaking` on a fresh id never grants a claim on rewards distributed before it.
16. `enableYield(id)` twice does not change that id's yield share. **Currently fails (H-2).**
17. `disableYield(id)` followed by `withdraw(id)` succeeds. **Currently fails (H-2).**
18. `distributeReward` with `totalSupply == 0` reverts cleanly rather than stranding tokens (H-9).
19. `rewardIndex` is monotonically non-decreasing.
20. A distribution too small to move `rewardIndex` either reverts or does not consume tokens (H-9).

### Access control
21. Every function on the Vaults reverts for an unprivileged caller. **`emergencyWithdraw` and `withdrawFees` currently do not (H-4).**
22. `deposit(v, other)` reverts unless `msg.sender == other` or an explicit delegation exists. **Currently does not (H-5).**
23. `Core.put` / `Core.exit` revert for any caller that is not the registered Issuer of that `assetID`.
24. `Register.incrementAssetDeposits` / `decrementAssetDeposits` revert for any caller other than `Core`.
25. `Distributor.distributeReward` reverts for any caller other than that asset's Vault.
26. `USST.burn` / `YLD.burn` revert without `MINTER_ROLE`.
27. `withdraw(tokenID)` reverts for a non-owner.

### State machine
28. `EMERGENCY_STOP` can be reached from `ENABLED` and `DISABLED`, and **is unreachable in reverse**. (Confirms H-4; assert it so a fix is detectable.)
29. All user-facing entry points revert when the asset is not `ENABLED`.
30. `setupAsset` is one-shot per assetID.
31. `setupAsset` rejects `yieldDuration > duration`, zero addresses, and any fee > `FEES_CONSTANT`.
32. Changing fees via `setFees` does **not** alter already-minted NFTs' snapshotted `MetaData.Fees`.

### Arithmetic and decimals
33. `normalizeToDecimals18` / `convertFrom18Decimals` round-trip without loss for 6-, 8-, and 18-decimal tokens.
34. `fetchForwardPrice(fetchInversePrice(x)) ≈ x` within a bounded tolerance; document the tolerance.
35. `decrementAssetDeposits` never underflows under any legitimate sequence.
36. `depositValueUSD -= stableValueNet + haircutAmount` never underflows.

---

## 9. Token contracts

### `STBL_USST` (ERC-20, 365 lines, identical on Ethereum and BSC)

Roles: `MINTER_ROLE`, `BRIDGE_ROLE`, `PAUSE_ROLE`, `LIST_MANAGER_ROLE`, `UPGRADER_ROLE`, `DEFAULT_ADMIN_ROLE`.

| Function | Gate | Note |
|---|---|---|
`mint(to, amt)` | `whenNotPaused onlyRole(MINTER_ROLE)` | **No supply cap** |
`burn(from, amt)` | `whenNotPaused onlyRole(MINTER_ROLE)` | **No allowance check — burns from anyone** |
`bridgeMint` / `bridgeBurn` | `whenNotPaused onlyRole(BRIDGE_ROLE)` | Cross-chain supply authority |
`pause` / `unpause` | `onlyRole(PAUSE_ROLE)` | |
`enableBlacklist` / `disableBlacklist` | `onlyRole(LIST_MANAGER_ROLE)` | |
`_update(from, to, value)` | override | Reverts on blacklisted `from` **or** `to` |

Also implements ERC-20 Permit (`nonces` override). Two consequences worth stating: **USST has no cap**, so `MINTER_ROLE` (held by Core) plus H-6 is unlimited mint; and **`burn` needs no approval**, so `MINTER_ROLE` can destroy any holder's balance.

**Cross-chain trust:** BSC USST is byte-identical and has no Core/Register behind it. Total USST supply across both chains is therefore whatever `BRIDGE_ROLE` says it is. The bridge itself is **not in scope** (§12), but total-supply solvency (invariant 1) spans both chains — a submission must account for the BSC leg.

### `STBL_YLD` (ERC-721, 370 lines)

`nftCtr` (public, monotonic), per-token `YLD_Metadata`, `getNFTData(id)`, `tokenURI`, `setBaseURI` (admin).

| Function | Gate |
|---|---|
`mint(to, metadata)` | `whenNotPaused onlyRole(MINTER_ROLE)` → returns new id |
`burn(from, id)` | `whenNotPaused onlyRole(MINTER_ROLE)`, requires `ownerOf(id) == from` |
`disableNFT(id)` / `enableNFT(id)` | `whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE)` |

**`disableNFT` is a per-user freeze.** It sets `isDisabled`, which makes both `iWithdraw` (`STBL_YLDDisabled`) and `claim` revert. `DEFAULT_ADMIN_ROLE` can therefore freeze any single position's principal *and* yield, indefinitely. `enableNFT` reverses it, so it is not permanent — but there is no timelock and no user recourse. Also note `withdrawExpired` explicitly **skips** `claim` when `isDisabled` is true, so a disabled NFT that expires loses its accrued yield entirely while the treasury still takes the collateral.

### `STBL_Token` (ERC-20, 307 lines, identical on Ethereum and BSC)

`MAX_CAP = 10**28` enforced in both `mint` and `bridgeMint`. Otherwise the same role set as USST minus the blacklist. Governance/value token; not part of the mint/redeem path.

---

## 10. Program terms that shape what to submit

From `security-research-program.md`:

**Eligible:** theft/loss/permanent locking of funds; unauthorized transactions or privilege escalation; transaction or accounting manipulation; business-logic flaws violating intended behavior; reentrancy; harmful transaction ordering; arithmetic overflow/underflow.

**Excluded:** theoretical issues without a working demonstration; compiler-version observations alone; **defects solely in imported third-party contracts**; style/gas/maintainability; **issues exploitable only through front-running**.

**Hard requirements:** submit within **24 hours of discovery** through a private channel; include a **runnable proof of concept**; keep everything confidential **even after remediation** unless written permission is given; **"Reports generated with AI without a runnable proof of concept are not eligible."**

Reading this against the leads above:

- H-1 through H-8 map cleanly onto eligible classes (permanent locking, unauthorized transactions, accounting manipulation, reentrancy).
- H-11 is style/naming and will be closed — record it, do not submit it.
- H-13 will likely be closed as documented-role authority; submit only the storage-layout angle.
- The **"defects solely in imported third-party contracts"** exclusion matters: the OZ base contracts and the USDY/OUSG tokens are out. But H-1's exploitability *depends on* USDY/OUSG behaviour — frame it as a defect in STBL's CEI ordering that a third-party token's behaviour makes reachable, not as a token defect.
- The **front-running** exclusion likely covers parts of H-10 (claim timing around NFT transfers). Frame H-10 as missing settlement-on-transfer, not as a race.
- **Every submission needs a Foundry PoC.** The repo gives you no scaffolding — you will need to write `foundry.toml`, fork-pin a block, fetch the missing libs and interfaces, and impersonate role holders.

---

## 11. Conventions that affect review

- **Filenames say `-Proxy.sol` but contain implementation source.** The proxies themselves are not in the repo.
- **`^0.8.20` floating pragma** — checked arithmetic throughout, so every `-=` and `+=` is a potential revert-DoS rather than a wrap. Several leads (H-2, H-3, H-6) turn on exactly that.
- **`_msgSender()` ≠ `msg.sender`** in this codebase, and which one is used varies by function (H-12). Build the table before reasoning about any authorisation path.
- **All role checks route through the Register**, not local `AccessControl`, on the Issuers/Vaults/Distributors. `onlyRole` on those contracts would be wrong; `registry.hasRole` is the pattern.
- **Fees are snapshotted into `YLD_Metadata` at deposit** and used for the entire position lifecycle. Later `setFees` calls do not retroactively apply. Confirm this with invariant 32 — it is a good property and worth verifying rather than assuming.
- **`FEES_CONSTANT`** is the fee denominator (in the missing `STBL_AssetDefinitionLib`). Its value determines whether fee math can round to zero. Fetch it.
- **Two USD-denominated and two asset-denominated accumulators coexist** in `VaultStruct` (`depositValueUSD` and `cumilativeHairCutValue` in USD; `assetDepositGross`/`assetDepositNet` and the four fee counters in asset units). Mixing them is the most likely source of a real accounting bug. Every `oracle.fetchInversePrice` / `fetchForwardPrice` call is a unit boundary — enumerate them all.
- Note the misspelling **`cumilativeHairCutValue`** in `VaultStruct` — useful for grepping.

---

## 12. What is missing from the repo and from scope

Both matter, for different reasons.

### Missing from the repo (fetchable — fix before working)
Interfaces, all `lib/` files (`STBL_AssetDefinitionLib`, `STBL_Decoder`, `STBL_OracleLib`, `DecimalConverter`, error libs), the OZ bases, and the proxy contracts. The download script already parses the full `sources` map; change `mainSource(...)` to write every entry. Without these, `calculateDepositFees`, `calculateYieldFee`, `isIssuer`, `isVault`, `isActive`, `MULTIPLIER`, `FEES_CONSTANT`, and all decimal conversion are unreadable — and several leads above cannot be closed.

### Missing from the scope table (a real gap in the program)

**The price oracles are not in scope.** Every Vault calls `iSTBL_PT1_AssetOracle(AssetData.oracle).fetchForwardPrice(...)` and `.fetchInversePrice(...)`, and those two functions determine: how much USST is minted per deposit, how much collateral is returned per withdrawal, the withdrawal solvency gate (H-8), and the yield differential. **The oracle is the single most valuation-critical dependency in the protocol and it is neither in the scope table nor in the repo.** `REGISTER_ROLE` can repoint it with `setOracle(id, addr)`, subject only to `addr != 0`.

Also absent from scope: the **cross-chain bridge** behind `BRIDGE_ROLE` (which governs total USST supply across two chains); the **trusted forwarder**, if any is set (H-12); the **treasury** address, which receives all fees, all expired LT1 collateral, and all emergency drains; and any **timelock or multisig** wrapping the role holders.

*Recommendation to raise with the program:* ask whether the oracles are in scope. A finding in `fetchForwardPrice` is functionally a finding in every Vault, and the current table would let it be closed as out-of-scope. Get that answered in writing before spending effort there.

---

## 13. Live-state verification checklist

Nothing in this repo reflects on-chain state. Do these first — several severities above depend on them.

**On `STBL_Register` (`0xa58b634c10df2665a3de1680675d5bb9065847d2`):**
1. `fetchCounter()` → how many assets actually exist.
2. `fetchAssetData(id)` for every id → decode `AssetDefinition`: status, token, issuer, vault, rewardDistributor, **oracle**, all four fees, `cut`, `limit`, `duration`, `yieldDuration`.
3. `fetchDeposits(id)` for every id → compare against `limit` (invariant 5) and against the sum of live NFTs (invariant 3, **H-3**).
4. `fetchTreasury()`, `fetchCore()`, `fetchUSSTToken()`, `fetchYLDToken()` → confirm they match the scope table.
5. `trustedForwarder()` → **zero or not?** Gates H-12.
6. Role holders for `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE`, `REGISTER_ROLE`, **`SPLITTER_ROLE`**, `YIELD_DISTRIBUTION_ROLE`. Use `RoleGranted` logs — the Register does not appear to use `AccessControlEnumerable`. **`SPLITTER_ROLE` sets H-2's severity; if it is an EOA, argue Critical.**
7. For each role holder: EOA, multisig, or timelock? If multisig, read owners and threshold.

**On each Vault (4 addresses):**
8. `fetchVaultData()` → all of `VaultStruct`. Check invariant 4 against `token.balanceOf(vault)`.
9. `CalculatePriceDifferentiation()` → current distributable yield.
10. Confirm `oracle.fetchForwardPrice(assetDepositNet) >= depositValueUSD` right now (H-8). If any asset is close to the boundary, that is a live pre-freeze condition worth reporting immediately.

**On each YieldDistributor (4 addresses):**
11. `rewardIndex`, `totalSupply`, `previousDistribution`.
12. `token.balanceOf(distributor)` vs Σ `calculateRewardsEarned(id)` (invariant 13).
13. Check `totalSupply == 0` on any asset (H-9).

**On `STBL_YLD` (`0xd33c37a90155be8fcab769e38a563e74bfd70e0b`):**
14. `nftCtr` → total ever minted. Enumerate live NFTs from `Transfer` logs.
15. `getNFTData(id)` for every live id → build the ground-truth position set for invariants 1, 3, 14.
16. How many have `isDisabled == true`? Each is an admin-frozen user.
17. **Count expired LT1 positions** — `depositTimestamp + duration < now` — that are still alive. Each one is either a pending H-3 insolvency or an already-realised one. **This is the single highest-value query in this list.**

**On `STBL_USST` (Ethereum + BSC):**
18. `totalSupply()` on both chains; sum. Compare against invariant 1. **A gap is H-3, quantified.**
19. Role holders for `MINTER_ROLE`, `BRIDGE_ROLE`, `LIST_MANAGER_ROLE`, `PAUSE_ROLE`.
20. `paused()`; any blacklisted addresses (from `enableBlacklist` events).

**Cross-cutting:**
21. Current implementation address behind each of the 19 proxies; confirm each is verified and matches the file in `audit-scope/`. The repo is a single commit with no timestamp guarantee — **an upgrade since then would silently invalidate the whole package.**
22. `version()` on each contract → how many upgrades have occurred.
23. Read the **oracle** implementations (not in scope, not in repo) — at minimum determine whether they are Chainlink-backed, admin-pushed, or NAV-based, and whether they have staleness checks.
24. Total value at risk: `token.balanceOf(vault)` × price, summed across the four vaults. This sizes every severity argument.

---

## 14. Suggested review order

1. **Re-download the full source.** Patch `download-contracts.mjs` to write the entire `sources` map, and also fetch the four oracle implementations and the proxies. Nothing below is reliable without the libs.
2. **Run §13.** Item 17 (expired-but-alive LT1 positions) and item 18 (USST supply vs sum of positions) can turn H-3 from a code-reading finding into a quantified live insolvency. Item 6 sets H-2's severity.
3. **Stand up a Foundry fork harness.** Pin a block, impersonate the role holders you found, and get one clean deposit→withdraw round-trip passing before attempting any exploit. Every submission needs a PoC and the repo gives you nothing.
4. **`STBL_LT1_Issuer.withdrawExpired`** (H-3) — the missing `Core.exit` is the clearest Critical, and the H-2 replay chain is the strongest version of it.
5. **`enableYield` / `disableYield`** (H-2) — eight lines, three defects, and it is the enabler for H-3's replay.
6. **`Vault.emergencyWithdraw` + the terminal `EMERGENCY_STOP`** (H-4). Also grep every contract for other externals with no modifier — two were found in one file, so assume more.
7. **`deposit(uint256, address)`** (H-5) and the empty `withdraw(uint256, address)` (H-7). Both trivial to demonstrate.
8. **The reentrancy ordering** (H-1) — but first settle whether USDY or OUSG can call back. If neither can, write it up as a CEI violation and move on rather than forcing it.
9. **`Core.put` / `Core.exit` missing cross-validation** (H-6), framed as missing checks rather than admin authority.
10. **Unit-boundary audit:** enumerate every `fetchForwardPrice` / `fetchInversePrice` call site and every `normalizeToDecimals18` / `convertFrom18Decimals` call, and verify USD-vs-asset units are never mixed. This is unglamorous and the most likely place a genuine accounting bug hides — the `VaultStruct` mixes both denominations in one struct.
11. **Storage-layout validation** across all 11 UUPS pairs (H-13), and the `__gap[64]` sizing.
12. **Ask the program about oracle scope** (§12) before investing there.

One framing note. This repo is a **scope package, not a codebase** — one commit, no tests, no build, and deliberately truncated source. Treat it as a table of contents for on-chain state, not as the artifact under review. The protocol itself is young, single-audit-unknown, and its central contract (`Core`) mints a stablecoin against a value the caller declares. The density of findings in ~4,700 lines is high: two functions with no access control, one empty function body, one missing burn that breaks the solvency invariant, and a role that can inflate yield and permanently lock withdrawals. Prioritise accordingly, and get PoCs written — without them, none of it is eligible.
