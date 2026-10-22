// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue explicit VPN route. Stream purposes are consumed even when dialing fails.
use crate::{
    DialFuture, NcmConnector, Purpose, Stream,
    transport::{Binding, dial_bound},
};
use std::{io, net::Ipv4Addr, sync::Mutex};

pub struct LocalVPNConnector {
    interface_index: u32,
    pairing_port: u16,
    local: Ipv4Addr,
    peer: Ipv4Addr,
    next: Mutex<u8>,
}
impl LocalVPNConnector {
    #[cfg(test)]
    pub fn new(interface_index: u32, pairing_port: u16) -> io::Result<Self> {
        Self::configured(
            interface_index,
            pairing_port,
            Ipv4Addr::new(10, 7, 1, 1),
            Ipv4Addr::new(10, 7, 0, 1),
        )
    }
    pub fn configured(
        interface_index: u32,
        pairing_port: u16,
        local: Ipv4Addr,
        peer: Ipv4Addr,
    ) -> io::Result<Self> {
        fn unicast(ip: Ipv4Addr) -> bool {
            matches!(ip.octets()[0], 1..=126 | 128..=223)
        }
        if !unicast(local)
            || !unicast(peer)
            || local == peer
            || interface_index == 0
            || pairing_port == 0
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        Ok(Self {
            interface_index,
            pairing_port,
            local,
            peer,
            next: Mutex::new(0),
        })
    }
    fn consume_port(&self, purpose: Purpose) -> io::Result<u16> {
        let mut next = self
            .next
            .lock()
            .map_err(|_| io::ErrorKind::ConnectionAborted)?;
        let (expected, port) = match purpose {
            Purpose::PairVerify => (0, self.pairing_port),
            Purpose::NegotiatedTunnel { port } if port > 0 => (1, port),
            _ => return Err(io::ErrorKind::InvalidInput.into()),
        };
        if *next != expected {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        *next += 1;
        Ok(port)
    }
}
impl NcmConnector for LocalVPNConnector {
    fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
        Box::pin(async move {
            let target = (self.peer, self.consume_port(purpose)?).into();
            let socket = dial_bound(self.interface_index, self.local, target, Binding::Vpn).await?;
            Ok(Box::new(socket) as Stream)
        })
    }
}

// Retained upstream regression fixtures (GPL-3.0-only).
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_pairing_and_negotiated_ports_no_replay_or_lockdown() {
        assert!(LocalVPNConnector::new(0, 1234).is_err());
        assert!(LocalVPNConnector::new(1, 0).is_err());
        let c = LocalVPNConnector::new(1, 1234).unwrap();
        assert!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 4321 })
                .is_err()
        );
        assert!(c.consume_port(Purpose::LockdownSession).is_err());
        assert_eq!(c.consume_port(Purpose::PairVerify).unwrap(), 1234);
        assert!(c.consume_port(Purpose::PairVerify).is_err());
        assert!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 0 })
                .is_err()
        );
        assert_eq!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 4321 })
                .unwrap(),
            4321
        );
        assert!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 4321 })
                .is_err()
        );
    }
    #[test]
    fn custom_addresses_preserve_octets_and_reject_invalid_peers() {
        let local = Ipv4Addr::from(0x0a080101u32);
        let peer = Ipv4Addr::from(0x0a080001u32);
        let c = LocalVPNConnector::configured(77, 4321, local, peer).unwrap();
        assert_eq!(c.local.octets(), [10, 8, 1, 1]);
        assert_eq!(c.peer.octets(), [10, 8, 0, 1]);
        for bad in [
            Ipv4Addr::UNSPECIFIED,
            Ipv4Addr::LOCALHOST,
            Ipv4Addr::new(224, 0, 0, 1),
            Ipv4Addr::BROADCAST,
            local,
        ] {
            assert!(LocalVPNConnector::configured(77, 4321, local, bad).is_err());
        }
    }
    #[tokio::test]
    async fn missing_interface_fails_without_default_routing_or_retry() {
        let c = LocalVPNConnector::new(u32::MAX, 1234).unwrap();
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        assert!(c.connect(Purpose::PairVerify).await.is_err());
    }
}
