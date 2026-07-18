#include "subversionr_bridge.h"

#include <stdio.h>
#include <string.h>

typedef struct probe_baton {
  unsigned int acquire_count;
  unsigned int dispose_count;
  unsigned int settlement_count;
  unsigned int settlement_outcomes[4];
  const char *settlement_leases[4];
  unsigned int fail_settlement_outcome;
  int return_invalid_lease;
  int reuse_first_lease;
  int contract_failed;
} probe_baton;

static int credential_acquire(
  void *raw_baton,
  const subversionr_bridge_remote_credential_request_v2 *request,
  subversionr_bridge_remote_credential_response_v2 *response
) {
  probe_baton *baton = (probe_baton *)raw_baton;
  if (
    baton == NULL || request == NULL || response == NULL ||
    request->realm == NULL || strcmp(request->realm, "fixture realm") != 0 ||
    request->suggested_username == NULL ||
    strcmp(request->suggested_username, "fixture-user") != 0 ||
    request->working_copy_root != NULL ||
    request->attempt > 1 || request->attempt != baton->acquire_count
  ) {
    return 1;
  }
  if (
    (request->attempt == 0 && request->previous_lease_id != NULL) ||
    (
      request->attempt == 1 &&
      (
        request->previous_lease_id == NULL ||
        strcmp(request->previous_lease_id, "lease-0") != 0
      )
    )
  ) {
    baton->contract_failed = 1;
    return 1;
  }

  response->username = "fixture-user";
  response->secret = request->attempt == 0 ? "fixture-secret-0" : "fixture-secret-1";
  response->lease_id = baton->return_invalid_lease
    ? "invalid lease"
    : (
      request->attempt == 0 || baton->reuse_first_lease
        ? "lease-0"
        : "lease-1"
    );
  response->persistence_requested = 1;
  ++baton->acquire_count;
  return 0;
}

static void credential_dispose(
  void *raw_baton,
  subversionr_bridge_remote_credential_response_v2 *response
) {
  probe_baton *baton = (probe_baton *)raw_baton;
  if (baton == NULL || response == NULL) {
    return;
  }
  ++baton->dispose_count;
}

static int credential_settle(
  void *raw_baton,
  const char *lease_id,
  unsigned int outcome
) {
  probe_baton *baton = (probe_baton *)raw_baton;
  if (
    baton == NULL || lease_id == NULL ||
    baton->settlement_count >= 4
  ) {
    return 1;
  }
  unsigned int index = baton->settlement_count++;
  baton->settlement_leases[index] = lease_id;
  baton->settlement_outcomes[index] = outcome;
  return outcome == baton->fail_settlement_outcome ? 1 : 0;
}

static subversionr_bridge_remote_credential_callbacks_v2 callbacks_for(probe_baton *baton) {
  subversionr_bridge_remote_credential_callbacks_v2 callbacks;
  memset(&callbacks, 0, sizeof(callbacks));
  callbacks.abi_version = SUBVERSIONR_BRIDGE_REMOTE_CREDENTIAL_ABI_VERSION;
  callbacks.baton = baton;
  callbacks.credential_callback = credential_acquire;
  callbacks.credential_response_dispose = credential_dispose;
  callbacks.credential_settlement_callback = credential_settle;
  return callbacks;
}

static unsigned int terminal_for_scenario(unsigned int scenario) {
  switch (scenario) {
    case SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_UNUSED:
      return SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_UNUSED;
    case SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_CANCELLED:
      return SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_CANCELLED;
    case SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_TIMED_OUT:
      return SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_TIMED_OUT;
    default:
      return SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_NONE;
  }
}

static int run_success_scenario(unsigned int scenario) {
  probe_baton baton;
  memset(&baton, 0, sizeof(baton));
  subversionr_bridge_remote_credential_callbacks_v2 callbacks = callbacks_for(&baton);
  subversionr_bridge_private_credential_probe_request request = {
    SUBVERSIONR_BRIDGE_REMOTE_CREDENTIAL_ABI_VERSION,
    scenario,
    "fixture realm",
    "fixture-user",
    terminal_for_scenario(scenario)
  };
  subversionr_bridge_private_credential_probe_inspection inspection;
  memset(&inspection, 0, sizeof(inspection));

  int status = subversionr_bridge_private_remote_credential_provider_probe(
    &callbacks,
    &request,
    &inspection
  );
  if (
    status != 0 || baton.contract_failed ||
    inspection.abi_version != SUBVERSIONR_BRIDGE_REMOTE_CREDENTIAL_ABI_VERSION ||
    inspection.scenario != scenario ||
    inspection.terminal_outcome != request.terminal_outcome
  ) {
    fprintf(
      stderr,
      "scenario=%u status=%d contract=%d acquire=%u dispose=%u settle=%u events=%u\n",
      scenario,
      status,
      baton.contract_failed,
      baton.acquire_count,
      baton.dispose_count,
      baton.settlement_count,
      inspection.event_count
    );
    return 0;
  }

  if (scenario == SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_FIRST_NEXT_SAVE) {
    return baton.acquire_count == 2 && baton.dispose_count == 2 &&
      baton.settlement_count == 2 &&
      strcmp(baton.settlement_leases[0], "lease-0") == 0 &&
      baton.settlement_outcomes[0] == SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_REJECTED &&
      strcmp(baton.settlement_leases[1], "lease-1") == 0 &&
      baton.settlement_outcomes[1] == SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_ACCEPTED &&
      inspection.event_count == 4;
  }

  unsigned int expected_outcome = scenario == SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_FIRST_SAVE
    ? SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_ACCEPTED
    : request.terminal_outcome;
  int passed = baton.acquire_count == 1 && baton.dispose_count == 1 &&
    baton.settlement_count == 1 &&
    strcmp(baton.settlement_leases[0], "lease-0") == 0 &&
    baton.settlement_outcomes[0] == expected_outcome &&
    inspection.event_count == 2;
  if (!passed) {
    fprintf(
      stderr,
      "scenario=%u post acquire=%u dispose=%u settle=%u outcome=%u events=%u\n",
      scenario,
      baton.acquire_count,
      baton.dispose_count,
      baton.settlement_count,
      baton.settlement_count > 0 ? baton.settlement_outcomes[0] : 0,
      inspection.event_count
    );
  }
  return passed;
}

static int invalid_contracts_fail_closed(void) {
  probe_baton baton;
  memset(&baton, 0, sizeof(baton));
  subversionr_bridge_remote_credential_callbacks_v2 callbacks = callbacks_for(&baton);
  subversionr_bridge_private_credential_probe_request request = {
    SUBVERSIONR_BRIDGE_REMOTE_CREDENTIAL_ABI_VERSION,
    SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_FIRST_SAVE,
    "fixture realm",
    "fixture-user",
    SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_NONE
  };
  subversionr_bridge_private_credential_probe_inspection inspection;

  callbacks.abi_version = 1;
  if (
    subversionr_bridge_private_remote_credential_provider_probe(
      &callbacks,
      &request,
      &inspection
    ) != 1
  ) {
    return 0;
  }

  callbacks = callbacks_for(&baton);
  request.realm = "fixture\nrealm";
  if (
    subversionr_bridge_private_remote_credential_provider_probe(
      &callbacks,
      &request,
      &inspection
    ) != 1
  ) {
    return 0;
  }

  request.realm = "fixture realm";
  baton.return_invalid_lease = 1;
  if (
    subversionr_bridge_private_remote_credential_provider_probe(
      &callbacks,
      &request,
      &inspection
    ) != 10 ||
    baton.dispose_count != 1 || baton.settlement_count != 0
  ) {
    return 0;
  }

  memset(&baton, 0, sizeof(baton));
  baton.fail_settlement_outcome = SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_ACCEPTED;
  callbacks = callbacks_for(&baton);
  if (subversionr_bridge_private_remote_credential_provider_probe(
    &callbacks,
    &request,
    &inspection
  ) != 10 || baton.settlement_count != 1) {
    return 0;
  }

  memset(&baton, 0, sizeof(baton));
  baton.reuse_first_lease = 1;
  callbacks = callbacks_for(&baton);
  request.scenario = SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_FIRST_NEXT_SAVE;
  return subversionr_bridge_private_remote_credential_provider_probe(
    &callbacks,
    &request,
    &inspection
  ) == 10 && baton.acquire_count == 2 && baton.dispose_count == 2 &&
    baton.settlement_count == 1 &&
    baton.settlement_outcomes[0] == SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_REJECTED;
}

static int remote_context_provider_mask_is_exact(void) {
  subversionr_bridge_remote_config_v1 anonymous = {
    SUBVERSIONR_BRIDGE_REMOTE_CONFIG_ABI_VERSION,
    SUBVERSIONR_BRIDGE_REMOTE_SCHEME_SVN,
    SUBVERSIONR_BRIDGE_REMOTE_AUTH_ANONYMOUS,
    1000,
    0
  };
  subversionr_bridge_remote_context *context = NULL;
  if (subversionr_bridge_remote_context_create(&anonymous, NULL, &context) != 0) {
    return 0;
  }
  subversionr_bridge_remote_config_inspection inspection;
  int passed = subversionr_bridge_remote_context_inspect(context, &inspection) == 0 &&
    inspection.provider_mask == 0;
  subversionr_bridge_remote_context_destroy(context);
  if (!passed) {
    return 0;
  }

  probe_baton baton;
  memset(&baton, 0, sizeof(baton));
  subversionr_bridge_remote_credential_callbacks_v2 callbacks = callbacks_for(&baton);
  subversionr_bridge_remote_config_v1 password = {
    SUBVERSIONR_BRIDGE_REMOTE_CONFIG_ABI_VERSION,
    SUBVERSIONR_BRIDGE_REMOTE_SCHEME_SVN,
    SUBVERSIONR_BRIDGE_REMOTE_AUTH_CRAM_MD5,
    1000,
    0
  };
  context = NULL;
  if (
    subversionr_bridge_remote_context_create(&password, NULL, &context) != 1 ||
    subversionr_bridge_remote_context_create(&anonymous, &callbacks, &context) != 1 ||
    subversionr_bridge_remote_context_create(&password, &callbacks, &context) != 0
  ) {
    return 0;
  }
  passed = subversionr_bridge_remote_context_inspect(context, &inspection) == 0 &&
    inspection.provider_mask == SUBVERSIONR_BRIDGE_REMOTE_PROVIDER_CUSTOM_SIMPLE &&
    subversionr_bridge_remote_context_finish_credentials(
      context,
      SUBVERSIONR_BRIDGE_CREDENTIAL_SETTLEMENT_UNUSED
    ) == 0;
  subversionr_bridge_remote_context_destroy(context);
  return passed;
}

int main(void) {
  const unsigned int scenarios[] = {
    SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_FIRST_SAVE,
    SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_FIRST_NEXT_SAVE,
    SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_UNUSED,
    SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_CANCELLED,
    SUBVERSIONR_BRIDGE_CREDENTIAL_PROBE_TIMED_OUT
  };
  for (size_t index = 0; index < sizeof(scenarios) / sizeof(scenarios[0]); ++index) {
    if (!run_success_scenario(scenarios[index])) {
      fprintf(stderr, "credential provider probe scenario %u failed\n", scenarios[index]);
      return 1;
    }
  }
  if (!invalid_contracts_fail_closed()) {
    fputs("credential provider invalid-contract gate failed\n", stderr);
    return 2;
  }
  if (!remote_context_provider_mask_is_exact()) {
    fputs("credential provider remote-context mask gate failed\n", stderr);
    return 3;
  }
  puts("credential_provider_probe=passed");
  return 0;
}
