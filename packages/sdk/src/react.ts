import { useEffect, useState } from "react";
import type { AutopilotClient } from "./client.js";
import type { PositionState } from "./generated/autopilot_pb.js";

export type RiskLevel = "safe" | "warning" | "critical";

export interface UsePosition {
  state: PositionState | null;
  error: Error | null;
  inRange: boolean;
  ilPercent: number;
  riskLevel: RiskLevel;
}

export function usePosition(client: AutopilotClient, positionId: string): UsePosition {
  const [state, setState] = useState<PositionState | null>(null);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!positionId) return;
    const ctrl = new AbortController();
    (async () => {
      try {
        for await (const s of client.streamPositions({ positionIds: [positionId] }, { signal: ctrl.signal })) {
          setState(s);
        }
      } catch (e) {
        if (!ctrl.signal.aborted) setError(e as Error);
      }
    })();
    return () => ctrl.abort();
  }, [client, positionId]);

  const ilPercent = state?.ilPercent ?? 0;
  const inRange = state?.inRange ?? false;
  const riskLevel: RiskLevel = !state
    ? "safe"
    : !inRange || Math.abs(ilPercent) > 10
      ? "critical"
      : Math.abs(ilPercent) > 5
        ? "warning"
        : "safe";

  return { state, error, inRange, ilPercent, riskLevel };
}
