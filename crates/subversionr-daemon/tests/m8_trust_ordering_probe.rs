use std::collections::BTreeMap;
use std::sync::{Arc, Barrier, Mutex};
use std::thread;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OperationState {
    Queued,
    Reserved { trust_epoch: u64 },
    Active,
    Terminating,
    Cancelled,
    Terminated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LaunchReservation {
    operation_id: u64,
    trust_epoch: u64,
}

#[derive(Debug)]
struct TrustGate {
    trusted: bool,
    trust_epoch: u64,
    acknowledged_epoch: u64,
    operations: BTreeMap<u64, OperationState>,
    worker_resume_count: u64,
}

impl TrustGate {
    fn new(trusted: bool, trust_epoch: u64) -> Self {
        assert!(trust_epoch > 0);
        Self {
            trusted,
            trust_epoch,
            acknowledged_epoch: trust_epoch,
            operations: BTreeMap::new(),
            worker_resume_count: 0,
        }
    }

    fn queue(&mut self, operation_id: u64) {
        assert!(
            self.operations
                .insert(operation_id, OperationState::Queued)
                .is_none()
        );
    }

    fn reserve_launch(
        &mut self,
        operation_id: u64,
        envelope_epoch: u64,
    ) -> Option<LaunchReservation> {
        if !self.trusted
            || envelope_epoch != self.trust_epoch
            || envelope_epoch != self.acknowledged_epoch
        {
            return None;
        }
        let state = self.operations.get_mut(&operation_id)?;
        if *state != OperationState::Queued {
            return None;
        }
        *state = OperationState::Reserved {
            trust_epoch: envelope_epoch,
        };
        Some(LaunchReservation {
            operation_id,
            trust_epoch: envelope_epoch,
        })
    }

    fn commit_worker_resume(&mut self, reservation: LaunchReservation) -> bool {
        if !self.trusted
            || self.trust_epoch != reservation.trust_epoch
            || self.acknowledged_epoch != reservation.trust_epoch
        {
            return false;
        }
        let Some(state) = self.operations.get_mut(&reservation.operation_id) else {
            return false;
        };
        if *state
            != (OperationState::Reserved {
                trust_epoch: reservation.trust_epoch,
            })
        {
            return false;
        }
        *state = OperationState::Active;
        self.worker_resume_count += 1;
        true
    }

    fn apply_trust_update(&mut self, trusted: bool, trust_epoch: u64) -> Result<(), &'static str> {
        let expected_epoch = self
            .trust_epoch
            .checked_add(1)
            .ok_or("trust epoch overflow")?;
        if trust_epoch != expected_epoch {
            return Err("trust update epoch must be the exact next connection epoch");
        }

        self.trusted = trusted;
        self.trust_epoch = trust_epoch;
        if !trusted {
            for state in self.operations.values_mut() {
                *state = match *state {
                    OperationState::Queued | OperationState::Reserved { .. } => {
                        OperationState::Cancelled
                    }
                    OperationState::Active => OperationState::Terminating,
                    other => other,
                };
            }
        }
        Ok(())
    }

    fn terminate_active_worker(&mut self, operation_id: u64) {
        let state = self
            .operations
            .get_mut(&operation_id)
            .expect("operation must exist");
        assert_eq!(*state, OperationState::Terminating);
        *state = OperationState::Terminated;
    }

    fn acknowledge_trust_update(&mut self, trust_epoch: u64) -> Result<u64, &'static str> {
        if trust_epoch != self.trust_epoch {
            return Err("only the current trust epoch can be acknowledged");
        }
        if !self.trusted
            && self.operations.values().any(|state| {
                matches!(
                    state,
                    OperationState::Queued
                        | OperationState::Reserved { .. }
                        | OperationState::Active
                        | OperationState::Terminating
                )
            })
        {
            return Err(
                "revocation cannot be acknowledged while launch or worker activity remains",
            );
        }
        self.acknowledged_epoch = trust_epoch;
        Ok(trust_epoch)
    }
}

#[derive(Debug)]
struct ExtensionGrantGate {
    current_epoch: u64,
    remote_submission_enabled: bool,
    pending_grant_epoch: Option<u64>,
}

impl ExtensionGrantGate {
    fn initially_untrusted(initial_epoch: u64) -> Self {
        assert!(initial_epoch > 0);
        Self {
            current_epoch: initial_epoch,
            remote_submission_enabled: false,
            pending_grant_epoch: None,
        }
    }

    fn begin_grant(&mut self) -> u64 {
        assert!(self.pending_grant_epoch.is_none());
        self.remote_submission_enabled = false;
        self.current_epoch = self
            .current_epoch
            .checked_add(1)
            .expect("trust epoch overflow");
        self.pending_grant_epoch = Some(self.current_epoch);
        self.current_epoch
    }

    fn acknowledge_grant(&mut self, acknowledged_epoch: u64) {
        assert_eq!(self.pending_grant_epoch, Some(acknowledged_epoch));
        self.pending_grant_epoch = None;
        self.remote_submission_enabled = true;
    }

    fn observe_local_revocation(&mut self) {
        self.remote_submission_enabled = false;
        self.pending_grant_epoch = None;
    }
}

#[test]
fn revocation_cancels_queued_and_reserved_launches_before_acknowledgement() {
    let mut gate = TrustGate::new(true, 1);
    gate.queue(1);
    gate.queue(2);
    let reserved = gate
        .reserve_launch(2, 1)
        .expect("second operation should reserve");

    gate.apply_trust_update(false, 2)
        .expect("exact next epoch must be accepted");
    assert_eq!(gate.operations[&1], OperationState::Cancelled);
    assert_eq!(gate.operations[&2], OperationState::Cancelled);
    assert!(!gate.commit_worker_resume(reserved));
    assert_eq!(gate.worker_resume_count, 0);
    assert_eq!(gate.acknowledge_trust_update(2), Ok(2));

    gate.queue(3);
    assert_eq!(
        gate.reserve_launch(3, 1),
        None,
        "stale envelope epoch must fail"
    );
    assert_eq!(
        gate.reserve_launch(3, 3),
        None,
        "future envelope epoch must fail"
    );
}

#[test]
fn revocation_ack_waits_for_an_active_worker_to_reach_terminal_cleanup() {
    let mut gate = TrustGate::new(true, 11);
    gate.queue(7);
    let reservation = gate
        .reserve_launch(7, 11)
        .expect("operation should reserve");
    assert!(gate.commit_worker_resume(reservation));

    gate.apply_trust_update(false, 12)
        .expect("exact next epoch must be accepted");
    assert_eq!(gate.operations[&7], OperationState::Terminating);
    assert_eq!(
        gate.acknowledge_trust_update(12),
        Err("revocation cannot be acknowledged while launch or worker activity remains")
    );

    gate.terminate_active_worker(7);
    assert_eq!(gate.acknowledge_trust_update(12), Ok(12));
}

#[test]
fn reserved_to_resume_race_is_linearized_by_the_revocation_gate() {
    let gate = Arc::new(Mutex::new(TrustGate::new(true, 20)));
    gate.lock().expect("gate lock").queue(99);
    let reserved = Arc::new(Barrier::new(2));
    let revoked = Arc::new(Barrier::new(2));

    let launch_gate = Arc::clone(&gate);
    let launch_reserved = Arc::clone(&reserved);
    let launch_revoked = Arc::clone(&revoked);
    let launcher = thread::spawn(move || {
        let reservation = launch_gate
            .lock()
            .expect("gate lock")
            .reserve_launch(99, 20)
            .expect("operation should reserve before revocation");
        launch_reserved.wait();
        launch_revoked.wait();
        launch_gate
            .lock()
            .expect("gate lock")
            .commit_worker_resume(reservation)
    });

    reserved.wait();
    {
        let mut gate = gate.lock().expect("gate lock");
        gate.apply_trust_update(false, 21)
            .expect("exact next epoch must be accepted");
        assert_eq!(gate.acknowledge_trust_update(21), Ok(21));
    }
    revoked.wait();

    assert!(!launcher.join().expect("launcher thread should complete"));
    assert_eq!(gate.lock().expect("gate lock").worker_resume_count, 0);
}

#[test]
fn grant_ack_is_the_only_transition_that_enables_remote_submission() {
    let mut extension = ExtensionGrantGate::initially_untrusted(30);
    assert!(!extension.remote_submission_enabled);

    let grant_epoch = extension.begin_grant();
    assert_eq!(grant_epoch, 31);
    assert!(!extension.remote_submission_enabled);

    let mut daemon = TrustGate::new(false, 30);
    daemon
        .apply_trust_update(true, grant_epoch)
        .expect("grant must use the exact next epoch");
    let acknowledged = daemon
        .acknowledge_trust_update(grant_epoch)
        .expect("grant should acknowledge immediately");
    extension.acknowledge_grant(acknowledged);
    assert!(extension.remote_submission_enabled);

    extension.observe_local_revocation();
    assert!(!extension.remote_submission_enabled);
}

#[test]
fn daemon_cannot_reserve_or_resume_a_worker_until_grant_is_acknowledged() {
    let mut daemon = TrustGate::new(false, 50);
    daemon.queue(1);
    daemon
        .apply_trust_update(true, 51)
        .expect("grant must use the exact next epoch");

    assert_eq!(daemon.reserve_launch(1, 51), None);
    daemon
        .operations
        .insert(2, OperationState::Reserved { trust_epoch: 51 });
    let unacknowledged_reservation = LaunchReservation {
        operation_id: 2,
        trust_epoch: 51,
    };
    assert!(!daemon.commit_worker_resume(unacknowledged_reservation));
    assert_eq!(daemon.worker_resume_count, 0);

    daemon
        .acknowledge_trust_update(51)
        .expect("current grant epoch must acknowledge");
    let reservation = daemon
        .reserve_launch(1, 51)
        .expect("acknowledged grant may reserve the queued operation");
    assert!(daemon.commit_worker_resume(reservation));
    assert!(daemon.commit_worker_resume(unacknowledged_reservation));
    assert_eq!(daemon.worker_resume_count, 2);
}

#[test]
fn trust_updates_reject_skipped_replayed_and_future_epochs() {
    let mut gate = TrustGate::new(false, 40);
    assert_eq!(
        gate.apply_trust_update(true, 42),
        Err("trust update epoch must be the exact next connection epoch")
    );
    gate.apply_trust_update(true, 41)
        .expect("exact next epoch must succeed");
    assert_eq!(
        gate.apply_trust_update(false, 41),
        Err("trust update epoch must be the exact next connection epoch")
    );
    assert_eq!(
        gate.apply_trust_update(false, 43),
        Err("trust update epoch must be the exact next connection epoch")
    );
}
