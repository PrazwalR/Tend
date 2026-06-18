import { createClient, type Client, type Interceptor } from "@connectrpc/connect";
import { createGrpcWebTransport } from "@connectrpc/connect-web";
import { AutopilotStrategy } from "./generated/autopilot_pb.js";

export type AutopilotClient = Client<typeof AutopilotStrategy>;

function bearer(token: string): Interceptor {
  return (next) => (req) => {
    req.header.set("authorization", `Bearer ${token}`);
    return next(req);
  };
}

export function createAutopilotClient(baseUrl: string, token?: string): AutopilotClient {
  const interceptors = token ? [bearer(token)] : [];
  return createClient(AutopilotStrategy, createGrpcWebTransport({ baseUrl, interceptors }));
}
