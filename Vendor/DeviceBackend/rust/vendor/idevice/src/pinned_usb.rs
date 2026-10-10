// SPDX-License-Identifier: GPL-3.0-only
//! Desktop-only USB TLS: pin the OS-selected DeviceCertificate and verify
//! handshake signatures. Never use hostname/CA bypass as proof of identity.
use crate::{IdeviceError, pairing_file::PairingFile};
use rustls::{
    ClientConfig, DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{ring, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime, pem::PemObject},
};
use std::sync::Arc;

pub fn create_client_config(pairing_file: &PairingFile) -> Result<ClientConfig, IdeviceError> {
    let mut config = ClientConfig::builder_with_provider(Arc::new(ring::default_provider()))
        .with_protocol_versions(&[&rustls::version::TLS12])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedDevice(
            pairing_file.device_certificate.clone(),
        )))
        .with_client_auth_cert(
            vec![pairing_file.host_certificate.clone()],
            PrivateKeyDer::from_pem_slice(&pairing_file.host_private_key)?,
        )?;
    config.enable_sni = false;
    Ok(config)
}

/// Match the already trusted pairing certificate and verify proof of possession.
/// No hostname/CA assumptions about Apple's locally generated pairing identity.
#[derive(Debug)]
struct PinnedDevice(CertificateDer<'static>);
impl ServerCertVerifier for PinnedDevice {
    fn verify_server_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if cert.as_ref() != self.0.as_ref() {
            return Err(rustls::Error::InvalidCertificate(
                rustls::CertificateError::ApplicationVerificationFailure,
            ));
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            signature,
            &ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            signature,
            &ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::internal::msgs::codec::{Codec, Reader};
    // Public synthetic fixtures, never system trust or a real device's keys.
    const HOST: &[u8] = include_bytes!("../../../tests/fixtures/lockdown/test-host.pem");
    const HOST_KEY: &[u8] = include_bytes!("../../../tests/fixtures/lockdown/test-host-key.pem");
    const DEVICE: &[u8] = include_bytes!("../../../tests/fixtures/lockdown/test-device.pem");
    const DEVICE_KEY: &[u8] =
        include_bytes!("../../../tests/fixtures/lockdown/test-device-key.pem");
    fn trust() -> PairingFile {
        PairingFile {
            device_certificate: CertificateDer::from_pem_slice(DEVICE).unwrap(),
            host_certificate: CertificateDer::from_pem_slice(HOST).unwrap(),
            host_private_key: HOST_KEY.to_vec(),
            root_certificate: CertificateDer::from_pem_slice(HOST).unwrap(),
            root_private_key: vec![],
            system_buid: "TEST".into(),
            host_id: "TEST".into(),
            escrow_bag: None,
            wifi_mac_address: String::new(),
            udid: None,
        }
    }
    #[test]
    fn usb_pins_the_selected_certificate_and_rejects_invalid_signatures() {
        let trusted = trust();
        let verifier = PinnedDevice(trusted.device_certificate.clone());
        let name = ServerName::try_from("Device").unwrap();
        let now = UnixTime::since_unix_epoch(std::time::Duration::from_secs(1));
        assert!(
            verifier
                .verify_server_cert(&trusted.device_certificate, &[], &name, &[], now)
                .is_ok()
        );
        assert!(
            verifier
                .verify_server_cert(&trusted.host_certificate, &[], &name, &[], now)
                .is_err()
        );
        // Encoded RSA-PSS-SHA256 DigitallySigned with an invalid 4-byte proof.
        let signature =
            DigitallySignedStruct::read(&mut Reader::init(&[8, 4, 0, 4, 0, 0, 0, 0])).unwrap();
        assert!(
            verifier
                .verify_tls12_signature(b"test", &trusted.device_certificate, &signature)
                .is_err()
        );
        assert!(
            verifier
                .verify_tls13_signature(b"test", &trusted.device_certificate, &signature)
                .is_err()
        );
    }

    async fn handshake(wrong_certificate: bool) -> bool {
        let (host, device) = tokio::io::duplex(16384);
        let client =
            tokio_rustls::TlsConnector::from(Arc::new(create_client_config(&trust()).unwrap()));
        let server =
            rustls::ServerConfig::builder_with_provider(Arc::new(ring::default_provider()))
                .with_protocol_versions(&[&rustls::version::TLS12])
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![
                        CertificateDer::from_pem_slice(if wrong_certificate {
                            HOST
                        } else {
                            DEVICE
                        })
                        .unwrap(),
                    ],
                    PrivateKeyDer::from_pem_slice(if wrong_certificate {
                        HOST_KEY
                    } else {
                        DEVICE_KEY
                    })
                    .unwrap(),
                )
                .unwrap();
        let server = tokio_rustls::TlsAcceptor::from(Arc::new(server));
        let (client_result, _) = tokio::join!(
            client.connect(ServerName::try_from("Device").unwrap(), host),
            server.accept(device)
        );
        client_result.is_ok()
    }

    #[tokio::test]
    async fn usb_tls_accepts_the_actual_pinned_key_and_rejects_another_device() {
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(5), handshake(false))
                .await
                .unwrap()
        );
        assert!(
            !tokio::time::timeout(std::time::Duration::from_secs(5), handshake(true))
                .await
                .unwrap()
        );
    }
}
