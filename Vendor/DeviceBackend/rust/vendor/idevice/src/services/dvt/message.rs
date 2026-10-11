//! Instruments protocol message format implementation
//!
//! This module handles the serialization and deserialization of messages used in
//! the iOS instruments protocol. The message format consists of:
//! - 32-byte message header
//! - 16-byte payload header
//! - Optional auxiliary data section
//! - Payload data (typically NSKeyedArchive format)
//!
//! # Message Structure
//! ```text
//! +---------------------+
//! |   MessageHeader     | 32 bytes
//! +---------------------+
//! |   PayloadHeader     | 16 bytes
//! +---------------------+
//! |   AuxHeader         | 16 bytes (if aux present)
//! |   Aux data          | variable length
//! +---------------------+
//! |   Payload data      | variable length (NSKeyedArchive)
//! +---------------------+
//! ```
//!
//! # Example
//! ```rust,no_run
//! use plist::Value;
//! use your_crate::IdeviceError;
//! use your_crate::dvt::message::{Message, MessageHeader, PayloadHeader, AuxValue};
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), IdeviceError> {
//! // Create a new message
//! let header = MessageHeader::new(
//!     1,      // fragment_id
//!     1,      // fragment_count  
//!     123,    // identifier
//!     0,      // conversation_index
//!     42,     // channel
//!     true    // expects_reply
//! );
//!
//! let message = Message::new(
//!     header,
//!     PayloadHeader::method_invocation(),
//!     Some(AuxValue::from_values(vec![
//!         AuxValue::String("param".into()),
//!         AuxValue::U32(123),
//!     ])),
//!     Some(Value::String("data".into()))
//! );
//!
//! // Serialize message
//! let bytes = message.serialize();
//!
//! // Deserialize message (from async reader)
//! # let mut reader = &bytes[..];
//! let deserialized = Message::from_reader(&mut reader).await?;
//! # Ok(())
//! # }

use plist::Value;
use std::io::{Cursor, Read};
use tokio::io::{AsyncRead, AsyncReadExt};

use super::errors::DvtError;
use crate::IdeviceError;

// Eiscue adaptation: bound untrusted DTX framing before allocation or decoding.
// Covers a complete message (payload header, auxiliary values and archived data).
const MAX_DTX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;
const DTX_HEADER_BYTES: usize = 32;
const DTX_PAYLOAD_HEADER_BYTES: usize = 16;

fn invalid_frame() -> IdeviceError {
    IdeviceError::UnexpectedResponse("invalid or oversized DTX frame".into())
}

/// Message header containing metadata about the message
///
/// 32-byte structure that appears at the start of every message
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MessageHeader {
    /// Magic number identifying the protocol (0x1F3D5B79)
    magic: u32,
    /// Length of this header (always 32)
    header_len: u32,
    /// Fragment identifier for multipart messages
    fragment_id: u16,
    /// Total number of fragments
    fragment_count: u16,
    /// Total length of payload (headers + aux + data)
    length: u32,
    /// Unique message identifier
    identifier: u32,
    /// Conversation tracking index
    conversation_index: u32,
    /// Channel number this message belongs to
    pub channel: i32,
    /// Whether a reply is expected
    expects_reply: bool,
}

/// Payload header containing information about the message contents
///
/// 16-byte structure following the message header
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct PayloadHeader {
    /// DTX message type (DISPATCH/OBJECT/OK/ERROR/DATA)
    msg_type: u8,
    /// Reserved bytes in the wire format
    flags_a: u8,
    /// Reserved bytes in the wire format
    flags_b: u8,
    /// Reserved byte in the wire format
    reserved: u8,
    /// Length of auxiliary data section
    aux_length: u32,
    /// Total length of payload (aux + data)
    total_length: u32,
    /// Additional payload flags
    flags: u32,
}

/// Header for auxiliary data section
///
/// 16-byte structure preceding auxiliary data
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct AuxHeader {
    /// Buffer size hint (often 496)
    buffer_size: u32,
    /// Unknown field (typically 0)
    unknown: u32,
    /// Actual size of auxiliary data
    aux_size: u32,
    /// Unknown field (typically 0)
    unknown2: u32,
}

/// Auxiliary data container
///
/// Contains a header and a collection of typed values
#[derive(Debug, Clone, PartialEq)]
pub struct Aux {
    /// Auxiliary data header
    pub header: AuxHeader,
    /// Collection of auxiliary values
    pub values: Vec<AuxValue>,
}

/// Typed auxiliary value that can be included in messages
#[derive(Clone, PartialEq)]
pub enum AuxValue {
    /// NULL value (type 0x0a) - no payload bytes
    Null,
    /// UTF-8 string value (type 0x01)
    String(String),
    /// Raw byte array (type 0x02)
    Array(Vec<u8>),
    /// 32-bit unsigned integer (type 0x03)
    U32(u32),
    /// 64-bit signed integer (type 0x06)
    I64(i64),
    /// 64-bit floating point (double) (type 0x09)
    Double(f64),
    /// Primitive dictionary (type 0xF0) - value is a list of primitives to match pymobiledevice3 format
    PrimitiveDictionary(Vec<(AuxValue, Vec<AuxValue>)>),
}

/// Complete protocol message
#[derive(Clone, PartialEq)]
pub struct Message {
    /// Message metadata header
    pub message_header: MessageHeader,
    /// Payload description header
    pub payload_header: PayloadHeader,
    /// Optional auxiliary data
    pub aux: Option<Aux>,
    /// Optional payload data (typically NSKeyedArchive)
    pub data: Option<Value>,
    /// Raw bytes of the data section before NSKeyedArchive decoding
    pub raw_data: Option<Vec<u8>>,
}

impl Aux {
    /// Parses the legacy aux wire format used on iOS 16 and earlier
    ///
    /// Layout: `[AuxHeader (16 B)][type (4 B)][data...][type (4 B)][data...]...`
    ///
    /// Type 0xF0 entries are `PrimitiveDictionary` blocks embedded inside
    /// the legacy envelope; their bodies are skipped since the useful values
    /// are the surrounding flat entries.
    fn parse_legacy_bytes(bytes: Vec<u8>) -> Result<Self, IdeviceError> {
        if bytes.len() < 16 {
            return Err(IdeviceError::NotEnoughBytes(bytes.len(), 16));
        }

        let mut cursor = Cursor::new(bytes.as_slice());
        let header = AuxHeader {
            buffer_size: Self::read_u32(&mut cursor)?,
            unknown: Self::read_u32(&mut cursor)?,
            aux_size: Self::read_u32(&mut cursor)?,
            unknown2: Self::read_u32(&mut cursor)?,
        };
        if header.aux_size as usize != bytes.len() - DTX_PAYLOAD_HEADER_BYTES {
            return Err(invalid_frame());
        }

        let mut values = Vec::new();
        while cursor.position() + 4 <= bytes.len() as u64 {
            let aux_type = Self::read_u32(&mut cursor)?;
            match aux_type {
                0x0a => {
                    // PNULL separator — used as dictionary keys; not a user value.
                }
                0x0f0 => {
                    // PrimitiveDictionary block embedded in a legacy envelope.
                    // Layout after the type: u32 flags, u64 body_length, [body].
                    // Skip the entire block; positional args appear as flat entries.
                    let _flags = Self::read_u32(&mut cursor)?;
                    let body_len = Self::read_u64(&mut cursor)?;
                    let pos = cursor.position() as usize;
                    let end = usize::try_from(body_len)
                        .ok()
                        .and_then(|len| pos.checked_add(len))
                        .filter(|end| *end <= bytes.len())
                        .ok_or_else(invalid_frame)?;
                    cursor.set_position(end as u64);
                }
                _ => {
                    // All other types share the same encoding as parse_primitive,
                    // but the type word is already consumed above so we reconstruct
                    // a cursor over [type || remaining] to reuse parse_primitive.
                    let pos = cursor.position() as usize - 4;
                    let mut sub = Cursor::new(&bytes[pos..]);
                    values.push(Self::parse_primitive(&mut sub)?);
                    cursor.set_position(pos as u64 + sub.position());
                }
            }
        }
        if cursor.position() != bytes.len() as u64 {
            return Err(invalid_frame());
        }
        Ok(Self { header, values })
    }

    fn read_u32(cursor: &mut Cursor<&[u8]>) -> Result<u32, IdeviceError> {
        let mut buf = [0u8; 4];
        Read::read_exact(cursor, &mut buf)?;
        Ok(u32::from_le_bytes(buf))
    }

    fn read_u64(cursor: &mut Cursor<&[u8]>) -> Result<u64, IdeviceError> {
        let mut buf = [0u8; 8];
        Read::read_exact(cursor, &mut buf)?;
        Ok(u64::from_le_bytes(buf))
    }

    fn read_f64(cursor: &mut Cursor<&[u8]>) -> Result<f64, IdeviceError> {
        let mut buf = [0u8; 8];
        Read::read_exact(cursor, &mut buf)?;
        Ok(f64::from_le_bytes(buf))
    }

    fn read_exact_vec(cursor: &mut Cursor<&[u8]>, len: usize) -> Result<Vec<u8>, IdeviceError> {
        let start = usize::try_from(cursor.position()).map_err(|_| invalid_frame())?;
        let end = start.checked_add(len).ok_or_else(invalid_frame)?;
        // Validate the nested length against the already bounded parent slice
        // before allocating. A short packet cannot request a multi-GiB vector.
        let buf = cursor
            .get_ref()
            .get(start..end)
            .ok_or_else(invalid_frame)?
            .to_vec();
        cursor.set_position(end as u64);
        Ok(buf)
    }

    fn parse_primitive(cursor: &mut Cursor<&[u8]>) -> Result<AuxValue, IdeviceError> {
        let raw_type = Self::read_u32(cursor)?;
        let type_code = raw_type & 0xFF;
        match type_code {
            0x01 => {
                let len = Self::read_u32(cursor)? as usize;
                Ok(AuxValue::String(String::from_utf8(Self::read_exact_vec(
                    cursor, len,
                )?)?))
            }
            0x02 => {
                let len = Self::read_u32(cursor)? as usize;
                Ok(AuxValue::Array(Self::read_exact_vec(cursor, len)?))
            }
            0x03 => Ok(AuxValue::U32(Self::read_u32(cursor)?)),
            0x06 => Ok(AuxValue::I64(Self::read_u64(cursor)? as i64)),
            0x09 => Ok(AuxValue::Double(Self::read_f64(cursor)?)),
            0x0A => Ok(AuxValue::Null),
            _ => Err(DvtError::UnknownAuxValueType(raw_type).into()),
        }
    }

    /// Parses auxiliary data from bytes, selecting the correct wire format
    /// based on the leading magic byte.
    ///
    /// # Wire formats
    ///
    /// **Legacy**: the first byte is NOT `0xF0`.
    /// The buffer begins with a 16-byte `AuxHeader` followed by flat
    /// type-tagged value entries.
    ///
    /// **Modern** (iOS 17+, RSD/testmanagerd path): the first byte IS `0xF0`,
    /// indicating the entire buffer is a single `PrimitiveDictionary` block
    /// (`[flags(4B)][unknown(4B)][body_len(8B)][key-value pairs...]`).
    /// Keys are positional-null sentinels; only the values are collected.
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, IdeviceError> {
        if bytes.len() > MAX_DTX_MESSAGE_BYTES {
            return Err(invalid_frame());
        }
        if bytes.is_empty() {
            return Ok(Self::from_values(Vec::new()));
        }

        if (bytes[0] as u32) != 0xF0 {
            return Self::parse_legacy_bytes(bytes);
        }

        if bytes.len() < 16 {
            return Err(IdeviceError::NotEnoughBytes(bytes.len(), 16));
        }

        let mut cursor = Cursor::new(bytes.as_slice());
        let _type_and_flags = Self::read_u32(&mut cursor)?;
        let _unknown_flags = Self::read_u32(&mut cursor)?;
        let body_len = Self::read_u64(&mut cursor)?;
        let body_end = body_len
            .checked_add(DTX_PAYLOAD_HEADER_BYTES as u64)
            .filter(|end| *end == bytes.len() as u64)
            .ok_or_else(invalid_frame)?;
        let body = bytes
            .get(DTX_PAYLOAD_HEADER_BYTES..body_end as usize)
            .ok_or_else(invalid_frame)?;
        let mut cursor = Cursor::new(body);

        let mut values = Vec::new();
        while cursor.position() < body_len {
            let _key = Self::parse_primitive(&mut cursor)?;
            let value = Self::parse_primitive(&mut cursor)?;
            values.push(value);
        }

        Ok(Self {
            header: AuxHeader::default(),
            values,
        })
    }

    /// Creates new auxiliary data from values
    ///
    /// Note: Header fields are populated during serialization
    ///
    /// # Arguments
    /// * `values` - Collection of auxiliary values to include
    pub fn from_values(values: Vec<AuxValue>) -> Self {
        Self {
            header: AuxHeader::default(),
            values,
        }
    }

    /// Serializes auxiliary data to bytes
    ///
    /// Includes properly formatted header with updated size fields
    pub fn serialize(&self) -> Vec<u8> {
        let mut values_payload = Vec::new();
        for v in self.values.iter() {
            values_payload.extend_from_slice(&0x0a_u32.to_le_bytes());
            match v {
                AuxValue::Null => {
                    // PNULL - type 0x0a with no payload bytes
                }
                AuxValue::String(s) => {
                    values_payload.extend_from_slice(&0x01_u32.to_le_bytes());
                    values_payload.extend_from_slice(&(s.len() as u32).to_le_bytes());
                    values_payload.extend_from_slice(s.as_bytes());
                }
                AuxValue::Array(v) => {
                    values_payload.extend_from_slice(&0x02_u32.to_le_bytes());
                    values_payload.extend_from_slice(&(v.len() as u32).to_le_bytes());
                    values_payload.extend_from_slice(v);
                }
                AuxValue::U32(u) => {
                    values_payload.extend_from_slice(&0x03_u32.to_le_bytes());
                    values_payload.extend_from_slice(&u.to_le_bytes());
                }
                AuxValue::I64(i) => {
                    values_payload.extend_from_slice(&0x06_u32.to_le_bytes());
                    values_payload.extend_from_slice(&i.to_le_bytes());
                }
                AuxValue::Double(d) => {
                    values_payload.extend_from_slice(&0x09_u32.to_le_bytes());
                    values_payload.extend_from_slice(&d.to_le_bytes());
                }
                AuxValue::PrimitiveDictionary(entries) => {
                    // PrimitiveDictionary: type=0xF0, entries are (key, [values]) pairs
                    // Header: u32 magic (0x1F0), u32 unknown (0), u64 body_length
                    // pymobiledevice3 format: {PNULL: [arg1, arg2, ...]}
                    let mut body_payload = Vec::new();
                    for (key, values) in entries {
                        // Write the key primitive once (typically NULL 0x0a)
                        body_payload.extend_from_slice(&0x0a_u32.to_le_bytes());
                        write_primitive_value(key, &mut body_payload);
                        // Write each value in the list
                        for value in values {
                            write_primitive_value(value, &mut body_payload);
                        }
                    }
                    let body_len = body_payload.len() as u64;
                    values_payload.extend_from_slice(&0xf0_u32.to_le_bytes());
                    values_payload.extend_from_slice(&0_u32.to_le_bytes()); // unknown flags
                    values_payload.extend_from_slice(&body_len.to_le_bytes());
                    values_payload.extend_from_slice(&body_payload);
                }
            }
        }

        let mut res = Vec::new();
        let buffer_size = 496_u32;
        res.extend_from_slice(&buffer_size.to_le_bytes());
        res.extend_from_slice(&0_u32.to_le_bytes());
        res.extend_from_slice(&(values_payload.len() as u32).to_le_bytes());
        res.extend_from_slice(&0_u32.to_le_bytes());
        res.extend_from_slice(&values_payload);
        res
    }
}

/// Helper to write a primitive value to the payload
fn write_primitive_value(v: &AuxValue, payload: &mut Vec<u8>) {
    match v {
        AuxValue::Null => {
            // PNULL - type 0x0a with no payload bytes
        }
        AuxValue::String(s) => {
            payload.extend_from_slice(&0x01_u32.to_le_bytes());
            payload.extend_from_slice(&(s.len() as u32).to_le_bytes());
            payload.extend_from_slice(s.as_bytes());
        }
        AuxValue::Array(bytes) => {
            payload.extend_from_slice(&0x02_u32.to_le_bytes());
            payload.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            payload.extend_from_slice(bytes);
        }
        AuxValue::U32(val) => {
            payload.extend_from_slice(&0x03_u32.to_le_bytes());
            payload.extend_from_slice(&val.to_le_bytes());
        }
        AuxValue::I64(val) => {
            payload.extend_from_slice(&0x06_u32.to_le_bytes());
            payload.extend_from_slice(&val.to_le_bytes());
        }
        AuxValue::Double(val) => {
            payload.extend_from_slice(&0x09_u32.to_le_bytes());
            payload.extend_from_slice(&val.to_le_bytes());
        }
        AuxValue::PrimitiveDictionary(_) => {
            // Nested dictionaries not typically used as primitive values
            // Write as empty dict
            payload.extend_from_slice(&0xf0_u32.to_le_bytes());
            payload.extend_from_slice(&0_u32.to_le_bytes());
            payload.extend_from_slice(&0u64.to_le_bytes());
        }
    }
}

impl AuxValue {
    /// Creates an auxiliary value containing NSKeyedArchived data
    ///
    /// # Arguments
    /// * `v` - Plist value to archive
    pub fn archived_value(v: impl Into<plist::Value>) -> Self {
        Self::Array(ns_keyed_archive::encode::encode_to_bytes(v.into()).expect("Failed to encode"))
    }

    /// Creates a primitive buffer (immutable buffer) containing raw bytes
    /// This is used for passing primitive arrays as DTX arguments (wire type 0x02)
    ///
    /// # Arguments
    /// * `bytes` - Raw bytes to include in the buffer
    pub fn primitive_buffer(bytes: Vec<u8>) -> Self {
        Self::Array(bytes)
    }

    /// Creates a PrimitiveDictionary auxiliary value (wire type 0xF0)
    ///
    /// # Arguments
    /// * `entries` - List of (key, [values]) pairs
    pub fn primitive_dictionary(entries: Vec<(AuxValue, Vec<AuxValue>)>) -> Self {
        Self::PrimitiveDictionary(entries)
    }

    /// Creates a DTX method call auxiliary argument format matching pymobiledevice3
    ///
    /// This wraps all arguments in a single PrimitiveDictionary with a NULL key,
    /// producing the structure `{PNULL: [arg1, arg2, ...]}`.
    ///
    /// This matches pymobiledevice3's `MessageAux.build()` which creates `PDict({PNULL: converted_list})`.
    ///
    /// # Arguments
    /// * `args` - List of arguments to wrap
    pub fn dtx_method_args(args: Vec<Self>) -> Self {
        // Create a PrimitiveDictionary with a single entry: (PNULL, [arg1, arg2, ...])
        Self::PrimitiveDictionary(vec![(Self::Null, args)])
    }
}

impl MessageHeader {
    async fn read<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Self, IdeviceError> {
        let mut buf = [0u8; DTX_HEADER_BYTES];
        reader.read_exact(&mut buf).await?;
        let number = |index: usize| {
            u32::from_le_bytes([buf[index], buf[index + 1], buf[index + 2], buf[index + 3]])
        };
        let wire_channel = i32::from_le_bytes([buf[24], buf[25], buf[26], buf[27]]);
        let conversation_index = number(20);
        let header = Self {
            magic: number(0),
            header_len: number(4),
            fragment_id: u16::from_le_bytes([buf[8], buf[9]]),
            fragment_count: u16::from_le_bytes([buf[10], buf[11]]),
            length: number(12),
            identifier: number(16),
            conversation_index,
            channel: if conversation_index.is_multiple_of(2) {
                wire_channel.checked_neg().ok_or_else(invalid_frame)?
            } else {
                wire_channel
            },
            expects_reply: number(28) == 1,
        };
        if header.magic != 0x1F3D5B79
            || header.header_len != DTX_HEADER_BYTES as u32
            || header.fragment_count == 0
            || header.fragment_id >= header.fragment_count
            || header.length == 0
            || header.length as usize > MAX_DTX_MESSAGE_BYTES
            || wire_channel == i32::MIN
            || number(28) > 1
        {
            return Err(invalid_frame());
        }
        Ok(header)
    }

    /// Creates a new message header
    ///
    /// Note: Length field is updated during message serialization
    ///
    /// # Arguments
    /// * `fragment_id` - Identifier for message fragments
    /// * `fragment_count` - Total fragments in message
    /// * `identifier` - Unique message ID
    /// * `conversation_index` - Conversation tracking number
    /// * `channel` - Channel number
    /// * `expects_reply` - Whether response is expected
    pub fn new(
        fragment_id: u16,
        fragment_count: u16,
        identifier: u32,
        conversation_index: u32,
        channel: i32,
        expects_reply: bool,
    ) -> Self {
        Self {
            magic: 0x1F3D5B79,
            header_len: 32,
            fragment_id,
            fragment_count,
            length: 0,
            identifier,
            conversation_index,
            channel,
            expects_reply,
        }
    }

    /// Returns the unique message identifier.
    pub(crate) fn identifier(&self) -> u32 {
        self.identifier
    }

    /// Returns the conversation index for this message.
    pub(crate) fn conversation_index(&self) -> u32 {
        self.conversation_index
    }

    /// Returns whether this message expects a reply.
    pub(crate) fn expects_reply(&self) -> bool {
        self.expects_reply
    }

    /// Serializes header to bytes
    pub fn serialize(&self) -> Vec<u8> {
        let mut res = Vec::new();
        res.extend_from_slice(&self.magic.to_le_bytes());
        res.extend_from_slice(&self.header_len.to_le_bytes());
        res.extend_from_slice(&self.fragment_id.to_le_bytes());
        res.extend_from_slice(&self.fragment_count.to_le_bytes());
        res.extend_from_slice(&self.length.to_le_bytes());
        res.extend_from_slice(&self.identifier.to_le_bytes());
        res.extend_from_slice(&self.conversation_index.to_le_bytes());
        res.extend_from_slice(&self.channel.to_le_bytes());
        res.extend_from_slice(&if self.expects_reply { 1_u32 } else { 0 }.to_le_bytes());

        res
    }
}

impl PayloadHeader {
    /// DTX payload type (0 ACK, 3 object reply, 4 remote error).
    pub fn message_type(&self) -> u8 { self.msg_type }

    /// Creates a new payload header
    pub fn new() -> Self {
        Self::default()
    }

    /// Serializes header to bytes
    pub fn serialize(&self) -> Vec<u8> {
        let mut res = vec![self.msg_type, self.flags_a, self.flags_b, self.reserved];
        res.extend_from_slice(&self.aux_length.to_le_bytes());
        res.extend_from_slice(&self.total_length.to_le_bytes());
        res.extend_from_slice(&self.flags.to_le_bytes());

        res
    }

    /// Creates header for method invocation messages
    pub fn method_invocation() -> Self {
        Self {
            msg_type: 2,
            ..Default::default()
        }
    }
}

impl Message {
    /// Reads and parses a message from an async reader
    ///
    /// # Arguments
    /// * `reader` - Async reader to read from
    ///
    /// # Returns  
    /// * `Ok(Message)` - Parsed message
    /// * `Err(IdeviceError)` - If reading/parsing fails
    ///
    /// # Errors
    /// * Various IdeviceError variants for IO and parsing failures
    pub async fn from_reader<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Self, IdeviceError> {
        let first = MessageHeader::read(reader).await?;
        if first.fragment_id != 0 || first.length < DTX_PAYLOAD_HEADER_BYTES as u32 {
            return Err(invalid_frame());
        }
        let announced_size = first.length as usize;
        let mut packet_data = Vec::new();
        // Fragment zero of a multipart message is an announcement only. Its
        // length is the total payload length, not bytes following that header.
        let mut header = first;
        for expected in 0..first.fragment_count {
            if expected != 0 {
                header = MessageHeader::read(reader).await?;
            }
            if header.fragment_id != expected
                || header.fragment_count != first.fragment_count
                || header.identifier != first.identifier
                || header.conversation_index != first.conversation_index
                || header.channel != first.channel
                || header.expects_reply != first.expects_reply
            {
                return Err(invalid_frame());
            }
            if expected == 0 && first.fragment_count > 1 {
                continue;
            }
            let end = packet_data
                .len()
                .checked_add(header.length as usize)
                .filter(|end| *end <= announced_size && *end <= MAX_DTX_MESSAGE_BYTES)
                .ok_or_else(invalid_frame)?;
            let start = packet_data.len();
            packet_data
                .try_reserve_exact(end - start)
                .map_err(|_| invalid_frame())?;
            packet_data.resize(end, 0);
            reader.read_exact(&mut packet_data[start..end]).await?;
        }
        if packet_data.len() != announced_size {
            return Err(invalid_frame());
        }
        let buf = packet_data
            .get(..DTX_PAYLOAD_HEADER_BYTES)
            .ok_or_else(invalid_frame)?;
        let pheader = PayloadHeader {
            msg_type: buf[0],
            flags_a: buf[1],
            flags_b: buf[2],
            reserved: buf[3],
            aux_length: u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]),
            total_length: u32::from_le_bytes([buf[8], buf[9], buf[10], buf[11]]),
            flags: u32::from_le_bytes([buf[12], buf[13], buf[14], buf[15]]),
        };
        let payload_end = DTX_PAYLOAD_HEADER_BYTES
            .checked_add(pheader.total_length as usize)
            .filter(|end| *end == packet_data.len())
            .ok_or_else(invalid_frame)?;
        let aux_end = DTX_PAYLOAD_HEADER_BYTES
            .checked_add(pheader.aux_length as usize)
            .filter(|end| *end <= payload_end)
            .ok_or_else(invalid_frame)?;
        let aux_bytes = packet_data
            .get(DTX_PAYLOAD_HEADER_BYTES..aux_end)
            .ok_or_else(invalid_frame)?;
        let aux = if aux_bytes.is_empty() {
            None
        } else {
            Some(Aux::from_bytes(aux_bytes.to_vec())?)
        };
        let data_bytes = packet_data
            .get(aux_end..payload_end)
            .ok_or_else(invalid_frame)?;
        let data = if data_bytes.is_empty() {
            None
        } else {
            Some(
                ns_keyed_archive::decode::from_bytes(data_bytes)
                    .map_err(super::errors::DvtError::from)?,
            )
        };
        let raw_data = if data_bytes.is_empty() {
            None
        } else {
            Some(data_bytes.to_vec())
        };

        Ok(Message {
            message_header: first,
            payload_header: pheader,
            aux,
            data,
            raw_data,
        })
    }

    /// Creates a new message
    ///
    /// # Arguments
    /// * `message_header` - Message metadata
    /// * `payload_header` - Payload description  
    /// * `aux` - Optional auxiliary data
    /// * `data` - Optional payload data
    pub fn new(
        message_header: MessageHeader,
        payload_header: PayloadHeader,
        aux: Option<Aux>,
        data: Option<Value>,
    ) -> Self {
        Self {
            message_header,
            payload_header,
            aux,
            data,
            raw_data: None,
        }
    }

    /// Serializes message to bytes
    ///
    /// Updates length fields in headers automatically
    pub fn serialize(&self) -> Vec<u8> {
        let aux = match &self.aux {
            Some(a) => a.serialize(),
            None => Vec::new(),
        };
        let data = match &self.data {
            Some(d) => ns_keyed_archive::encode::encode_to_bytes(d.to_owned())
                .expect("Failed to encode value"),
            None => Vec::new(),
        };

        // Update the payload header
        let mut payload_header = self.payload_header.to_owned();
        payload_header.aux_length = aux.len() as u32;
        payload_header.total_length = (aux.len() + data.len()) as u32;
        let payload_header = payload_header.serialize();

        // Update the message header
        let mut message_header = self.message_header.to_owned();
        message_header.length = (payload_header.len() + aux.len() + data.len()) as u32;

        let mut res = Vec::new();
        res.extend_from_slice(&message_header.serialize());
        res.extend_from_slice(&payload_header);
        res.extend_from_slice(&aux);
        res.extend_from_slice(&data);

        res
    }

    /// Builds a raw reply frame for an incoming message, sending `data_bytes`
    /// verbatim as the payload without additional NSKeyedArchive encoding.
    ///
    /// This is used for replies where the payload is already a serialised
    /// NSKeyedArchive (e.g. `XCTestConfiguration`).  Pass an empty slice to
    /// send an acknowledgement with no payload.
    pub(crate) fn build_raw_reply(
        channel: i32,
        incoming_msg_id: u32,
        incoming_conversation_index: u32,
        data_bytes: &[u8],
    ) -> Vec<u8> {
        // Payload header (16 bytes): flags=0, aux_len=0, total_len
        let msg_type: u8 = if data_bytes.is_empty() { 0 } else { 3 };
        let flags_a: u8 = 0;
        let flags_b: u8 = 0;
        let reserved: u8 = 0;
        let aux_len: u32 = 0;
        let total_len: u32 = data_bytes.len() as u32;

        let payload_total = 16usize + data_bytes.len(); // payload_hdr + data

        // Message header (32 bytes)
        let magic: u32 = 0x1F3D5B79;
        let header_len: u32 = 32;
        let fragment_id: u16 = 0;
        let fragment_count: u16 = 1;
        let length: u32 = payload_total as u32;
        let conversation_index = incoming_conversation_index + 1;
        let expects_reply: u32 = 0;
        let wire_channel = if conversation_index.is_multiple_of(2) {
            channel
        } else {
            -channel
        };

        let mut buf = Vec::with_capacity(32 + 16 + data_bytes.len());
        buf.extend_from_slice(&magic.to_le_bytes());
        buf.extend_from_slice(&header_len.to_le_bytes());
        buf.extend_from_slice(&fragment_id.to_le_bytes());
        buf.extend_from_slice(&fragment_count.to_le_bytes());
        buf.extend_from_slice(&length.to_le_bytes());
        buf.extend_from_slice(&incoming_msg_id.to_le_bytes());
        buf.extend_from_slice(&conversation_index.to_le_bytes());
        buf.extend_from_slice(&wire_channel.to_le_bytes());
        buf.extend_from_slice(&expects_reply.to_le_bytes());
        // Payload header
        buf.push(msg_type);
        buf.push(flags_a);
        buf.push(flags_b);
        buf.push(reserved);
        buf.extend_from_slice(&aux_len.to_le_bytes());
        buf.extend_from_slice(&total_len.to_le_bytes());
        buf.extend_from_slice(&0_u32.to_le_bytes());
        // Data
        buf.extend_from_slice(data_bytes);
        buf
    }
}

impl std::fmt::Debug for AuxValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AuxValue::Null => write!(f, "Null"),
            AuxValue::String(s) => write!(f, "String({s:?})"),
            AuxValue::Array(arr) => write!(
                f,
                "Array(len={}, first_bytes={:?})",
                arr.len(),
                &arr[..arr.len().min(10)]
            ),
            AuxValue::U32(n) => write!(f, "U32({n})"),
            AuxValue::I64(n) => write!(f, "I64({n})"),
            AuxValue::Double(d) => write!(f, "Double({d})"),
            AuxValue::PrimitiveDictionary(_) => write!(f, "PrimitiveDictionary"),
        }
    }
}

impl std::fmt::Debug for Message {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Message")
            .field("message_header", &self.message_header)
            .field("payload_header", &self.payload_header)
            .field("aux", &self.aux)
            .field("has_data", &self.data.is_some())
            .field("raw_data_length", &self.raw_data.as_ref().map(Vec::len))
            .finish()
    }
}

#[cfg(test)]
mod framing_tests {
    use super::*;

    fn message() -> Message {
        Message::new(
            MessageHeader::new(0, 1, 42, 1, 7, false),
            PayloadHeader::method_invocation(),
            Some(Aux::from_values(vec![
                AuxValue::U32(5),
                AuxValue::String("fixture".into()),
            ])),
            Some(Value::String("fixture screenshot method".into())),
        )
    }

    fn fragment_header(index: u16, count: u16, length: usize) -> Vec<u8> {
        let mut header = MessageHeader::new(index, count, 42, 1, 7, false);
        header.length = length as u32;
        header.serialize()
    }

    fn fragmented() -> (Vec<u8>, usize) {
        let bytes = message().serialize();
        let payload = &bytes[DTX_HEADER_BYTES..];
        // The first data fragment deliberately cuts across the payload header.
        let split = 7;
        let mut wire = fragment_header(0, 3, payload.len());
        wire.extend(fragment_header(1, 3, split));
        wire.extend_from_slice(&payload[..split]);
        let last_header = wire.len();
        wire.extend(fragment_header(2, 3, payload.len() - split));
        wire.extend_from_slice(&payload[split..]);
        (wire, last_header)
    }

    async fn invalid(bytes: &[u8]) {
        let result = Message::from_reader(&mut &bytes[..]).await;
        assert!(
            matches!(result, Err(IdeviceError::UnexpectedResponse(_))),
            "invalid framing must be rejected before reading its claimed body: {result:?}"
        );
    }

    #[tokio::test]
    async fn parses_single_and_fragmented_messages_with_the_same_content() {
        let expected = message();
        let (fragmented, _) = fragmented();
        for wire in [expected.serialize(), fragmented] {
            let actual = Message::from_reader(&mut wire.as_slice()).await.unwrap();
            assert_eq!(actual.data, expected.data);
            assert_eq!(
                actual.aux.unwrap().values,
                expected.aux.clone().unwrap().values
            );
            assert_eq!(actual.message_header.identifier, 42);
            assert_eq!(actual.message_header.fragment_id, 0);
            assert_eq!(actual.message_header.channel, 7);
        }
    }

    #[tokio::test]
    async fn parses_fixed_wire_fragment_zero_announcement_without_a_body() {
        // Literal DTX wire fixture, independent of this module's serializer:
        // id 42 / conversation 1 / channel 7; 3 fragments; 16-byte empty payload.
        // Fragment zero declares the aggregate size and carries no payload.
        let announcement: [u8; 32] = [
            0x79, 0x5b, 0x3d, 0x1f, 32, 0, 0, 0, 0, 0, 3, 0, 16, 0, 0, 0, 42, 0, 0, 0, 1, 0, 0, 0,
            7, 0, 0, 0, 0, 0, 0, 0,
        ];
        let first_body: [u8; 40] = [
            0x79, 0x5b, 0x3d, 0x1f, 32, 0, 0, 0, 1, 0, 3, 0, 8, 0, 0, 0, 42, 0, 0, 0, 1, 0, 0, 0,
            7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ];
        let second_body: [u8; 40] = [
            0x79, 0x5b, 0x3d, 0x1f, 32, 0, 0, 0, 2, 0, 3, 0, 8, 0, 0, 0, 42, 0, 0, 0, 1, 0, 0, 0,
            7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ];
        let wire = [
            announcement.as_slice(),
            first_body.as_slice(),
            second_body.as_slice(),
        ]
        .concat();
        let actual = Message::from_reader(&mut wire.as_slice()).await.unwrap();
        assert_eq!(actual.message_header.identifier, 42);
        assert_eq!(actual.message_header.length, 16);
        assert!(actual.data.is_none());
        assert!(actual.aux.is_none());
    }

    #[tokio::test]
    async fn rejects_invalid_headers_before_allocating_a_body() {
        let base = fragment_header(0, 1, 16);
        for (offset, value) in [
            (0, 0_u32),
            (4, 0),
            (4, 31),
            (4, 33),
            (12, 0),
            (12, 15),
            (12, MAX_DTX_MESSAGE_BYTES as u32 + 1),
            (12, u32::MAX),
            (24, i32::MIN as u32),
            (28, 2),
        ] {
            let mut wire = base.clone();
            wire[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
            invalid(&wire).await;
        }
        for (index, count) in [(0, 0), (1, 1), (2, 2), (1, 3)] {
            invalid(&fragment_header(index, count, 16)).await;
        }
    }

    #[tokio::test]
    async fn rejects_fragment_reordering_and_mixed_message_identities() {
        let (wire, last_header) = fragmented();
        for offset in [DTX_HEADER_BYTES, last_header] {
            for (field, bytes) in [
                (8, 0_u16.to_le_bytes().to_vec()),
                (8, 3_u16.to_le_bytes().to_vec()),
                (10, 4_u16.to_le_bytes().to_vec()),
                (16, 43_u32.to_le_bytes().to_vec()),
                (20, 3_u32.to_le_bytes().to_vec()),
                (24, 8_u32.to_le_bytes().to_vec()),
                (28, 1_u32.to_le_bytes().to_vec()),
            ] {
                let mut damaged = wire.clone();
                damaged[offset + field..offset + field + bytes.len()].copy_from_slice(&bytes);
                invalid(&damaged).await;
            }
        }
    }

    #[tokio::test]
    async fn rejects_aggregate_and_payload_length_mismatches() {
        let mut oversized_aggregate = fragment_header(0, 3, 40);
        oversized_aggregate.extend(fragment_header(1, 3, 30));
        oversized_aggregate.extend([0; 30]);
        oversized_aggregate.extend(fragment_header(2, 3, 20));
        invalid(&oversized_aggregate).await;

        let (mut incomplete_aggregate, _) = fragmented();
        let length = u32::from_le_bytes(incomplete_aggregate[12..16].try_into().unwrap());
        incomplete_aggregate[12..16].copy_from_slice(&(length + 1).to_le_bytes());
        invalid(&incomplete_aggregate).await;

        for (aux, total, trailing) in [
            (1_u32, 0_u32, 0),
            (u32::MAX, 0, 0),
            (0, u32::MAX, 0),
            (16, 1, 1),
            (0, 0, 1),
        ] {
            let mut payload = PayloadHeader {
                aux_length: aux,
                total_length: total,
                ..PayloadHeader::default()
            }
            .serialize();
            payload.extend(vec![0; trailing]);
            let mut wire = fragment_header(0, 1, payload.len());
            wire.extend(payload);
            invalid(&wire).await;
        }
    }

    #[tokio::test]
    async fn rejects_truncated_headers_and_bodies_without_panicking() {
        let wire = message().serialize();
        for end in [0, 1, 31, 32, wire.len() - 1] {
            assert!(Message::from_reader(&mut &wire[..end]).await.is_err());
        }
        let (wire, _) = fragmented();
        assert!(
            Message::from_reader(&mut &wire[..wire.len() - 1])
                .await
                .is_err()
        );
    }

    #[test]
    fn rejects_nested_aux_lengths_before_allocating_and_checked_dictionary_overflow() {
        for buffer_size in [496_u32, 1_u32] {
            for primitive_type in [1_u32, 2_u32] {
                let mut wire = buffer_size.to_le_bytes().to_vec();
                wire.extend(0_u32.to_le_bytes());
                wire.extend(12_u64.to_le_bytes());
                wire.extend(0x0a_u32.to_le_bytes());
                wire.extend(primitive_type.to_le_bytes());
                wire.extend(u32::MAX.to_le_bytes());
                assert!(Aux::from_bytes(wire).is_err());
            }
        }
        let mut modern = 496_u64.to_le_bytes().to_vec();
        modern.extend(u64::MAX.to_le_bytes());
        assert!(Aux::from_bytes(modern).is_err());
        let mut legacy = 1_u64.to_le_bytes().to_vec();
        legacy.extend(16_u64.to_le_bytes());
        legacy.extend(0xf0_u32.to_le_bytes());
        legacy.extend(0_u32.to_le_bytes());
        legacy.extend(u64::MAX.to_le_bytes());
        assert!(Aux::from_bytes(legacy).is_err());
    }
}

#[cfg(test)]
mod debug_security_tests {
    use super::*;

    #[test]
    fn message_debug_omits_decoded_and_raw_payload_bytes() {
        let message = Message {
            message_header: MessageHeader {
                magic: 0x1F3D5B79,
                header_len: 32,
                fragment_id: 0,
                fragment_count: 1,
                length: 4,
                identifier: 1,
                conversation_index: 0,
                channel: 1,
                expects_reply: false,
            },
            payload_header: PayloadHeader {
                total_length: 4,
                ..PayloadHeader::default()
            },
            aux: None,
            data: Some(Value::Data(vec![222, 173, 190, 239])),
            raw_data: Some(vec![222, 173, 190, 239]),
        };

        let description = format!("{message:?}");

        assert!(!description.contains("[222, 173, 190, 239]"));
        assert!(description.contains("has_data: true"));
        assert!(description.contains("raw_data_length: Some(4)"));
    }
}
