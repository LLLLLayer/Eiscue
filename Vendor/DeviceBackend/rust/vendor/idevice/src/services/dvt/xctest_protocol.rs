// SPDX-License-Identifier: MIT
//! Protocol-only XCTest payloads extracted from Jackson Coxson's licensed
//! xctest/types.rs. No Lockdown, provider, runner launch or installation code.
use crate::IdeviceError;
use plist::{Dictionary, Uid, Value};

fn archive_to_bytes(archive: Value) -> Result<Vec<u8>, IdeviceError> {
    let mut bytes = Vec::new();
    plist::to_writer_binary(&mut bytes, &archive)
        .map_err(|_| IdeviceError::UnexpectedResponse("invalid XCTest archive".into()))?;
    Ok(bytes)
}

/// Serialises an `NSUUID` object to NSKeyedArchive bytes.
pub fn archive_nsuuid_to_bytes(uuid: &[u8; 16]) -> Result<Vec<u8>, IdeviceError> {
    let mut class = Dictionary::new();
    class.insert(
        "$classes".into(),
        Value::Array(vec![Value::String("NSUUID".into())]),
    );
    class.insert("$classname".into(), Value::String("NSUUID".into()));

    let mut obj = Dictionary::new();
    obj.insert("$class".into(), Value::Uid(Uid::new(2)));
    obj.insert("NS.uuidbytes".into(), Value::Data(uuid.to_vec()));

    let mut top = Dictionary::new();
    top.insert("root".into(), Value::Uid(Uid::new(1)));

    let mut archive = Dictionary::new();
    archive.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
    archive.insert(
        "$objects".into(),
        Value::Array(vec![
            Value::String("$null".into()),
            Value::Dictionary(obj),
            Value::Dictionary(class),
        ]),
    );
    archive.insert("$top".into(), Value::Dictionary(top));
    archive.insert("$version".into(), Value::Integer(100000u64.into()));

    archive_to_bytes(Value::Dictionary(archive))
}

/// Serialises an `XCTCapabilities` object to NSKeyedArchive bytes matching
/// pymobiledevice3's simple `encode_archive` layout.
pub fn archive_xct_capabilities_to_bytes(
    capabilities: &Dictionary,
) -> Result<Vec<u8>, IdeviceError> {
    let mut objects = vec![Value::String("$null".into())];

    let root_uid = Uid::new(1);
    let xct_caps_class_uid = Uid::new(2);
    let dict_uid = Uid::new(3);
    let nsdict_class_uid = Uid::new(4);

    let mut root = Dictionary::new();
    root.insert("$class".into(), Value::Uid(xct_caps_class_uid));
    root.insert("capabilities-dictionary".into(), Value::Uid(dict_uid));
    objects.push(Value::Dictionary(root));

    let mut xct_caps_class = Dictionary::new();
    xct_caps_class.insert(
        "$classes".into(),
        Value::Array(vec![Value::String("XCTCapabilities".into())]),
    );
    xct_caps_class.insert("$classname".into(), Value::String("XCTCapabilities".into()));
    objects.push(Value::Dictionary(xct_caps_class));

    let key_base = 5u64;
    let mut key_uids = Vec::with_capacity(capabilities.len());
    let mut value_uids = Vec::with_capacity(capabilities.len());

    for (idx, (key, value)) in capabilities.iter().enumerate() {
        let key_uid = Uid::new(key_base + (idx as u64 * 2));
        let value_uid = Uid::new(key_base + (idx as u64 * 2) + 1);
        key_uids.push(Value::Uid(key_uid));
        value_uids.push(Value::Uid(value_uid));
        objects.push(Value::String(key.clone()));
        objects.push(value.clone());
    }

    let mut dict = Dictionary::new();
    dict.insert("$class".into(), Value::Uid(nsdict_class_uid));
    dict.insert("NS.keys".into(), Value::Array(key_uids));
    dict.insert("NS.objects".into(), Value::Array(value_uids));
    objects.insert(dict_uid.get() as usize, Value::Dictionary(dict));

    let mut nsdict_class = Dictionary::new();
    nsdict_class.insert(
        "$classes".into(),
        Value::Array(vec![Value::String("NSDictionary".into())]),
    );
    nsdict_class.insert("$classname".into(), Value::String("NSDictionary".into()));
    objects.insert(
        nsdict_class_uid.get() as usize,
        Value::Dictionary(nsdict_class),
    );

    let mut top = Dictionary::new();
    top.insert("root".into(), Value::Uid(root_uid));

    let mut archive = Dictionary::new();
    archive.insert("$archiver".into(), Value::String("NSKeyedArchiver".into()));
    archive.insert("$objects".into(), Value::Array(objects));
    archive.insert("$top".into(), Value::Dictionary(top));
    archive.insert("$version".into(), Value::Integer(100000u64.into()));

    archive_to_bytes(Value::Dictionary(archive))
}

/// Existing vendored modern IDE capabilities, without the runner orchestration.
pub fn ide_capabilities() -> Dictionary {
    crate::plist!(dict {
        "expected failure test capability": true,
        "test case run configurations": true,
        "test timeout capability": true,
        "test iterations": true,
        "request diagnostics for specific devices": true,
        "delayed attachment transfer": true,
        "skipped test capability": true,
        "daemon container sandbox extension": true,
        "ubiquitous test identifiers": true,
        "XCTIssue capability": true,
    })
}
