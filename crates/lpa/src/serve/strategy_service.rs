use std::time::{SystemTime, UNIX_EPOCH};

use tonic::{Request, Response, Status};

use crate::proto::autopilot_strategy_server::AutopilotStrategy;
use crate::proto::{
    DeregisterPositionRequest, DeregisterPositionResponse, GetPositionConfigRequest, PingRequest,
    PingResponse, PositionConfig, RegisterPositionRequest, RegisterPositionResponse,
    UpdateConfigRequest, UpdateConfigResponse,
};

#[derive(Default)]
pub struct StrategyService;

#[tonic::async_trait]
impl AutopilotStrategy for StrategyService {
    async fn ping(&self, _req: Request<PingRequest>) -> Result<Response<PingResponse>, Status> {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| Status::internal(e.to_string()))?
            .as_secs();
        Ok(Response::new(PingResponse { timestamp }))
    }

    async fn register_position(
        &self,
        _req: Request<RegisterPositionRequest>,
    ) -> Result<Response<RegisterPositionResponse>, Status> {
        Err(Status::unimplemented("register_position lands in P7"))
    }

    async fn deregister_position(
        &self,
        _req: Request<DeregisterPositionRequest>,
    ) -> Result<Response<DeregisterPositionResponse>, Status> {
        Err(Status::unimplemented("deregister_position lands in P7"))
    }

    async fn get_position_config(
        &self,
        _req: Request<GetPositionConfigRequest>,
    ) -> Result<Response<PositionConfig>, Status> {
        Err(Status::unimplemented("get_position_config lands in P7"))
    }

    async fn update_config(
        &self,
        _req: Request<UpdateConfigRequest>,
    ) -> Result<Response<UpdateConfigResponse>, Status> {
        Err(Status::unimplemented("update_config lands in P7"))
    }
}
