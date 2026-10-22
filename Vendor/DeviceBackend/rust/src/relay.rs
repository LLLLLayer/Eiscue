// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue board relay adapter: one selected discovery generation, no route retry.
use crate::{
    DialFuture, NcmConnector, Purpose, Stream,
    transport::{Binding, dial_bound},
};
use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::Mutex,
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

enum Route {
    Pairing { generation: u32, endpoint: u8 },
    Lockdown,
}
pub struct RelayConnector {
    interface_index: u32,
    route: Route,
    nonce: String,
    next: Mutex<u8>,
    local: Ipv4Addr,
    relay: SocketAddr,
    binding: Binding,
}
impl RelayConnector {
    fn configured(interface_index: u32, route: Route) -> io::Result<Self> {
        if interface_index == 0 {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        Ok(Self {
            interface_index,
            route,
            nonce: uuid::Uuid::new_v4().simple().to_string(),
            next: Mutex::new(0),
            local: Ipv4Addr::new(192, 168, 7, 2),
            relay: SocketAddr::from(([192, 168, 7, 1], 28767)),
            binding: Binding::Usb,
        })
    }
    pub fn new(interface_index: u32, generation: u32, index: u8) -> io::Result<Self> {
        if generation == 0 || index > 15 {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        Self::configured(
            interface_index,
            Route::Pairing {
                generation,
                endpoint: index,
            },
        )
    }
    pub fn new_lockdown(interface_index: u32) -> io::Result<Self> {
        Self::configured(interface_index, Route::Lockdown)
    }
    #[cfg(any(test, feature = "offline-fixtures"))]
    pub(crate) fn loopback(port: u16) -> Self {
        let mut fixture = Self::new(1, 7, 0).unwrap();
        fixture.interface_index = 0;
        fixture.local = Ipv4Addr::LOCALHOST;
        fixture.relay = (Ipv4Addr::LOCALHOST, port).into();
        fixture.binding = Binding::Loopback;
        fixture
    }
    fn preamble(&self, purpose: Purpose) -> io::Result<String> {
        let mut next = self
            .next
            .lock()
            .map_err(|_| io::ErrorKind::ConnectionAborted)?;
        let line = match (&self.route, *next, purpose) {
            (
                Route::Pairing {
                    generation,
                    endpoint,
                },
                0,
                Purpose::PairVerify,
            ) => format!("NR1 OPEN {generation} {endpoint} {}\n", self.nonce),
            (Route::Pairing { .. }, 1, Purpose::NegotiatedTunnel { port }) if port > 0 => {
                format!("NR1 TUNNEL {} {port}\n", self.nonce)
            }
            (Route::Lockdown, 0, Purpose::LockdownSession) => format!("NL1 OPEN {}\n", self.nonce),
            _ => return Err(io::ErrorKind::InvalidInput.into()),
        };
        *next += 1;
        Ok(line)
    }
}
impl NcmConnector for RelayConnector {
    fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
        Box::pin(async move {
            let preamble = self.preamble(purpose)?;
            let mut socket =
                dial_bound(self.interface_index, self.local, self.relay, self.binding).await?;
            let acknowledgement: &[u8] = match self.route {
                Route::Lockdown => b"NL1 OK\n",
                _ => b"NR1 OK\n",
            };
            tokio::time::timeout(Duration::from_secs(4), async {
                socket.write_all(preamble.as_bytes()).await?;
                socket.flush().await?;
                // Read only the acknowledgement: pairing bytes may already follow it.
                let mut received = [0; 7];
                socket.read_exact(&mut received).await?;
                if received != acknowledgement {
                    return Err(io::ErrorKind::ConnectionRefused.into());
                }
                Ok::<_, io::Error>(())
            })
            .await
            .map_err(|_| io::ErrorKind::TimedOut)??;
            Ok(Box::new(socket) as Stream)
        })
    }
}

// Retained upstream regression fixture (GPL-3.0-only).
#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    #[tokio::test]
    async fn exact_two_streams_share_nonce_and_no_extra_bytes_are_consumed() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let c = RelayConnector::loopback(listener.local_addr().unwrap().port());
        let mock = tokio::spawn(async move {
            let mut nonce = String::new();
            for kind in 0..2 {
                let (mut peer, _) = listener.accept().await.unwrap();
                let mut line = Vec::new();
                loop {
                    let b = peer.read_u8().await.unwrap();
                    if b == b'\n' {
                        break;
                    }
                    line.push(b);
                }
                let text = String::from_utf8(line).unwrap();
                let parts: Vec<_> = text.split(' ').collect();
                if kind == 0 {
                    assert_eq!(&parts[..4], &["NR1", "OPEN", "7", "0"]);
                    nonce = parts[4].to_owned();
                } else {
                    assert_eq!(parts, vec!["NR1", "TUNNEL", nonce.as_str(), "54321"]);
                }
                peer.write_all(b"NR1 OK\nNEXT").await.unwrap();
            }
        });
        let mut first = c.connect(Purpose::PairVerify).await.unwrap();
        let mut b = [0; 4];
        first.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"NEXT");
        let mut second = c
            .connect(Purpose::NegotiatedTunnel { port: 54321 })
            .await
            .unwrap();
        second.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"NEXT");
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        assert!(
            c.connect(Purpose::NegotiatedTunnel { port: 54321 })
                .await
                .is_err()
        );
        mock.await.unwrap();
    }
    #[tokio::test]
    async fn relay_rejection_does_not_expose_stream_or_retry() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let c = RelayConnector::loopback(listener.local_addr().unwrap().port());
        let mock = tokio::spawn(async move {
            let (mut p, _) = listener.accept().await.unwrap();
            while p.read_u8().await.unwrap() != b'\n' {}
            p.write_all(b"NR1 ERR rejected\n").await.unwrap();
        });
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        mock.await.unwrap();
    }
}
