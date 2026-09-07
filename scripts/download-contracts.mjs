#!/usr/bin/env node

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const apiKey = process.env.ETHERSCAN_API_KEY;
if (!apiKey) {
  throw new Error('Set ETHERSCAN_API_KEY before running this script.');
}

const outputRoot = path.resolve('audit-scope');
const targets = [
  ['ethereum', 'STBL_Token-Proxy', '0xb3116013c55d49f575ace3cb0d123f3dbf6cac35'],
  ['bsc', 'STBL_Token-Proxy', '0x8dedf84656fa932157e27c060d8613824e7979e3'],
  ['ethereum', 'STBL_USST-Proxy', '0xf9d82660828d8f5d121b14a9dc9c677d91f60065'],
  ['ethereum', 'STBL_YLD-Proxy', '0xd33c37a90155be8fcab769e38a563e74bfd70e0b'],
  ['ethereum', 'STBL_Register-Proxy', '0xa58b634c10df2665a3de1680675d5bb9065847d2'],
  ['ethereum', 'STBL_Core-Proxy', '0x3c316bcf47c991ba09622d4c2f40f786ab4f46db'],
  ['ethereum', 'STBL_PT1_Issuer-USDY-Proxy', '0xa0e2b352118f9983f3a75ddc9abd996983c93764'],
  ['ethereum', 'STBL_PT1_Vault-USDY-Proxy', '0xd238e964b557bd8f39feba8c2c93d6f428007232'],
  ['ethereum', 'STBL_PT1_YieldDistributor-USDY-Proxy', '0x97fb98a7a7400bc651dec6a02640a36f8bdfaa0b'],
  ['ethereum', 'STBL_LT1_Issuer-USDY-Proxy', '0x916442ebaa1cef4b3f5cd9b7a62170b50c3305c1'],
  ['ethereum', 'STBL_LT1_Vault-USDY-Proxy', '0x5766b5d21bea4de3dda1b935f1740d194babab1f'],
  ['ethereum', 'STBL_LT1_YieldDistributor-USDY-Proxy', '0xcc14f2eddeae2a3c450c7afe328fd7331355dd73'],
  ['ethereum', 'STBL_PT1_Issuer-OUSG-Proxy', '0xf8acf255854c8d36010c849f1702eb350c8c4087'],
  ['ethereum', 'STBL_PT1_Vault-OUSG-Proxy', '0x64bef4478942d8fd62be281707076442aa2d055e'],
  ['ethereum', 'STBL_PT1_YieldDistributor-OUSG-Proxy', '0x447a8f3608fb2002c1aa8e44b076b7d62b6fa618'],
  ['ethereum', 'STBL_LT1_Issuer-OUSG-Proxy', '0xbac1f4f20847669ba12841a534b2aa053d65373c'],
  ['ethereum', 'STBL_LT1_Vault-OUSG-Proxy', '0x0437ee84ca723ceb7052a8cc73360e21427c42ea'],
  ['ethereum', 'STBL_LT1_YieldDistributor-OUSG-Proxy', '0x50eda4294d9a57b35a9d836faaeb88d1c4fab6c9'],
  ['bsc', 'STBL_USST-Proxy', '0x1171ce10262a60c17507580a3b70b956f20a35de'],
];
const chainIds = { ethereum: 1, bsc: 56 };
const downloaded = new Map();
let lastRequestAt = 0;

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function api(chain, address) {
  const query = new URLSearchParams({
    chainid: String(chainIds[chain]),
    module: 'contract',
    action: 'getsourcecode',
    address,
    apikey: apiKey,
  });
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    const delay = Math.max(0, 400 - (Date.now() - lastRequestAt));
    if (delay) await pause(delay);
    lastRequestAt = Date.now();
    const response = await fetch(`https://api.etherscan.io/v2/api?${query}`);
    const body = await response.json();
    if (body.status === '1' && body.result?.[0]) return body.result[0];
    if (!String(body.result).includes('rate limit') || attempt === 4) {
      throw new Error(body.result || body.message || `HTTP ${response.status}`);
    }
    await pause(attempt * 1_000);
  }
}

function parseSources(sourceCode, fallbackName) {
  let value = sourceCode.trim();
  if (value.startsWith('{{') && value.endsWith('}}')) value = value.slice(1, -1);
  try {
    const parsed = JSON.parse(value);
    if (parsed.sources && typeof parsed.sources === 'object') {
      return Object.entries(parsed.sources).map(([file, source]) => [file, typeof source === 'string' ? source : source.content]);
    }
  } catch {
    // Single-file source code is stored as plain text.
  }
  return [[`${fallbackName || 'Contract'}.sol`, sourceCode]];
}

function mainSource(sources, contractName) {
  const contractPattern = new RegExp(`\\b(?:abstract\\s+)?contract\\s+${contractName}\\b`);
  const exactFile = sources.find(([file]) => path.posix.basename(file) === `${contractName}.sol`);
  return (exactFile ?? sources.find(([, content]) => contractPattern.test(content)) ?? sources[0])[1];
}

async function saveContract(chain, label, address) {
  const key = `${chain}:${address.toLowerCase()}`;
  if (downloaded.has(key)) return downloaded.get(key);

  const promise = (async () => {
    const proxy = await api(chain, address);
    const implementationAddress = proxy.Implementation?.trim();
    if (!implementationAddress || !/^0x[a-fA-F0-9]{40}$/.test(implementationAddress)) {
      throw new Error(`${label} (${address}) does not expose a verified implementation address.`);
    }
    const data = await api(chain, implementationAddress);
    const directoryName = label.replaceAll(' ', '-').replaceAll('/', '-');
    const base = path.join(outputRoot, chain);
    await mkdir(base, { recursive: true });

    const { SourceCode } = data;
    const sources = parseSources(SourceCode, data.ContractName);
    await writeFile(path.join(base, `${directoryName}.sol`), mainSource(sources, data.ContractName));
    return { chain, address, implementationAddress };
  })();
  downloaded.set(key, promise);
  return promise;
}

for (const [chain, label, address] of targets) {
  await saveContract(chain, label, address);
}

await mkdir(outputRoot, { recursive: true });
console.log(`Downloaded ${downloaded.size} unique contract addresses.`);
