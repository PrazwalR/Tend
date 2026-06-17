mod strategy_service;

use tonic::transport::Server;
use tonic_web::GrpcWebLayer;

use crate::proto::autopilot_strategy_server::AutopilotStrategyServer;
use strategy_service::StrategyService;

pub async fn run(host: &str, port: u16) -> anyhow::Result<()> {
    let addr = format!("{host}:{port}").parse()?;
    if host == "0.0.0.0" {
        tracing::warn!("serve bound to 0.0.0.0 (all interfaces) — unauthenticated; restrict before exposing");
    }
    tracing::info!(%addr, "lpa serve listening (grpc + grpc-web)");
    Server::builder()
        .accept_http1(true)
        .layer(GrpcWebLayer::new())
        .add_service(AutopilotStrategyServer::new(StrategyService))
        .serve(addr)
        .await?;
    Ok(())
}
