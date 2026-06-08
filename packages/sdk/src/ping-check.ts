import { createAutopilotClient } from "./client.js";

const baseUrl = process.env.LPA_URL ?? "http://localhost:50051";
const client = createAutopilotClient(baseUrl);
const res = await client.ping({});
console.log(JSON.stringify({ ok: true, timestamp: res.timestamp.toString() }));
