// SPDX-License-Identifier: GPL-3.0-only
//! Eiscue pinned Lockdown client. Retained upstream TLS fixtures are identified below.
use crate::{NcmConnector, Purpose, Stream};
use plist::{Dictionary, Value};
use rustls::{
    ClientConfig, DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{ring, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime, pem::PemObject},
};
use std::{future::Future, io::Cursor, sync::Arc, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use zeroize::Zeroizing;
const LIMIT: usize = 64 * 1024;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Failure {
    Identity,
    Connect,
    StartSession,
    PeerRejected,
    SessionTls,
    StopSession,
    Closed,
}
pub struct ExistingIdentity {
    host_id: String,
    system_buid: String,
    device_certificate: CertificateDer<'static>,
    host_certificate: CertificateDer<'static>,
    host_key: Zeroizing<Vec<u8>>,
}
fn identifier(value: &str) -> bool {
    (1..=256).contains(&value.len())
        && value
            .as_bytes()
            .iter()
            .all(|byte| matches!(*byte, 33..=126))
}
struct Record(Dictionary);
impl Record {
    fn string(&self, field: &str) -> Result<String, Failure> {
        self.0
            .get(field)
            .and_then(Value::as_string)
            .filter(|text| identifier(text))
            .map(String::from)
            .ok_or(Failure::Identity)
    }
    fn bytes(&self, field: &str) -> Result<&[u8], Failure> {
        self.0
            .get(field)
            .and_then(Value::as_data)
            .filter(|data| (1..=LIMIT).contains(&data.len()))
            .ok_or(Failure::Identity)
    }
    fn certificate(&self, field: &str) -> Result<CertificateDer<'static>, Failure> {
        CertificateDer::from_pem_slice(self.bytes(field)?).map_err(|_| Failure::Identity)
    }
}
impl ExistingIdentity {
    pub fn from_plist(encoded: &[u8], expected_udid: &str) -> Result<Self, Failure> {
        if encoded.is_empty() || encoded.len() > 1024 * 1024 || !identifier(expected_udid) {
            return Err(Failure::Identity);
        }
        let record = Value::from_reader(Cursor::new(encoded))
            .ok()
            .and_then(Value::into_dictionary)
            .map(Record)
            .ok_or(Failure::Identity)?;
        if let Some(value) = record.0.get("UDID") {
            if value.as_string() != Some(expected_udid) {
                return Err(Failure::Identity);
            }
        }
        let identity = Self {
            host_id: record.string("HostID")?,
            system_buid: record.string("SystemBUID")?,
            device_certificate: record.certificate("DeviceCertificate")?,
            host_certificate: record.certificate("HostCertificate")?,
            host_key: Zeroizing::new(record.bytes("HostPrivateKey")?.to_vec()),
        };
        identity.tls_config()?;
        Ok(identity)
    }
    fn tls_config(&self) -> Result<ClientConfig, Failure> {
        let provider = Arc::new(ring::default_provider());
        let verifier = PinnedDevice {
            certificate: self.device_certificate.clone(),
            provider: provider.clone(),
        };
        let key = PrivateKeyDer::from_pem_slice(self.host_key.as_slice())
            .map_err(|_| Failure::Identity)?;
        let builder = ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS12])
            .map_err(|_| Failure::Identity)?;
        let mut configuration = builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_client_auth_cert(vec![self.host_certificate.clone()], key)
            .map_err(|_| Failure::Identity)?;
        configuration.enable_sni = false;
        Ok(configuration)
    }
}
#[derive(Debug)]
struct PinnedDevice {
    certificate: CertificateDer<'static>,
    provider: Arc<rustls::crypto::CryptoProvider>,
}
impl ServerCertVerifier for PinnedDevice {
    fn verify_server_cert(
        &self,
        presented: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        match presented.as_ref() == self.certificate.as_ref() {
            true => Ok(ServerCertVerified::assertion()),
            false => Err(rustls::Error::InvalidCertificate(
                rustls::CertificateError::ApplicationVerificationFailure,
            )),
        }
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            certificate,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            certificate,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}
async fn within<T, E>(
    seconds: u64,
    failure: Failure,
    operation: impl Future<Output = Result<T, E>>,
) -> Result<T, Failure> {
    match tokio::time::timeout(Duration::from_secs(seconds), operation).await {
        Ok(Ok(value)) => Ok(value),
        _ => Err(failure),
    }
}
fn request(operation: &str) -> Dictionary {
    Dictionary::from_iter([
        ("Label", Value::String("EiscueNative".into())),
        ("Request", Value::String(operation.into())),
    ])
}
async fn exchange(socket: &mut Stream, fields: Dictionary) -> Result<Dictionary, ()> {
    let mut outgoing = Vec::with_capacity(1024);
    outgoing.extend_from_slice(&[0; 4]);
    Value::Dictionary(fields)
        .to_writer_xml(&mut outgoing)
        .map_err(|_| ())?;
    let body_size = outgoing.len() - 4;
    if body_size > LIMIT {
        return Err(());
    }
    outgoing[..4].copy_from_slice(&(body_size as u32).to_be_bytes());
    socket.write_all(&outgoing).await.map_err(|_| ())?;
    socket.flush().await.map_err(|_| ())?;
    let mut prefix = [0; 4];
    socket.read_exact(&mut prefix).await.map_err(|_| ())?;
    let incoming_size = u32::from_be_bytes(prefix) as usize;
    if !(1..=LIMIT).contains(&incoming_size) {
        return Err(());
    }
    let mut incoming = vec![0; incoming_size];
    socket.read_exact(&mut incoming).await.map_err(|_| ())?;
    Value::from_reader(Cursor::new(incoming))
        .ok()
        .and_then(Value::into_dictionary)
        .ok_or(())
}
fn session_id(reply: &Dictionary) -> Result<String, Failure> {
    if reply.contains_key("Error") {
        return Err(Failure::PeerRejected);
    }
    let valid = reply.get("Request").and_then(Value::as_string) == Some("StartSession")
        && reply.get("EnableSessionSSL").and_then(Value::as_boolean) == Some(true);
    if !valid {
        return Err(Failure::StartSession);
    }
    reply
        .get("SessionID")
        .and_then(Value::as_string)
        .filter(|id| identifier(id))
        .map(String::from)
        .ok_or(Failure::StartSession)
}
struct Live {
    socket: Stream,
    identifier: String,
}
pub struct Session {
    active: Option<Live>,
}
impl Session {
    pub async fn connect(
        connector: &impl NcmConnector,
        identity: &ExistingIdentity,
    ) -> Result<Self, Failure> {
        let configuration = Arc::new(identity.tls_config()?);
        let mut socket = within(
            4,
            Failure::Connect,
            connector.connect(Purpose::LockdownSession),
        )
        .await?;
        let mut fields = request("StartSession");
        fields.extend([
            ("HostID".into(), identity.host_id.clone().into()),
            ("SystemBUID".into(), identity.system_buid.clone().into()),
        ]);
        let response = within(15, Failure::StartSession, exchange(&mut socket, fields)).await?;
        let identifier = session_id(&response)?;
        let tls = tokio_rustls::TlsConnector::from(configuration);
        let name = ServerName::try_from("Device").map_err(|_| Failure::Identity)?;
        let secured = within(15, Failure::SessionTls, tls.connect(name, socket)).await?;
        Ok(Session {
            active: Some(Live {
                socket: Box::new(secured),
                identifier,
            }),
        })
    }
    pub fn tls_ready(&self) -> bool {
        matches!(self.active, Some(_))
    }
    pub async fn stop(&mut self) -> Result<(), Failure> {
        let Live {
            mut socket,
            identifier,
        } = self.active.take().ok_or(Failure::Closed)?;
        let mut fields = request("StopSession");
        fields.insert("SessionID".into(), identifier.into());
        let response = within(5, Failure::StopSession, exchange(&mut socket, fields)).await?;
        match (
            response.contains_key("Error"),
            response.get("Request").and_then(Value::as_string),
        ) {
            (false, Some("StopSession")) => Ok(()),
            _ => Err(Failure::StopSession),
        }
    }
}

// Retained upstream regression fixtures (GPL-3.0-only), including pinned mTLS.
#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::DialFuture;
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::DuplexStream;
    const HOST: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-host.pem");
    const HOST_KEY: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-host-key.pem");
    const DEVICE: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-device.pem");
    const DEVICE_KEY: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-device-key.pem");
    const ROOT: &[u8] = include_bytes!("../tests/fixtures/lockdown/test-root.pem");
    struct Connector {
        socket: Mutex<Option<DuplexStream>>,
        calls: AtomicUsize,
    }
    impl NcmConnector for Connector {
        fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
            assert_eq!(purpose, Purpose::LockdownSession);
            self.calls.fetch_add(1, Ordering::SeqCst);
            let stream = self.socket.lock().unwrap().take().unwrap();
            Box::pin(async move { Ok(Box::new(stream) as Stream) })
        }
    }
    fn pair_bytes() -> Vec<u8> {
        let mut d = Dictionary::new();
        for (k, v) in [
            ("HostID", "PUBLIC-TEST-HOST"),
            ("SystemBUID", "PUBLIC-TEST-BUID"),
            ("UDID", "PUBLIC-TEST-UDID"),
        ] {
            d.insert(k.into(), v.into());
        }
        for (k, v) in [
            ("DeviceCertificate", DEVICE),
            ("HostCertificate", HOST),
            ("HostPrivateKey", HOST_KEY),
        ] {
            d.insert(k.into(), Value::Data(v.into()));
        }
        let mut bytes = Vec::new();
        Value::Dictionary(d).to_writer_binary(&mut bytes).unwrap();
        bytes
    }
    pub(crate) fn identity() -> ExistingIdentity {
        ExistingIdentity::from_plist(&pair_bytes(), "PUBLIC-TEST-UDID").unwrap()
    }
    pub(crate) async fn read<S: tokio::io::AsyncRead + Unpin>(s: &mut S) -> Dictionary {
        let len = s.read_u32().await.unwrap() as usize;
        assert!(len <= LIMIT);
        let mut data = vec![0; len];
        s.read_exact(&mut data).await.unwrap();
        Value::from_reader(Cursor::new(data))
            .unwrap()
            .into_dictionary()
            .unwrap()
    }
    pub(crate) async fn write<S: tokio::io::AsyncWrite + Unpin>(s: &mut S, d: Dictionary) {
        let mut data = Vec::new();
        Value::Dictionary(d).to_writer_binary(&mut data).unwrap();
        s.write_u32(data.len() as u32).await.unwrap();
        s.write_all(&data).await.unwrap();
        s.flush().await.unwrap();
    }
    pub(crate) fn start_reply() -> Dictionary {
        let mut d = request("StartSession");
        d.insert("EnableSessionSSL".into(), true.into());
        d.insert("SessionID".into(), "PUBLIC-TEST-SESSION".into());
        d
    }
    pub(crate) fn acceptor(wrong_cert: bool) -> tokio_rustls::TlsAcceptor {
        let mut roots = rustls::RootCertStore::empty();
        roots
            .add(CertificateDer::from_pem_slice(ROOT).unwrap())
            .unwrap();
        let provider = Arc::new(ring::default_provider());
        let verifier = rustls::server::WebPkiClientVerifier::builder_with_provider(
            Arc::new(roots),
            provider.clone(),
        )
        .build()
        .unwrap();
        let config = rustls::ServerConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS12])
            .unwrap()
            .with_client_cert_verifier(verifier)
            .with_single_cert(
                vec![
                    CertificateDer::from_pem_slice(if wrong_cert { HOST } else { DEVICE }).unwrap(),
                ],
                PrivateKeyDer::from_pem_slice(if wrong_cert { HOST_KEY } else { DEVICE_KEY })
                    .unwrap(),
            )
            .unwrap();
        tokio_rustls::TlsAcceptor::from(Arc::new(config))
    }
    #[test]
    fn ordinary_record_rejects_peer_mismatch_and_rp_record() {
        assert!(ExistingIdentity::from_plist(&pair_bytes(), "ANOTHER-UDID").is_err());
        assert!(
            ExistingIdentity::from_plist(br#"{"identifier":"rp-only"}"#, "PUBLIC-TEST-UDID")
                .is_err()
        );
        assert!(
            ExistingIdentity::from_plist(&vec![0; 1024 * 1024 + 1], "PUBLIC-TEST-UDID").is_err()
        );
    }
    #[test]
    fn strict_start_session_response() {
        let good = start_reply();
        assert!(session_id(&good).is_ok());
        for key in ["SessionID", "EnableSessionSSL", "Request"] {
            let mut d = good.clone();
            d.remove(key);
            assert_eq!(session_id(&d), Err(Failure::StartSession));
        }
        let mut d = good.clone();
        d.insert("EnableSessionSSL".into(), false.into());
        assert_eq!(session_id(&d), Err(Failure::StartSession));
        d.insert("Error".into(), "InvalidHostID".into());
        assert_eq!(session_id(&d), Err(Failure::PeerRejected));
    }
    #[tokio::test]
    async fn mutual_tls_and_stop_session_on_same_stream() {
        let (a, mut b) = tokio::io::duplex(4096);
        let c = Connector {
            socket: Mutex::new(Some(a)),
            calls: AtomicUsize::new(0),
        };
        let server = tokio::spawn(async move {
            let start = read(&mut b).await;
            assert_eq!(
                start.get("Request").and_then(Value::as_string),
                Some("StartSession")
            );
            assert_eq!(
                start.get("HostID").and_then(Value::as_string),
                Some("PUBLIC-TEST-HOST")
            );
            assert_eq!(
                start.get("SystemBUID").and_then(Value::as_string),
                Some("PUBLIC-TEST-BUID")
            );
            assert!(!start.contains_key("PairRecord"));
            write(&mut b, start_reply()).await;
            let mut tls = acceptor(false).accept(b).await.unwrap();
            assert_eq!(tls.get_ref().1.peer_certificates().unwrap().len(), 1);
            let stop = read(&mut tls).await;
            assert_eq!(
                stop.get("Request").and_then(Value::as_string),
                Some("StopSession")
            );
            assert_eq!(
                stop.get("SessionID").and_then(Value::as_string),
                Some("PUBLIC-TEST-SESSION")
            );
            write(&mut tls, request("StopSession")).await;
        });
        let mut session = Session::connect(&c, &identity()).await.unwrap();
        assert!(session.tls_ready());
        session.stop().await.unwrap();
        assert!(!session.tls_ready());
        assert_eq!(session.stop().await, Err(Failure::Closed));
        assert_eq!(c.calls.load(Ordering::SeqCst), 1);
        server.await.unwrap();
    }
    #[tokio::test]
    async fn mismatched_device_certificate_is_terminal() {
        let (a, mut b) = tokio::io::duplex(4096);
        let c = Connector {
            socket: Mutex::new(Some(a)),
            calls: AtomicUsize::new(0),
        };
        let server = tokio::spawn(async move {
            read(&mut b).await;
            write(&mut b, start_reply()).await;
            assert!(acceptor(true).accept(b).await.is_err());
        });
        assert!(matches!(
            Session::connect(&c, &identity()).await,
            Err(Failure::SessionTls)
        ));
        assert_eq!(c.calls.load(Ordering::SeqCst), 1);
        server.await.unwrap();
    }
    #[tokio::test]
    async fn rejected_session_never_sends_tls_or_pair() {
        let (a, mut b) = tokio::io::duplex(4096);
        let c = Connector {
            socket: Mutex::new(Some(a)),
            calls: AtomicUsize::new(0),
        };
        let server = tokio::spawn(async move {
            read(&mut b).await;
            let mut d = request("StartSession");
            d.insert("Error".into(), "InvalidHostID".into());
            write(&mut b, d).await;
            assert_eq!(
                b.read_u8().await.unwrap_err().kind(),
                std::io::ErrorKind::UnexpectedEof
            );
        });
        assert!(matches!(
            Session::connect(&c, &identity()).await,
            Err(Failure::PeerRejected)
        ));
        assert_eq!(c.calls.load(Ordering::SeqCst), 1);
        server.await.unwrap();
    }
}
