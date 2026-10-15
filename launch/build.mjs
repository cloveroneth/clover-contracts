#!/usr/bin/env node
// Builds the Programmable Custom Launch package for $CLOVER (Ethereum). `pack` selects the live profile and fee
// policy from /v3/capabilities, since the config does not pin a profile version.
//
// Compiles the exact sources with solc 0.8.26+commit.8a97fa7a, writes the Standard JSON input, the four
// compiler artifacts and programmable-launch.config.json. Then:
//   programmable-launch pack --config programmable-launch.config.json --output launch.json
//   programmable-launch validate launch.json --config programmable-launch.config.json [--remote]
//   programmable-launch submit launch.json --config programmable-launch.config.json
// No key, signature or transaction is ever produced here.
//
// Public inputs come from launch.params.json. Environment:
//   CLOVER_SOURCE_REVISION  public 40-char commit of this repository containing these exact sources (required)
//   CLOVER_LAUNCH_NONCE     optional bytes32; a fresh random nonce is used otherwise
import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import solc from "solc";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");

const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90";
const GRAPH_FACTORY = "0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887";
// Programmable platform fee recipient (capabilities.currentTradeFeePolicy.recipient).
const PLATFORM_RECIPIENT = "0xD88539d3c4C460136a733A3Fd60cf6BF269079da";
const NATIVE = "0x0000000000000000000000000000000000000000";
const EXACT_SOLC = "0.8.26+commit.8a97fa7a";

const REMAPPINGS = [
  "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
  "solmate/=lib/solmate/",
  "v4-core/=lib/v4-core/src/",
];
const ENTRYPOINTS = ["src/CloverCanvas.sol", "src/CloverHook.sol", "src/CloverToken.sol", "src/Launchpad.sol"];

const params = JSON.parse(await readFile(path.join(here, "launch.params.json"), "utf8"));
const revision = (process.env.CLOVER_SOURCE_REVISION ?? "").toLowerCase();
if (!/^[0-9a-f]{40}$/.test(revision)) throw new Error("CLOVER_SOURCE_REVISION must be the public 40-char commit");
const nonce = (process.env.CLOVER_LAUNCH_NONCE ?? `0x${randomBytes(32).toString("hex")}`).toLowerCase();
if (!/^0x[0-9a-f]{64}$/.test(nonce) || /^0x0+$/.test(nonce)) throw new Error("nonce must be a nonzero bytes32");
for (const k of ["launchWallet", "protocolRecipient"]) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(params[k] ?? "")) throw new Error(`launch.params.json: ${k} is not an address`);
}

// ------------------------------------------------------------------ sources

function resolveImport(from, spec) {
  if (spec.startsWith(".")) return path.posix.normalize(path.posix.join(path.posix.dirname(from), spec));
  for (const r of REMAPPINGS) {
    const [prefix, target] = r.split("=");
    if (spec.startsWith(prefix)) return target + spec.slice(prefix.length);
  }
  return spec;
}

const sources = new Map();
const pending = [...ENTRYPOINTS];
while (pending.length) {
  const name = pending.shift();
  if (sources.has(name)) continue;
  const content = await readFile(path.join(repo, name), "utf8");
  sources.set(name, content);
  for (const m of content.matchAll(/^\s*import\s+(?:[^"']*\sfrom\s+)?["']([^"']+)["']/gm)) {
    pending.push(resolveImport(name, m[1]));
  }
}

const standardJson = {
  language: "Solidity",
  sources: Object.fromEntries(
    [...sources.entries()]
      .sort(([a], [b]) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
      .map(([name, content]) => [name, { content }]),
  ),
  settings: {
    optimizer: { enabled: true, runs: 1000 },
    evmVersion: "cancun",
    viaIR: false,
    metadata: { bytecodeHash: "none", appendCBOR: false, useLiteralContent: true },
    libraries: {},
    remappings: REMAPPINGS,
    outputSelection: {
      "*": {
        "*": [
          "abi",
          "metadata",
          "evm.bytecode.object",
          "evm.bytecode.linkReferences",
          "evm.deployedBytecode.object",
          "evm.deployedBytecode.linkReferences",
          "evm.deployedBytecode.immutableReferences",
        ],
        "": ["ast"],
      },
    },
  },
};

// ------------------------------------------------------------------ compile

const version = solc.version();
if (!version.startsWith(EXACT_SOLC)) throw new Error(`solc ${version} is not ${EXACT_SOLC}`);
const standardJsonBytes = Buffer.from(`${JSON.stringify(standardJson)}\n`, "utf8");
const output = JSON.parse(solc.compile(standardJsonBytes.toString("utf8")));
const errors = (output.errors ?? []).filter((e) => e.severity === "error");
if (errors.length) throw new Error(errors.map((e) => e.formattedMessage).join("\n"));

// AST id -> state variable name, for the immutable bindings.
const declarations = new Map();
(function walk(node) {
  if (Array.isArray(node)) return node.forEach(walk);
  if (!node || typeof node !== "object") return;
  if (node.nodeType === "VariableDeclaration" && typeof node.id === "number") declarations.set(String(node.id), node.name);
  for (const v of Object.values(node)) if (v && typeof v === "object") walk(v);
})(Object.values(output.sources).map((s) => s.ast));

const g = params.genesis;
const IMMUTABLES = {
  poolManager: { abiType: "address", literal: POOL_MANAGER },
  DEPLOYER: { abiType: "address", literal: GRAPH_FACTORY },
  PLATFORM_RECIPIENT: { abiType: "address", literal: PLATFORM_RECIPIENT },
  PROTOCOL: { abiType: "address", literal: params.protocolRecipient },
  hook: { abiType: "address", target: "hook" },
  canvas: { abiType: "address", target: "canvas" },
  genesisCreator: { abiType: "address", literal: params.protocolRecipient },
  genesisTokenFeeBps: { abiType: "uint16", literal: String(g.tokenFeeBps) },
  genesisCanvasShareBps: { abiType: "uint16", literal: String(g.canvasShareBps) },
  genesisSize: { abiType: "uint8", literal: String(g.size) },
  genesisRentBps: { abiType: "uint16", literal: String(g.rentBps) },
  genesisFadeTime: { abiType: "uint32", literal: String(g.fadeTimeSeconds) },
  genesisStartPrice: { abiType: "uint96", literal: String(g.startPriceWei) },
};

await mkdir(path.join(here, "standard-json"), { recursive: true });
await mkdir(path.join(here, "artifacts"), { recursive: true });
await writeFile(path.join(here, "standard-json/clover.json"), standardJsonBytes);

const artifacts = {};
function emit(sourceName, contractName, targetId) {
  const c = output.contracts?.[sourceName]?.[contractName];
  if (!c?.evm?.bytecode?.object || !c?.evm?.deployedBytecode?.object) throw new Error(`no output for ${contractName}`);
  const runtimeImmutables = Object.keys(c.evm.deployedBytecode.immutableReferences ?? {})
    .sort((a, b) => Number(a) - Number(b))
    .map((immutableId) => {
      const name = declarations.get(immutableId);
      const binding = IMMUTABLES[name];
      if (!binding) throw new Error(`${contractName}: no binding for immutable ${name} (${immutableId})`);
      return { immutableId, ...binding };
    });
  const value = {
    abi: c.abi,
    bytecode: c.evm.bytecode,
    deployedBytecode: c.evm.deployedBytecode,
    metadata: c.metadata,
  };
  artifacts[targetId] = Buffer.from(`${JSON.stringify(value)}\n`, "utf8");
  return { artifact: `launch/artifacts/${targetId}.json`, runtimeImmutables, runtimeSize: c.evm.deployedBytecode.object.length / 2 };
}
const hook = emit("src/CloverHook.sol", "CloverHook", "hook");
const canvas = emit("src/CloverCanvas.sol", "CloverCanvas", "canvas");
const launchpad = emit("src/Launchpad.sol", "Launchpad", "launchpad");
const token = emit("src/CloverToken.sol", "CloverToken", "token");
for (const [id, bytes] of Object.entries(artifacts)) await writeFile(path.join(here, `artifacts/${id}.json`), bytes);
for (const [id, a] of Object.entries({ hook, canvas, launchpad, token })) {
  if (a.runtimeSize > 24576) throw new Error(`${id} runtime is ${a.runtimeSize} bytes, above EIP-170`);
}

// ------------------------------------------------------------------ evidence

const sha256 = (b) => `sha256:${createHash("sha256").update(b).digest("hex")}`;
const evidence = {
  schemaVersion: "clover.launch-build-evidence.v1",
  compiler: version,
  settings: standardJson.settings.optimizer,
  standardJson: sha256(standardJsonBytes),
  artifacts: Object.fromEntries(Object.entries(artifacts).map(([k, v]) => [k, sha256(v)])),
  runtimeSizes: Object.fromEntries(Object.entries({ hook, canvas, launchpad, token }).map(([k, a]) => [k, a.runtimeSize])),
  publicOrigin: { url: params.publicOriginUrl, revision },
};
await mkdir(path.join(here, "evidence"), { recursive: true });
await writeFile(path.join(here, "evidence/build.json"), `${JSON.stringify(evidence, null, 2)}\n`);
for (const f of params.attestationEvidence) await stat(path.join(repo, f.evidence)); // must exist

// ------------------------------------------------------------------ config

const devBuyWei = String(params.devBuyWei ?? "0");
const now = Math.floor(Date.now() / 1000);
const config = {
  schemaVersion: "programmable.launch-pack-config.v3",
  launchWallet: params.launchWallet,
  chainId: "1",
  nonce,
  source: {
    root: ".",
    paths: ["foundry.toml", "lib", "src"],
    sourceLineageNonce: "0",
    publicOrigin: { url: params.publicOriginUrl, revision },
  },
  compilationUnits: [{ compilationUnitId: "clover-solc", standardJson: "launch/standard-json/clover.json" }],
  targets: [
    {
      targetId: "hook",
      compilationUnitId: "clover-solc",
      artifact: hook.artifact,
      applicantSalt: { mode: "deterministic-hook-permission-grind-v1", start: "0", maxAttempts: "262144" },
      constructorArguments: [POOL_MANAGER, PLATFORM_RECIPIENT],
      initializer: { function: "initialize", arguments: [{ target: "launchpad" }, { target: "canvas" }] },
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "hook",
      declaredHookPermissions: [
        "beforeInitialize",
        "beforeAddLiquidity",
        "beforeSwap",
        "afterSwap",
        "beforeSwapReturnDelta",
        "afterSwapReturnDelta",
      ],
      runtimeImmutables: hook.runtimeImmutables,
    },
    {
      targetId: "canvas",
      compilationUnitId: "clover-solc",
      artifact: canvas.artifact,
      applicantSalt: `0x${"01".repeat(32)}`,
      constructorArguments: [params.protocolRecipient],
      initializer: { function: "initialize", arguments: [{ target: "launchpad" }, { target: "hook" }] },
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "other",
      declaredHookPermissions: null,
      runtimeImmutables: canvas.runtimeImmutables,
    },
    {
      targetId: "launchpad",
      compilationUnitId: "clover-solc",
      artifact: launchpad.artifact,
      applicantSalt: `0x${"02".repeat(32)}`,
      constructorArguments: [
        POOL_MANAGER,
        { target: "hook" },
        { target: "canvas" },
        params.protocolRecipient,
        String(g.tokenFeeBps),
        String(g.canvasShareBps),
        String(g.size),
        String(g.rentBps),
        String(g.fadeTimeSeconds),
        String(g.startPriceWei),
      ],
      initializer: { function: "genesis", arguments: [{ target: "token" }] },
      deploymentValueWei: "0",
      initializerValueWei: devBuyWei,
      componentKind: "other",
      declaredHookPermissions: null,
      runtimeImmutables: launchpad.runtimeImmutables,
    },
    {
      targetId: "token",
      compilationUnitId: "clover-solc",
      artifact: token.artifact,
      applicantSalt: `0x${"03".repeat(32)}`,
      constructorArguments: [params.token.name, params.token.symbol, { target: "launchpad" }],
      initializer: null,
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "token",
      declaredHookPermissions: null,
      runtimeImmutables: token.runtimeImmutables,
    },
  ],
  pool: { tokenTargetId: "token", hookTargetId: "hook", fee: 0, tickSpacing: 200, quoteCurrency: NATIVE },
  projectMetadata: {
    schemaVersion: "programmable.project-metadata-input.v1",
    token: params.token,
    presentation: params.presentation,
  },
  launchProfile: {
    schemaVersion: "programmable.direct-native-hook-graph-profile-selection.v3",
    profileId: "programmable.direct-native-hook-graph.v1",
    profileRevision: 3,
    targetRoles: {
      tokenTargetId: "token",
      hookTargetId: "hook",
      initializerTargetId: "launchpad",
      platformFeeBindingTargetId: "hook",
    },
    liquidityModel: {
      schemaVersion: "programmable.direct-native-liquidity-model-intent.v1",
      model: "launch-seeded-concentrated-liquidity",
      declaredLaunchState: "assessment_required",
      liquidityTargetId: "launchpad",
      assessment: {
        schemaVersion: "programmable.direct-native-liquidity-model-assessment.v1",
        status: "required",
        requestClaimsExecution: false,
        requiredVectorIds: [
          "liquidity.seeded.pool-active-liquidity",
          "liquidity.seeded.position-custody-and-withdrawal",
          "liquidity.seeded.buy-and-sell",
        ],
      },
    },
    fundingMode: devBuyWei === "0" ? "none" : "wallet-transaction-value",
    accountingMode: "additive-platform-share",
    assessmentBase: "executed-gross-declared-quote",
    feeCurrency: "declared-quote-currency",
    claimMode: "claim-authority-selected-recipient",
    applicantSelectedBuyHundredthsOfBip: String(g.tokenFeeBps * 100),
    applicantSelectedSellHundredthsOfBip: String(g.tokenFeeBps * 100),
  },
  permitWindow: { validAfter: String(now), deadline: String(now + 24 * 3600 - 60) },
  agentAttestation: {
    agentId: "clover-launch-builder",
    checkedAt: new Date().toISOString(),
    checks: [{ checkId: "exact-build", evidence: "launch/evidence/build.json" }, ...params.attestationEvidence],
  },
};
await writeFile(path.join(repo, "programmable-launch.config.json"), `${JSON.stringify(config, null, 2)}\n`);

process.stdout.write(
  `${JSON.stringify({ compiler: version, sources: sources.size, runtimeSizes: evidence.runtimeSizes, nonce, fundingMode: config.launchProfile.fundingMode }, null, 2)}\n`,
);
