mod strategy_service;

use std::sync::Arc;

use tonic::transport::Server;
use tonic::{Request, Status};
use tonic_web::GrpcWebLayer;

use crate::position::tracker::Tracker;
use crate::proto::autopilot_strategy_server::AutopilotStrategyServer;
use strategy_service::StrategyService;

/// Constant-time byte comparison, so the auth check does not leak the token
/// via response timing. Length is not secret (bearer tokens are fixed-length).
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

pub async fn run(host: &str, port: u16, db: &str) -> anyhow::Result<()> {
    let addr = format!("{host}:{port}").parse()?;
    if host == "0.0.0.0" {
        tracing::warn!("serve bound to 0.0.0.0 (all interfaces) — restrict before exposing");
    }

    let tracker = Arc::new(Tracker::open(db)?);
    let service = StrategyService::new(tracker);

    let expected = std::env::var("LPA_API_TOKEN")
        .ok()
        .filter(|s| !s.is_empty())
        .map(|t| format!("Bearer {t}"));
    if expected.is_none() {
        tracing::warn!("LPA_API_TOKEN unset — serve RPCs are UNAUTHENTICATED");
    }
    let auth = move |req: Request<()>| -> Result<Request<()>, Status> {
        match &expected {
            Some(header) => {
                let got = req
                    .metadata()
                    .get("authorization")
                    .and_then(|v| v.to_str().ok());
                match got {
                    Some(g) if ct_eq(g.as_bytes(), header.as_bytes()) => Ok(req),
                    _ => Err(Status::unauthenticated("missing or invalid bearer token")),
                }
            }
            None => Ok(req),
        }
    };

    tracing::info!(%addr, "lpa serve listening (grpc + grpc-web)");
    Server::builder()
        .accept_http1(true)
        .layer(GrpcWebLayer::new())
        .add_service(AutopilotStrategyServer::with_interceptor(service, auth))
        .serve_with_shutdown(addr, async {
            let _ = tokio::signal::ctrl_c().await;
            tracing::info!("shutdown signal received; draining serve");
        })
        .await?;
    Ok(())
}
