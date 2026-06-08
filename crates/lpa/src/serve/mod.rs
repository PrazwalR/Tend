mod strategy_service;

use tonic::transport::Server;
use tonic_web::GrpcWebLayer;

use crate::proto::autopilot_strategy_server::AutopilotStrategyServer;
use strategy_service::StrategyService;

pub async fn run(port: u16) -> anyhow::Result<()> {
    let addr = format!("0.0.0.0:{port}").parse()?;
    tracing::info!(%addr, "lpa serve listening (grpc + grpc-web)");
    Server::builder()
        .accept_http1(true)
        .layer(GrpcWebLayer::new())
        .add_service(AutopilotStrategyServer::new(StrategyService::default()))
        .serve(addr)
        .await?;
    Ok(())
}
