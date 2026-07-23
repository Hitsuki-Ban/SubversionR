#[path = "../src/remote_checkout_journal.rs"]
mod remote_checkout_journal;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use remote_checkout_journal::{
    MAX_REMOTE_CHECKOUT_JOURNAL_ENTRIES, REMOTE_CHECKOUT_JOURNAL_FILE_NAME,
    RemoteCheckoutJournalErrorKind, RemoteCheckoutMutationJournal, RemoteCheckoutMutationState,
};

const OPERATION_1: &str = "01234567-89ab-4def-8123-456789abcdef";
const OPERATION_2: &str = "11234567-89ab-4def-8123-456789abcdef";
const OPERATION_3: &str = "21234567-89ab-4def-8123-456789abcdef";
const OPERATION_4: &str = "31234567-89ab-4def-8123-456789abcdef";

static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(1);

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "subversionr-checkout-journal-{}-{}",
            std::process::id(),
            NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).expect("test storage root");
        Self(path.canonicalize().expect("canonical test storage root"))
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn target(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn arm_restart_blocks_and_clear_persists_exact_entry() {
    let root = TestDirectory::new();
    let target = root.target("new-working-copy");
    let mut journal = RemoteCheckoutMutationJournal::open(root.path()).expect("open journal");
    let armed = journal.arm(&target, OPERATION_1).expect("arm target");
    assert_eq!(armed.state, RemoteCheckoutMutationState::Armed);
    assert!(
        root.path()
            .join(REMOTE_CHECKOUT_JOURNAL_FILE_NAME)
            .is_file()
    );

    drop(journal);
    let mut restarted = RemoteCheckoutMutationJournal::open(root.path()).expect("restart journal");
    assert_eq!(restarted.entries().len(), 1);
    assert_eq!(
        restarted.entries()[0].state,
        RemoteCheckoutMutationState::Blocked
    );
    restarted
        .clear(&armed.target_sha256, OPERATION_1)
        .expect("clear exact entry");
    drop(restarted);

    let empty = RemoteCheckoutMutationJournal::open(root.path()).expect("reopen empty journal");
    assert!(empty.entries().is_empty());
}

#[test]
fn mark_blocked_is_attributed_and_durable() {
    let root = TestDirectory::new();
    let mut journal = RemoteCheckoutMutationJournal::open(root.path()).expect("open journal");
    let armed = journal
        .arm(root.target("target"), OPERATION_2)
        .expect("arm target");
    assert_eq!(
        journal
            .mark_blocked(&armed.target_sha256, "41234567-89ab-4def-8123-456789abcdef",)
            .expect_err("wrong attribution must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::EntryNotFound
    );
    journal
        .mark_blocked(&armed.target_sha256, OPERATION_2)
        .expect("block exact entry");
    drop(journal);

    let restarted = RemoteCheckoutMutationJournal::open(root.path()).expect("restart journal");
    assert_eq!(
        restarted.entries()[0].state,
        RemoteCheckoutMutationState::Blocked
    );
}

#[test]
fn arm_rejects_noncanonical_operation_identity() {
    let root = TestDirectory::new();
    let mut journal = RemoteCheckoutMutationJournal::open(root.path()).expect("open journal");
    assert_eq!(
        journal
            .arm(root.target("target"), "operation-with-possible-prose")
            .expect_err("non-UUID operation identity must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::OperationIdInvalid
    );
    assert!(journal.entries().is_empty());
}

#[test]
fn open_rejects_relative_missing_and_file_roots() {
    let relative = RemoteCheckoutMutationJournal::open(Path::new("relative-root"))
        .err()
        .expect("relative root must fail");
    assert_eq!(
        relative.kind(),
        RemoteCheckoutJournalErrorKind::StorageRootNotAbsolute
    );

    let root = TestDirectory::new();
    let missing = root.target("missing-root");
    assert_eq!(
        RemoteCheckoutMutationJournal::open(&missing)
            .err()
            .expect("missing root must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::StorageRootUnavailable
    );

    let file = root.target("root-file");
    fs::write(&file, b"not a directory").expect("write root file");
    assert_eq!(
        RemoteCheckoutMutationJournal::open(&file)
            .err()
            .expect("file root must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::StorageRootNotDirectory
    );
}

#[test]
fn corrupted_unknown_and_tampered_documents_fail_fast() {
    let cases = [
        (
            r#"{"schemaVersion":1,"entries":[],"unknown":true}"#,
            RemoteCheckoutJournalErrorKind::JournalCorrupt,
        ),
        (
            r#"{"schemaVersion":2,"entries":[]}"#,
            RemoteCheckoutJournalErrorKind::UnsupportedSchema,
        ),
        (
            r#"{"schemaVersion":1,"entries":[{"targetPath":"relative","targetSha256":"00","originOperationId":"21234567-89ab-4def-8123-456789abcdef","effect":"checkoutTarget","state":"blocked"}]}"#,
            RemoteCheckoutJournalErrorKind::TargetPathInvalid,
        ),
    ];
    for (document, expected) in cases {
        let root = TestDirectory::new();
        fs::write(
            root.path().join(REMOTE_CHECKOUT_JOURNAL_FILE_NAME),
            document,
        )
        .expect("write tampered journal");
        assert_eq!(
            RemoteCheckoutMutationJournal::open(root.path())
                .err()
                .expect("tampered journal must fail")
                .kind(),
            expected
        );
    }
}

#[test]
fn target_hash_tampering_is_rejected() {
    let root = TestDirectory::new();
    let mut journal = RemoteCheckoutMutationJournal::open(root.path()).expect("open journal");
    journal
        .arm(root.target("hash-target"), OPERATION_4)
        .expect("arm target");
    drop(journal);

    let path = root.path().join(REMOTE_CHECKOUT_JOURNAL_FILE_NAME);
    let mut value: serde_json::Value =
        serde_json::from_slice(&fs::read(&path).expect("read journal")).expect("parse journal");
    value["entries"][0]["targetSha256"] = serde_json::Value::String("0".repeat(64));
    fs::write(&path, serde_json::to_vec(&value).expect("serialize tamper")).expect("write tamper");
    assert_eq!(
        RemoteCheckoutMutationJournal::open(root.path())
            .err()
            .expect("hash tamper must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::JournalCorrupt
    );
}

#[test]
fn orphaned_atomic_temporary_file_fails_fast() {
    let root = TestDirectory::new();
    fs::write(
        root.path()
            .join(".subversionr-remote-checkout-mutations-v1.tmp"),
        b"partial",
    )
    .expect("write orphaned temporary file");
    assert_eq!(
        RemoteCheckoutMutationJournal::open(root.path())
            .err()
            .expect("orphaned temporary file must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::OrphanedTemporaryFile
    );
}

#[test]
fn entry_limit_and_duplicate_targets_are_rejected_without_changing_disk() {
    let root = TestDirectory::new();
    let mut journal = RemoteCheckoutMutationJournal::open(root.path()).expect("open journal");
    let first_target = root.target("target-0");
    journal
        .arm(&first_target, OPERATION_3)
        .expect("arm first target");
    assert_eq!(
        journal
            .arm(&first_target, "51234567-89ab-4def-8123-456789abcdef",)
            .expect_err("duplicate target must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::EntryAlreadyExists
    );
    for index in 1..MAX_REMOTE_CHECKOUT_JOURNAL_ENTRIES {
        journal
            .arm(
                root.target(&format!("target-{index}")),
                &format!("61234567-89ab-4def-8123-{index:012x}"),
            )
            .expect("arm bounded entry");
    }
    assert_eq!(
        journal
            .arm(
                root.target("target-over-limit"),
                "71234567-89ab-4def-8123-456789abcdef",
            )
            .expect_err("entry over limit must fail")
            .kind(),
        RemoteCheckoutJournalErrorKind::EntryLimitExceeded
    );
    assert_eq!(journal.entries().len(), MAX_REMOTE_CHECKOUT_JOURNAL_ENTRIES);
    assert!(
        !root
            .path()
            .join(".subversionr-remote-checkout-mutations-v1.tmp")
            .exists()
    );
}
