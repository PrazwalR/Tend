import { createAutopilotClient } from "./client.js";

const baseUrl = process.env.LPA_URL ?? "http://localhost:50051";
const token = process.env.LPA_API_TOKEN;
const client = createAutopilotClient(baseUrl, token);

const reg = await client.registerPosition({
  owner: "0x1111111111111111111111111111111111111111",
  poolKey: {
    currency0: "0x0000000000000000000000000000000000000001",
    currency1: "0x0000000000000000000000000000000000000002",
    fee: 3000,
    tickSpacing: 60,
    hooks: "0x0000000000000000000000000000000000000000",
  },
  tickRange: { tickLower: -600, tickUpper: 600 },
  config: {
    strategy: 1,
    ilThresholdPct: 5,
    feeCaptureRatio: 0.5,
    bollingerPeriod: 200,
    bollingerStddev: 2,
    maxGasUsd: 50,
    autoCompoundFees: true,
    useFlashbots: true,
  },
  chainId: "8453",
});
console.log(JSON.stringify({ step: "register", positionId: reg.positionId, success: reg.success }));

const cfg = await client.getPositionConfig({ positionId: reg.positionId });
console.log(JSON.stringify({ step: "getConfig", strategy: cfg.strategy, ilThresholdPct: cfg.ilThresholdPct }));

for await (const s of client.streamPositions({ positionIds: [reg.positionId] })) {
  console.log(
    JSON.stringify({ step: "stream", positionId: s.positionId, inRange: s.inRange, currentTick: s.currentTick }),
  );
  break;
}
