use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const REMOTE_CHECKOUT_JOURNAL_FILE_NAME: &str = "subversionr-remote-checkout-mutations-v1.json";
const REMOTE_CHECKOUT_JOURNAL_TEMP_FILE_NAME: &str =
    ".subversionr-remote-checkout-mutations-v1.tmp";
const JOURNAL_SCHEMA_VERSION: u16 = 1;
const MAX_JOURNAL_BYTES: u64 = 128 * 1024;
pub const MAX_REMOTE_CHECKOUT_JOURNAL_ENTRIES: usize = 128;
const MAX_TARGET_PATH_BYTES: usize = 32 * 1024;

#[derive(Debug)]
pub struct RemoteCheckoutJournalError {
    kind: RemoteCheckoutJournalErrorKind,
    source: Option<io::Error>,
}

impl RemoteCheckoutJournalError {
    fn new(kind: RemoteCheckoutJournalErrorKind) -> Self {
        Self { kind, source: None }
    }

    fn io(kind: RemoteCheckoutJournalErrorKind, source: io::Error) -> Self {
        Self {
            kind,
            source: Some(source),
        }
    }

    pub fn kind(&self) -> RemoteCheckoutJournalErrorKind {
        self.kind
    }
}

impl fmt::Display for RemoteCheckoutJournalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self.kind {
            RemoteCheckoutJournalErrorKind::StorageRootNotAbsolute => {
                "remote checkout journal storage root is not absolute"
            }
            RemoteCheckoutJournalErrorKind::StorageRootUnavailable => {
                "remote checkout journal storage root is unavailable"
            }
            RemoteCheckoutJournalErrorKind::StorageRootNotDirectory => {
                "remote checkout journal storage root is not a directory"
            }
            RemoteCheckoutJournalErrorKind::OrphanedTemporaryFile => {
                "remote checkout journal has an orphaned temporary file"
            }
            RemoteCheckoutJournalErrorKind::JournalTooLarge => {
                "remote checkout journal exceeds its byte limit"
            }
            RemoteCheckoutJournalErrorKind::JournalCorrupt => "remote checkout journal is corrupt",
            RemoteCheckoutJournalErrorKind::UnsupportedSchema => {
                "remote checkout journal schema is unsupported"
            }
            RemoteCheckoutJournalErrorKind::EntryLimitExceeded => {
                "remote checkout journal entry limit is exceeded"
            }
            RemoteCheckoutJournalErrorKind::TargetPathInvalid => {
                "remote checkout journal target path is invalid"
            }
            RemoteCheckoutJournalErrorKind::OperationIdInvalid => {
                "remote checkout journal origin operation id is invalid"
            }
            RemoteCheckoutJournalErrorKind::EntryAlreadyExists => {
                "remote checkout journal entry already exists"
            }
            RemoteCheckoutJournalErrorKind::EntryNotFound => {
                "remote checkout journal entry was not found"
            }
            RemoteCheckoutJournalErrorKind::AtomicWriteFailed => {
                "remote checkout journal atomic write failed"
            }
        };
        formatter.write_str(message)?;
        if let Some(source) = &self.source {
            write!(formatter, ": {source}")?;
        }
        Ok(())
    }
}

impl std::error::Error for RemoteCheckoutJournalError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.source
            .as_ref()
            .map(|source| source as &(dyn std::error::Error + 'static))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteCheckoutJournalErrorKind {
    StorageRootNotAbsolute,
    StorageRootUnavailable,
    StorageRootNotDirectory,
    OrphanedTemporaryFile,
    JournalTooLarge,
    JournalCorrupt,
    UnsupportedSchema,
    EntryLimitExceeded,
    TargetPathInvalid,
    OperationIdInvalid,
    EntryAlreadyExists,
    EntryNotFound,
    AtomicWriteFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteCheckoutMutationEffect {
    CheckoutTarget,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteCheckoutMutationState {
    Armed,
    Blocked,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemoteCheckoutMutationEntry {
    pub target_path: String,
    pub target_sha256: String,
    pub origin_operation_id: String,
    pub effect: RemoteCheckoutMutationEffect,
    pub state: RemoteCheckoutMutationState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RemoteCheckoutJournalDocument {
    schema_version: u16,
    entries: Vec<RemoteCheckoutMutationEntry>,
}

pub struct RemoteCheckoutMutationJournal {
    storage_root: PathBuf,
    journal_path: PathBuf,
    document: RemoteCheckoutJournalDocument,
}

impl RemoteCheckoutMutationJournal {
    pub fn open(storage_root: impl AsRef<Path>) -> Result<Self, RemoteCheckoutJournalError> {
        let storage_root = validate_storage_root(storage_root.as_ref())?;
        let journal_path = storage_root.join(REMOTE_CHECKOUT_JOURNAL_FILE_NAME);
        let temporary_path = storage_root.join(REMOTE_CHECKOUT_JOURNAL_TEMP_FILE_NAME);
        if temporary_path.exists() {
            return Err(RemoteCheckoutJournalError::new(
                RemoteCheckoutJournalErrorKind::OrphanedTemporaryFile,
            ));
        }

        let mut journal = Self {
            storage_root,
            journal_path,
            document: RemoteCheckoutJournalDocument {
                schema_version: JOURNAL_SCHEMA_VERSION,
                entries: Vec::new(),
            },
        };

        if journal.journal_path.exists() {
            journal.document = load_document(&journal.journal_path)?;
            let mut armed = false;
            for entry in &mut journal.document.entries {
                if entry.state == RemoteCheckoutMutationState::Armed {
                    entry.state = RemoteCheckoutMutationState::Blocked;
                    armed = true;
                }
            }
            if armed {
                journal.persist(&journal.document)?;
            }
        } else {
            journal.persist(&journal.document)?;
        }
        Ok(journal)
    }

    pub fn entries(&self) -> &[RemoteCheckoutMutationEntry] {
        &self.document.entries
    }

    pub fn arm(
        &mut self,
        target: impl AsRef<Path>,
        origin_operation_id: &str,
    ) -> Result<RemoteCheckoutMutationEntry, RemoteCheckoutJournalError> {
        validate_operation_id(origin_operation_id)?;
        let target_path = normalized_absolute_path(target.as_ref())?;
        let target_sha256 = target_path_sha256(&target_path);
        if self
            .document
            .entries
            .iter()
            .any(|entry| entry.target_sha256 == target_sha256)
        {
            return Err(RemoteCheckoutJournalError::new(
                RemoteCheckoutJournalErrorKind::EntryAlreadyExists,
            ));
        }
        if self.document.entries.len() >= MAX_REMOTE_CHECKOUT_JOURNAL_ENTRIES {
            return Err(RemoteCheckoutJournalError::new(
                RemoteCheckoutJournalErrorKind::EntryLimitExceeded,
            ));
        }

        let entry = RemoteCheckoutMutationEntry {
            target_path,
            target_sha256,
            origin_operation_id: origin_operation_id.to_owned(),
            effect: RemoteCheckoutMutationEffect::CheckoutTarget,
            state: RemoteCheckoutMutationState::Armed,
        };
        let mut next = self.document.clone();
        next.entries.push(entry.clone());
        self.persist(&next)?;
        self.document = next;
        Ok(entry)
    }

    pub fn mark_blocked(
        &mut self,
        target_sha256: &str,
        origin_operation_id: &str,
    ) -> Result<RemoteCheckoutMutationEntry, RemoteCheckoutJournalError> {
        validate_entry_identity(target_sha256, origin_operation_id)?;
        let mut next = self.document.clone();
        let entry = find_entry_mut(&mut next, target_sha256, origin_operation_id)?;
        entry.state = RemoteCheckoutMutationState::Blocked;
        let entry = entry.clone();
        self.persist(&next)?;
        self.document = next;
        Ok(entry)
    }

    pub fn clear(
        &mut self,
        target_sha256: &str,
        origin_operation_id: &str,
    ) -> Result<RemoteCheckoutMutationEntry, RemoteCheckoutJournalError> {
        validate_entry_identity(target_sha256, origin_operation_id)?;
        let position = self
            .document
            .entries
            .iter()
            .position(|entry| {
                entry.target_sha256 == target_sha256
                    && entry.origin_operation_id == origin_operation_id
            })
            .ok_or_else(|| {
                RemoteCheckoutJournalError::new(RemoteCheckoutJournalErrorKind::EntryNotFound)
            })?;
        let mut next = self.document.clone();
        let entry = next.entries.remove(position);
        self.persist(&next)?;
        self.document = next;
        Ok(entry)
    }

    fn persist(
        &self,
        document: &RemoteCheckoutJournalDocument,
    ) -> Result<(), RemoteCheckoutJournalError> {
        let bytes = serde_json::to_vec(document).map_err(|_| {
            RemoteCheckoutJournalError::new(RemoteCheckoutJournalErrorKind::JournalCorrupt)
        })?;
        if bytes.len() as u64 > MAX_JOURNAL_BYTES {
            return Err(RemoteCheckoutJournalError::new(
                RemoteCheckoutJournalErrorKind::JournalTooLarge,
            ));
        }
        atomic_replace(
            &self.storage_root,
            &self.journal_path,
            &self
                .storage_root
                .join(REMOTE_CHECKOUT_JOURNAL_TEMP_FILE_NAME),
            &bytes,
        )
    }
}

fn validate_storage_root(storage_root: &Path) -> Result<PathBuf, RemoteCheckoutJournalError> {
    if !storage_root.is_absolute() {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::StorageRootNotAbsolute,
        ));
    }
    let metadata = fs::metadata(storage_root).map_err(|source| {
        RemoteCheckoutJournalError::io(
            RemoteCheckoutJournalErrorKind::StorageRootUnavailable,
            source,
        )
    })?;
    if !metadata.is_dir() {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::StorageRootNotDirectory,
        ));
    }
    storage_root.canonicalize().map_err(|source| {
        RemoteCheckoutJournalError::io(
            RemoteCheckoutJournalErrorKind::StorageRootUnavailable,
            source,
        )
    })
}

fn load_document(path: &Path) -> Result<RemoteCheckoutJournalDocument, RemoteCheckoutJournalError> {
    let metadata = fs::metadata(path).map_err(|source| {
        RemoteCheckoutJournalError::io(RemoteCheckoutJournalErrorKind::JournalCorrupt, source)
    })?;
    if !metadata.is_file() || metadata.len() > MAX_JOURNAL_BYTES {
        return Err(RemoteCheckoutJournalError::new(
            if metadata.len() > MAX_JOURNAL_BYTES {
                RemoteCheckoutJournalErrorKind::JournalTooLarge
            } else {
                RemoteCheckoutJournalErrorKind::JournalCorrupt
            },
        ));
    }
    let bytes = fs::read(path).map_err(|source| {
        RemoteCheckoutJournalError::io(RemoteCheckoutJournalErrorKind::JournalCorrupt, source)
    })?;
    let document: RemoteCheckoutJournalDocument = serde_json::from_slice(&bytes).map_err(|_| {
        RemoteCheckoutJournalError::new(RemoteCheckoutJournalErrorKind::JournalCorrupt)
    })?;
    validate_document(&document)?;
    Ok(document)
}

fn validate_document(
    document: &RemoteCheckoutJournalDocument,
) -> Result<(), RemoteCheckoutJournalError> {
    if document.schema_version != JOURNAL_SCHEMA_VERSION {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::UnsupportedSchema,
        ));
    }
    if document.entries.len() > MAX_REMOTE_CHECKOUT_JOURNAL_ENTRIES {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::EntryLimitExceeded,
        ));
    }
    let mut identities = std::collections::BTreeSet::new();
    for entry in &document.entries {
        validate_operation_id(&entry.origin_operation_id)?;
        let normalized = normalized_absolute_path(Path::new(&entry.target_path))?;
        if normalized != entry.target_path
            || target_path_sha256(&entry.target_path) != entry.target_sha256
            || !identities.insert(entry.target_sha256.clone())
        {
            return Err(RemoteCheckoutJournalError::new(
                RemoteCheckoutJournalErrorKind::JournalCorrupt,
            ));
        }
    }
    Ok(())
}

fn validate_operation_id(value: &str) -> Result<(), RemoteCheckoutJournalError> {
    let canonical_uuid = value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        })
        && value.bytes().any(|byte| byte != b'0' && byte != b'-');
    if !canonical_uuid {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::OperationIdInvalid,
        ));
    }
    Ok(())
}

fn validate_entry_identity(
    target_sha256: &str,
    origin_operation_id: &str,
) -> Result<(), RemoteCheckoutJournalError> {
    validate_operation_id(origin_operation_id)?;
    if target_sha256.len() != 64
        || !target_sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::TargetPathInvalid,
        ));
    }
    Ok(())
}

fn find_entry_mut<'a>(
    document: &'a mut RemoteCheckoutJournalDocument,
    target_sha256: &str,
    origin_operation_id: &str,
) -> Result<&'a mut RemoteCheckoutMutationEntry, RemoteCheckoutJournalError> {
    document
        .entries
        .iter_mut()
        .find(|entry| {
            entry.target_sha256 == target_sha256 && entry.origin_operation_id == origin_operation_id
        })
        .ok_or_else(|| {
            RemoteCheckoutJournalError::new(RemoteCheckoutJournalErrorKind::EntryNotFound)
        })
}

fn normalized_absolute_path(path: &Path) -> Result<String, RemoteCheckoutJournalError> {
    if !path.is_absolute() {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::TargetPathInvalid,
        ));
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                normalized.push(component.as_os_str());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() || !normalized.is_absolute() {
                    return Err(RemoteCheckoutJournalError::new(
                        RemoteCheckoutJournalErrorKind::TargetPathInvalid,
                    ));
                }
            }
        }
    }
    let value = normalized.to_str().ok_or_else(|| {
        RemoteCheckoutJournalError::new(RemoteCheckoutJournalErrorKind::TargetPathInvalid)
    })?;
    if value.as_bytes().len() > MAX_TARGET_PATH_BYTES {
        return Err(RemoteCheckoutJournalError::new(
            RemoteCheckoutJournalErrorKind::TargetPathInvalid,
        ));
    }
    Ok(value.to_owned())
}

fn target_path_sha256(target_path: &str) -> String {
    format!("{:x}", Sha256::digest(target_path.as_bytes()))
}

fn atomic_replace(
    storage_root: &Path,
    destination: &Path,
    temporary: &Path,
    bytes: &[u8],
) -> Result<(), RemoteCheckoutJournalError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temporary)
        .map_err(|source| {
            RemoteCheckoutJournalError::io(
                RemoteCheckoutJournalErrorKind::AtomicWriteFailed,
                source,
            )
        })?;
    file.write_all(bytes).map_err(|source| {
        RemoteCheckoutJournalError::io(RemoteCheckoutJournalErrorKind::AtomicWriteFailed, source)
    })?;
    file.sync_all().map_err(|source| {
        RemoteCheckoutJournalError::io(RemoteCheckoutJournalErrorKind::AtomicWriteFailed, source)
    })?;
    drop(file);

    replace_file(temporary, destination).map_err(|source| {
        RemoteCheckoutJournalError::io(RemoteCheckoutJournalErrorKind::AtomicWriteFailed, source)
    })?;
    sync_storage_root(storage_root).map_err(|source| {
        RemoteCheckoutJournalError::io(RemoteCheckoutJournalErrorKind::AtomicWriteFailed, source)
    })
}

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;

    const MOVEFILE_REPLACE_EXISTING: u32 = 0x0000_0001;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x0000_0008;
    unsafe extern "system" {
        fn MoveFileExW(
            existing_file_name: *const u16,
            new_file_name: *const u16,
            flags: u32,
        ) -> i32;
    }

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let moved = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(windows)]
fn sync_storage_root(_storage_root: &Path) -> io::Result<()> {
    // MoveFileExW with MOVEFILE_WRITE_THROUGH flushes the move before returning.
    Ok(())
}

#[cfg(not(windows))]
fn sync_storage_root(storage_root: &Path) -> io::Result<()> {
    fs::File::open(storage_root)?.sync_all()
}
