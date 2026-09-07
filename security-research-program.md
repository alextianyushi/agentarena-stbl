# STBL Smart Contract Security Research Program

## Overview

STBL is a stablecoin protocol that separates stable principal from yield on-chain. The protocol issues USST as the stable-principal token and YLD as the tokenized-yield token. STBL governance and protocol-value mechanisms are supported by the STBL token.

This document defines the authorized scope, research expectations, and reward framework for responsible security research affecting the deployed STBL smart contracts.

## In-Scope Contracts

All targets below are smart contracts. Findings that can materially affect an in-scope target may be eligible up to **Critical** severity.

| Network | Contract | Address |
| --- | --- | --- |
| Ethereum | STBL_Token (Proxy) | [`0xb3116013c55d49f575ace3cb0d123f3dbf6cac35`](https://etherscan.io/address/0xb3116013c55d49f575ace3cb0d123f3dbf6cac35#code) |
| BNB Smart Chain | STBL_Token (Proxy) | [`0x8dedf84656fa932157e27c060d8613824e7979e3`](https://bscscan.com/address/0x8dedf84656fa932157e27c060d8613824e7979e3#code) |
| Ethereum | STBL_USST (Proxy) | [`0xf9d82660828d8f5d121b14a9dc9c677d91f60065`](https://etherscan.io/address/0xf9d82660828d8f5d121b14a9dc9c677d91f60065#code) |
| BNB Smart Chain | STBL_USST (Proxy) | [`0x1171ce10262a60c17507580a3b70b956f20a35de`](https://bscscan.com/address/0x1171ce10262a60c17507580a3b70b956f20a35de#code) |
| Ethereum | STBL_YLD (Proxy) | [`0xd33c37a90155be8fcab769e38a563e74bfd70e0b`](https://etherscan.io/address/0xd33c37a90155be8fcab769e38a563e74bfd70e0b#code) |
| Ethereum | STBL_Register (Proxy) | [`0xa58b634c10df2665a3de1680675d5bb9065847d2`](https://etherscan.io/address/0xa58b634c10df2665a3de1680675d5bb9065847d2#code) |
| Ethereum | STBL_Core (Proxy) | [`0x3c316bcf47c991ba09622d4c2f40f786ab4f46db`](https://etherscan.io/address/0x3c316bcf47c991ba09622d4c2f40f786ab4f46db#code) |
| Ethereum | STBL_PT1_Issuer-USDY (Proxy) | [`0xa0e2b352118f9983f3a75ddc9abd996983c93764`](https://etherscan.io/address/0xa0e2b352118f9983f3a75ddc9abd996983c93764#code) |
| Ethereum | STBL_PT1_Vault-USDY (Proxy) | [`0xd238e964b557bd8f39feba8c2c93d6f428007232`](https://etherscan.io/address/0xd238e964b557bd8f39feba8c2c93d6f428007232#code) |
| Ethereum | STBL_PT1_YieldDistributor-USDY (Proxy) | [`0x97fb98a7a7400bc651dec6a02640a36f8bdfaa0b`](https://etherscan.io/address/0x97fb98a7a7400bc651dec6a02640a36f8bdfaa0b#code) |
| Ethereum | STBL_LT1_Issuer-USDY (Proxy) | [`0x916442ebaa1cef4b3f5cd9b7a62170b50c3305c1`](https://etherscan.io/address/0x916442ebaa1cef4b3f5cd9b7a62170b50c3305c1#code) |
| Ethereum | STBL_LT1_Vault-USDY (Proxy) | [`0x5766b5d21bea4de3dda1b935f1740d194babab1f`](https://etherscan.io/address/0x5766b5d21bea4de3dda1b935f1740d194babab1f#code) |
| Ethereum | STBL_LT1_YieldDistributor-USDY (Proxy) | [`0xcc14f2eddeae2a3c450c7afe328fd7331355dd73`](https://etherscan.io/address/0xcc14f2eddeae2a3c450c7afe328fd7331355dd73#code) |
| Ethereum | STBL_PT1_Issuer-OUSG (Proxy) | [`0xf8acf255854c8d36010c849f1702eb350c8c4087`](https://etherscan.io/address/0xf8acf255854c8d36010c849f1702eb350c8c4087#code) |
| Ethereum | STBL_PT1_Vault-OUSG (Proxy) | [`0x64bef4478942d8fd62be281707076442aa2d055e`](https://etherscan.io/address/0x64bef4478942d8fd62be281707076442aa2d055e#code) |
| Ethereum | STBL_PT1_YieldDistributor-OUSG (Proxy) | [`0x447a8f3608fb2002c1aa8e44b076b7d62b6fa618`](https://etherscan.io/address/0x447a8f3608fb2002c1aa8e44b076b7d62b6fa618#code) |
| Ethereum | STBL_LT1_Issuer-OUSG (Proxy) | [`0xbac1f4f20847669ba12841a534b2aa053d65373c`](https://etherscan.io/address/0xbac1f4f20847669ba12841a534b2aa053d65373c#code) |
| Ethereum | STBL_LT1_Vault-OUSG (Proxy) | [`0x0437ee84ca723ceb7052a8cc73360e21427c42ea`](https://etherscan.io/address/0x0437ee84ca723ceb7052a8cc73360e21427c42ea#code) |
| Ethereum | STBL_LT1_YieldDistributor-OUSG (Proxy) | [`0x50eda4294d9a57b35a9d836faaeb88d1c4fab6c9`](https://etherscan.io/address/0x50eda4294d9a57b35a9d836faaeb88d1c4fab6c9#code) |

## Eligible Vulnerability Classes

Reports should demonstrate a concrete, unintended smart-contract behavior, such as:

- theft, loss, or permanent locking of funds;
- unauthorized transactions or privilege escalation;
- transaction or accounting manipulation;
- business-logic flaws that violate intended protocol behavior;
- reentrancy;
- harmful transaction ordering or reordering;
- arithmetic overflow or underflow.

## Exclusions

The following are not eligible:

- theoretical issues without a working demonstration or proof of impact;
- outdated or unlocked compiler-version observations alone;
- defects solely in imported third-party contracts;
- style, maintainability, redundant-code, gas-optimization, or general best-practice observations;
- issues exploitable only through front-running.

## Safe Research Rules

- Test only the contracts and assets listed in scope.
- Do not harm availability, degrade services, access personal data, or access or alter another user's data.
- Use accounts and assets you control; keep tests isolated and minimally invasive.
- Do not conduct denial-of-service testing, social engineering, spam, automated form/account abuse, or high-traffic automated scanning.
- Comply with applicable law.
- If a finding depends on a chain-level issue, rewards are considered only for the single highest-severity applicable issue.

## Reporting and Confidentiality

- Submit findings through the designated private reporting channel within 24 hours of discovery.
- Keep the program and all vulnerabilities confidential unless STBL provides written permission to disclose them, including after remediation.
- Include a concise description, impact analysis, reproducible steps, and a runnable proof of concept. Add screenshots or other supporting material when useful.
- Reports generated with AI without a runnable proof of concept are not eligible.

## Eligibility

To qualify for a reward, a researcher must:

- be the first to privately report an eligible vulnerability;
- provide sufficient, precise reproduction steps and evidence;
- not be a current or former STBL employee or contractor.

## Reward Schedule

| Severity | Reward |
| --- | ---: |
| Critical | $20,000 |
| High | $5,000 |
| Medium | $2,000 |
| Low | $200 |

Rewards range from **$200 to $20,000**, subject to validation, impact assessment, and compliance with this program.

## Response Targets

| Milestone | Target |
| --- | ---: |
| Initial response | 3 business days |
| Triage | 3 business days |
| Reward decision | 3 business days |
| Resolution | 14 business days |

---

*Source reference: STBL Smart Contracts public program page, reviewed September 6, 2026. This document is a platform-neutral adaptation; establish a private reporting address before publishing it.*
