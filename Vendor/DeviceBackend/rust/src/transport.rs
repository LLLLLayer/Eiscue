// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue transport implementation. Existing upstream regression fixtures are retained below.
use std::{
    future::Future,
    io,
    net::{Ipv4Addr, SocketAddr},
    pin::Pin,
    sync::{Arc, Mutex, Weak},
    task::{Context, Poll, Waker},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpSocket,
};

pub type Stream = Box<dyn idevice::ReadWrite>;
pub type DialFuture<'a> = Pin<Box<dyn Future<Output = io::Result<Stream>> + Send + 'a>>;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Purpose {
    PairVerify,
    NegotiatedTunnel { port: u16 },
    LockdownSession,
}
pub trait NcmConnector: Send + Sync {
    fn connect(&self, purpose: Purpose) -> DialFuture<'_>;
}

#[derive(Default)]
struct Waiters(Mutex<[Option<Waker>; 2]>);
#[derive(Default)]
struct GateState {
    closed: bool,
    streams: Vec<Weak<Waiters>>,
}
#[derive(Default)]
pub(crate) struct Gate {
    state: Mutex<GateState>,
}
impl Gate {
    pub fn is_closed(&self) -> bool {
        self.state.lock().map_or(true, |state| state.closed)
    }
    pub fn close(&self) {
        let streams = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            state.closed = true;
            std::mem::take(&mut state.streams)
        };
        for stream in streams.into_iter().filter_map(|stream| stream.upgrade()) {
            let pending = {
                let mut slots = stream.0.lock().unwrap_or_else(|e| e.into_inner());
                std::mem::take(&mut *slots)
            };
            for waker in pending.into_iter().flatten() {
                waker.wake();
            }
        }
    }
    fn register(&self, waiters: &Waiters, direction: usize, cx: &Context<'_>) -> io::Result<()> {
        let state = self
            .state
            .lock()
            .map_err(|_| io::ErrorKind::ConnectionAborted)?;
        if state.closed {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        let mut slots = waiters
            .0
            .lock()
            .map_err(|_| io::ErrorKind::ConnectionAborted)?;
        slots[direction] = Some(cx.waker().clone());
        Ok(())
    }
}
pub(crate) struct Owner(pub Arc<Gate>);
impl Default for Owner {
    fn default() -> Self {
        Owner(Arc::default())
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.0.close();
    }
}

pub(crate) struct Gated {
    inner: Stream,
    gate: Arc<Gate>,
    waiters: Arc<Waiters>,
}
impl std::fmt::Debug for Gated {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("EiscueTransport")
    }
}
impl Gated {
    pub fn new(inner: Stream, gate: Arc<Gate>) -> Self {
        let waiters = Arc::new(Waiters::default());
        {
            let mut state = gate.state.lock().unwrap_or_else(|e| e.into_inner());
            state.streams.retain(|entry| entry.strong_count() > 0);
            if !state.closed {
                state.streams.push(Arc::downgrade(&waiters));
            }
        }
        Self {
            inner,
            gate,
            waiters,
        }
    }
}
impl AsyncRead for Gated {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        self.gate.register(&self.waiters, 0, cx)?;
        Pin::new(&mut self.inner).poll_read(cx, output)
    }
}
impl AsyncWrite for Gated {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.gate.register(&self.waiters, 1, cx)?;
        Pin::new(&mut self.inner).poll_write(cx, bytes)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.gate.register(&self.waiters, 1, cx)?;
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // Local shutdown remains possible after authority has been revoked.
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
pub(crate) struct OperationGuard(pub Option<Arc<Gate>>);
impl Drop for OperationGuard {
    fn drop(&mut self) {
        if let Some(gate) = &self.0 {
            gate.close();
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) enum Binding {
    Vpn,
    Usb,
    #[cfg(any(test, feature = "offline-fixtures"))]
    Loopback,
}
pub(crate) async fn dial_bound(
    index: u32,
    local: Ipv4Addr,
    peer: SocketAddr,
    binding: Binding,
) -> io::Result<tokio::net::TcpStream> {
    let socket = TcpSocket::new_v4()?;
    bind_socket(&socket, index, local, binding)?;
    socket.bind(SocketAddr::from((local, 0)))?;
    let connected = tokio::time::timeout(Duration::from_secs(4), socket.connect(peer))
        .await
        .map_err(|_| io::ErrorKind::TimedOut)??;
    if connected.local_addr()?.ip() != local || connected.peer_addr()? != peer {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    connected.set_nodelay(true)?;
    Ok(connected)
}
#[cfg(target_vendor = "apple")]
fn bind_socket(
    socket: &TcpSocket,
    index: u32,
    local: Ipv4Addr,
    binding: Binding,
) -> io::Result<()> {
    use std::{ffi::CStr, os::fd::AsRawFd};
    #[cfg(any(test, feature = "offline-fixtures"))]
    if matches!(binding, Binding::Loopback) && index == 0 && local.is_loopback() {
        return Ok(());
    }
    if index == 0 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    struct Addresses(*mut libc::ifaddrs);
    impl Drop for Addresses {
        fn drop(&mut self) {
            unsafe { libc::freeifaddrs(self.0) };
        }
    }
    let mut addresses = Addresses(std::ptr::null_mut());
    if unsafe { libc::getifaddrs(&mut addresses.0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut cursor = addresses.0;
    let mut found = 0;
    while let Some(row) = unsafe { cursor.as_ref() } {
        cursor = row.ifa_next;
        if row.ifa_name.is_null() || row.ifa_addr.is_null() {
            continue;
        }
        if unsafe { libc::if_nametoindex(row.ifa_name) } != index
            || unsafe { (*row.ifa_addr).sa_family } != libc::AF_INET as u8
        {
            continue;
        }
        let address = unsafe { &*row.ifa_addr.cast::<libc::sockaddr_in>() };
        if address.sin_addr.s_addr.to_ne_bytes() != local.octets() {
            continue;
        }
        let flags = row.ifa_flags as i32;
        if flags & (libc::IFF_UP | libc::IFF_RUNNING) != libc::IFF_UP | libc::IFF_RUNNING
            || flags & libc::IFF_LOOPBACK != 0
        {
            continue;
        }
        let accepted = match binding {
            Binding::Vpn => {
                flags & libc::IFF_POINTOPOINT != 0
                    && unsafe { CStr::from_ptr(row.ifa_name) }
                        .to_bytes()
                        .starts_with(b"utun")
            }
            Binding::Usb => {
                flags & libc::IFF_POINTOPOINT == 0
                    && !row.ifa_netmask.is_null()
                    && unsafe { &*row.ifa_netmask.cast::<libc::sockaddr_in>() }
                        .sin_addr
                        .s_addr
                        .to_ne_bytes()
                        == [255, 255, 255, 0]
            }
            #[cfg(any(test, feature = "offline-fixtures"))]
            Binding::Loopback => false,
        };
        found += usize::from(accepted);
    }
    if found != 1 {
        return Err(io::ErrorKind::AddrNotAvailable.into());
    }
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            libc::IP_BOUND_IF,
            (&index as *const u32).cast(),
            std::mem::size_of::<u32>() as libc::socklen_t,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(not(target_vendor = "apple"))]
fn bind_socket(_: &TcpSocket, index: u32, local: Ipv4Addr, binding: Binding) -> io::Result<()> {
    #[cfg(any(test, feature = "offline-fixtures"))]
    if matches!(binding, Binding::Loopback) && index == 0 && local.is_loopback() {
        return Ok(());
    }
    let _ = (index, local, binding);
    Err(io::ErrorKind::Unsupported.into())
}

// Retained upstream regression fixture (GPL-3.0-only).
#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;
    #[tokio::test]
    async fn eiscue_close_wakes_every_live_stream_and_rejects_late_streams() {
        let owner = Owner::default();
        let mut reads = Vec::new();
        let mut peers = Vec::new();
        for _ in 0..32 {
            let (socket, peer) = tokio::io::duplex(16);
            peers.push(peer);
            let mut guarded = Gated::new(Box::new(socket), owner.0.clone());
            reads.push(tokio::spawn(async move { guarded.read(&mut [0; 1]).await }));
        }
        tokio::task::yield_now().await;
        owner.0.close();
        for read in reads {
            let failure = tokio::time::timeout(Duration::from_secs(1), read)
                .await
                .unwrap()
                .unwrap()
                .unwrap_err();
            assert_eq!(failure.kind(), io::ErrorKind::ConnectionAborted);
        }
        let (socket, _peer) = tokio::io::duplex(16);
        let mut late = Gated::new(Box::new(socket), owner.0.clone());
        assert_eq!(
            late.read(&mut [0; 1]).await.unwrap_err().kind(),
            io::ErrorKind::ConnectionAborted
        );
        drop(peers);
    }
    #[tokio::test]
    async fn cancellation_wakes_pending_read_without_network() {
        let (stream, _peer) = tokio::io::duplex(64);
        let owner = Owner::default();
        let mut stream = Gated::new(Box::new(stream), owner.0.clone());
        let task = tokio::spawn(async move {
            let mut b = [0];
            stream.read(&mut b).await
        });
        tokio::task::yield_now().await;
        drop(owner);
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_millis(100), task)
                .await
                .unwrap()
                .unwrap()
                .unwrap_err()
                .kind(),
            io::ErrorKind::ConnectionAborted
        );
    }
}
