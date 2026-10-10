//! Explicit first-pairing negotiation over an already-authenticated USB service.
//! This module is absent from the iOS backend's feature set.

use super::*;
use tlv::{PairingDataComponentType as Component, TLV8Entry};

impl<R: RpPairingSocketProvider> RemotePairingClient<R> {
    /// Selects Pair Setup using the USB service's normal failed-verification
    /// transition. Call ONLY on a trusted USB Lockdown RemotePairing service,
    /// after authenticating USB trust and checking the selected device's UDID.
    ///
    /// Unlike `connect_paired`, this does not authenticate a RemotePairing peer
    /// or establish session keys. It offers a fresh, throwaway controller that
    /// MUST be rejected. This is an explicit bootstrap operation, never a
    /// fallback after verification of a stored identity has failed.
    /// The caller must subsequently verify Pair Setup M6 and use a fresh
    /// connection for full Pair Verify against the newly learned public key.
    pub async fn begin_new_pairing_over_trusted_usb(&mut self) -> Result<(), IdeviceError> {
        self.attempt_pair_verify().await?;
        let private = EphemeralSecret::random_from_rng(OsRng);
        let public = X25519PublicKey::from(&private);
        self.send_pairing_data(plist!({
            "data": R::serialize_bytes(&tlv::serialize_tlv8(&[
                entry(Component::State, vec![1]),
                entry(Component::PublicKey, public.as_bytes().to_vec()),
            ])),
            "kind": "verifyManualPairing",
            "startNewSession": true
        }))
        .await?;
        let response = self.receive_pairing_data().await?;
        let response = R::deserialize_bytes(response).ok_or_else(invalid_probe)?;
        let m2 = canonical_message(&response, 2)?;
        if is_authentication_rejection(&m2)? {
            return self.send_pair_verified_failed().await;
        }
        let peer_public: [u8; 32] = tlv::collect_component_data(&m2, Component::PublicKey)
            .try_into()
            .map_err(|_| invalid_probe())?;
        let peer_public = X25519PublicKey::from(peer_public);
        let shared = private.diffie_hellman(&peer_public);
        if !shared.was_contributory() {
            return Err(invalid_probe());
        }
        let hk = Hkdf::<Sha512>::new(Some(b"Pair-Verify-Encrypt-Salt"), shared.as_bytes());
        let mut key = Zeroizing::new([0u8; 32]);
        hk.expand(b"Pair-Verify-Encrypt-Info", &mut key[..])
            .map_err(|_| invalid_probe())?;
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key[..]));

        // No peer public key exists yet. USB trust authenticates this transport;
        // do not represent this probe as authenticated RemotePairing or retain
        // any identity/session key received here. Only Pair Setup may learn it.
        let mut probe = RpPairingFile::generate(&uuid::Uuid::new_v4().to_string());
        let mut signed = Vec::new();
        signed.extend_from_slice(public.as_bytes());
        signed.extend_from_slice(probe.identifier.as_bytes());
        signed.extend_from_slice(peer_public.as_bytes());
        let signature: Signature = probe.e_private_key.sign(&signed);
        let plaintext = tlv::serialize_tlv8(&[
            entry(Component::Identifier, probe.identifier.as_bytes().to_vec()),
            entry(Component::Signature, signature.to_vec()),
        ]);
        let encrypted = cipher
            .encrypt(Nonce::from_slice(b"\0\0\0\0PV-Msg03"), plaintext.as_slice())
            .map_err(|_| invalid_probe())?;
        self.send_pairing_data(plist!({
            "data": R::serialize_bytes(&tlv::serialize_tlv8(&[
                entry(Component::State, vec![3]),
                entry(Component::EncryptedData, encrypted),
            ])),
            "kind": "verifyManualPairing",
            "startNewSession": false
        }))
        .await?;
        let response = self.receive_pairing_data().await?;
        let response = R::deserialize_bytes(response).ok_or_else(invalid_probe)?;
        let m4 = canonical_message(&response, 4)?;
        if !is_authentication_rejection(&m4)? {
            // A new random controller cannot already be trusted. Never treat
            // this as success or start setup on an unexpected success response.
            return Err(invalid_probe());
        }
        self.send_pair_verified_failed().await
    }
}

fn entry(tlv_type: Component, data: Vec<u8>) -> TLV8Entry {
    TLV8Entry { tlv_type, data }
}

fn invalid_probe() -> IdeviceError {
    IdeviceError::UnexpectedResponse("unexpected USB first-pairing negotiation response".into())
}

fn canonical_message(data: &[u8], expected_state: u8) -> Result<Vec<TLV8Entry>, IdeviceError> {
    let entries = tlv::deserialize_tlv8(data)?;
    if tlv::serialize_tlv8(&entries) != data {
        return Err(invalid_probe());
    }
    let mut states = entries.iter().filter(|x| x.tlv_type == Component::State);
    match (states.next(), states.next()) {
        (Some(state), None) if state.data == [expected_state] => Ok(entries),
        _ => Err(invalid_probe()),
    }
}

fn is_authentication_rejection(entries: &[TLV8Entry]) -> Result<bool, IdeviceError> {
    let mut errors = entries
        .iter()
        .filter(|x| x.tlv_type == Component::ErrorResponse);
    match (errors.next(), errors.next()) {
        (None, None) => Ok(false),
        // HomeKit TLV error 2 is Authentication; other errors must not trigger
        // Pair Setup (e.g. busy, rate limited, or unavailable).
        (Some(error), None) if error.data == [2] => Ok(true),
        _ => Err(invalid_probe()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestSocket = RpPairingSocket<tokio::io::DuplexStream>;

    fn pairing_data(value: plist::Value) -> Vec<TLV8Entry> {
        let value = value
            .get_by("event")
            .and_then(|x| x.get_by("_0"))
            .and_then(|x| x.get_by("pairingData"))
            .and_then(|x| x.get_by("_0"))
            .and_then(|x| x.get_by("data"))
            .unwrap()
            .clone();
        tlv::deserialize_tlv8(&TestSocket::deserialize_bytes(value).unwrap()).unwrap()
    }

    async fn reply(socket: &mut TestSocket, data: &[TLV8Entry], sequence: usize) {
        socket
            .send_plain(
                plist!({ "event": { "_0": { "pairingData": { "_0": {
                    "data": TestSocket::serialize_bytes(&tlv::serialize_tlv8(data))
                }}}}}),
                sequence,
            )
            .await
            .unwrap();
    }

    async fn run_probe_fixture(reject_unknown_identity: bool) {
        let (host, device) = tokio::io::duplex(8192);
        let mut client = RemotePairingClient::new(RpPairingSocket::new(host), "test");
        let server = async {
            let mut socket = RpPairingSocket::new_device(device);
            let handshake = socket.recv_plain().await.unwrap();
            assert_eq!(
                handshake
                    .get_by("request")
                    .unwrap()
                    .get_by("_0")
                    .unwrap()
                    .get_by("handshake")
                    .unwrap()
                    .get_by("_0")
                    .unwrap()
                    .get_by("hostOptions")
                    .unwrap()
                    .get_by("attemptPairVerify")
                    .unwrap()
                    .as_boolean(),
                Some(true)
            );
            socket
                .send_plain(
                    plist!({ "response": { "_1": { "handshake": { "_0": {} }}}}),
                    0,
                )
                .await
                .unwrap();
            let m1 = pairing_data(socket.recv_plain().await.unwrap());
            assert_eq!(tlv::collect_component_data(&m1, Component::State), [1]);
            let controller_public: [u8; 32] =
                tlv::collect_component_data(&m1, Component::PublicKey)
                    .try_into()
                    .unwrap();
            let private = EphemeralSecret::random_from_rng(OsRng);
            let public = X25519PublicKey::from(&private);
            let shared = private.diffie_hellman(&X25519PublicKey::from(controller_public));
            let hk = Hkdf::<Sha512>::new(Some(b"Pair-Verify-Encrypt-Salt"), shared.as_bytes());
            let mut key = [0; 32];
            hk.expand(b"Pair-Verify-Encrypt-Info", &mut key).unwrap();
            let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
            reply(
                &mut socket,
                &[
                    entry(Component::State, vec![2]),
                    entry(Component::PublicKey, public.as_bytes().to_vec()),
                ],
                1,
            )
            .await;
            let m3 = pairing_data(socket.recv_plain().await.unwrap());
            assert_eq!(tlv::collect_component_data(&m3, Component::State), [3]);
            let encrypted = tlv::collect_component_data(&m3, Component::EncryptedData);
            let identity = cipher
                .decrypt(Nonce::from_slice(b"\0\0\0\0PV-Msg03"), encrypted.as_slice())
                .unwrap();
            let identity = tlv::deserialize_tlv8(&identity).unwrap();
            assert!(!tlv::collect_component_data(&identity, Component::Identifier).is_empty());
            assert_eq!(
                tlv::collect_component_data(&identity, Component::Signature).len(),
                64
            );
            let mut m4 = vec![entry(Component::State, vec![4])];
            if reject_unknown_identity {
                m4.push(entry(Component::ErrorResponse, vec![2]));
            }
            reply(&mut socket, &m4, 2).await;
            if reject_unknown_identity {
                let failure = socket.recv_plain().await.unwrap();
                assert!(
                    failure
                        .get_by("event")
                        .unwrap()
                        .get_by("_0")
                        .unwrap()
                        .get_by("pairVerifyFailed")
                        .is_some()
                );
            }
        };
        let (result, ()) = tokio::join!(client.begin_new_pairing_over_trusted_usb(), server);
        assert_eq!(result.is_ok(), reject_unknown_identity);
        assert_eq!(client.encryption_key(), [0; 32]);
        assert!(client.paired_peer_device().is_err());
    }

    #[tokio::test]
    async fn usb_setup_negotiation_follows_failed_verification_and_keeps_no_peer() {
        tokio::time::timeout(std::time::Duration::from_secs(5), run_probe_fixture(true))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn usb_setup_negotiation_rejects_an_unexpected_success() {
        tokio::time::timeout(std::time::Duration::from_secs(5), run_probe_fixture(false))
            .await
            .unwrap();
    }

    #[test]
    fn only_an_explicit_authentication_rejection_can_start_setup() {
        let valid = canonical_message(&[6, 1, 4, 7, 1, 2], 4).unwrap();
        assert!(is_authentication_rejection(&valid).unwrap());
        assert!(!is_authentication_rejection(&canonical_message(&[6, 1, 4], 4).unwrap()).unwrap());
        for bytes in [&[6, 1, 4, 7, 1, 6][..], &[6, 1, 4, 7, 1, 2, 7, 1, 2]] {
            assert!(is_authentication_rejection(&canonical_message(bytes, 4).unwrap()).is_err());
        }
        for bytes in [&[6, 1, 2, 7, 1, 2][..], &[6, 1, 4, 0], &[6, 1, 4, 6, 1, 4]] {
            assert!(canonical_message(bytes, 4).is_err());
        }
    }
}
