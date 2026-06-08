import { createClient, type Client } from "@connectrpc/connect";
import { createGrpcWebTransport } from "@connectrpc/connect-web";
import { AutopilotStrategy } from "./generated/autopilot_pb.js";

export type AutopilotClient = Client<typeof AutopilotStrategy>;

export function createAutopilotClient(baseUrl: string): AutopilotClient {
  return createClient(AutopilotStrategy, createGrpcWebTransport({ baseUrl }));
}
