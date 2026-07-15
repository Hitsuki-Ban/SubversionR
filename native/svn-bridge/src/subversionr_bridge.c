#include "subversionr_bridge.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#endif

#include <apr_hash.h>
#include <apr_pools.h>
#include <apr_strings.h>
#include <apr_tables.h>
#include <svn_client.h>
#include <svn_auth.h>
#include <svn_config.h>
#include <svn_diff.h>
#include <svn_dirent_uri.h>
#include <svn_error_codes.h>
#include <svn_hash.h>
#include <svn_io.h>
#include <svn_opt.h>
#include <svn_props.h>
#include <svn_string.h>
#include <svn_time.h>
#include <svn_types.h>
#include <svn_user.h>
#include <svn_wc.h>
#include <svn_version.h>

#ifdef _WIN32
#define BRIDGE_PRELOAD_MODULE_COUNT 3
#endif
#define BRIDGE_MAX_SVN_REVNUM 2147483647L
#define BRIDGE_AUTH_CALLBACK_OK 0
#define BRIDGE_STATUS_CANCEL_CALLBACK_FAILED 10
#define BRIDGE_STATUS_CANCELLED 11
#define BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED 11
#define BRIDGE_OPERATION_CANCELLED 12

struct subversionr_bridge_runtime {
  apr_pool_t *pool;
  apr_pool_t *result_pool;
  svn_client_ctx_t *ctx;
  subversionr_bridge_error_entry last_error_entries[SUBVERSIONR_BRIDGE_ERROR_ENTRY_LIMIT];
  size_t last_error_entry_count;
  int last_error_truncated;
};

static void bridge_clear_last_error(subversionr_bridge_runtime *runtime) {
  runtime->last_error_entry_count = 0;
  runtime->last_error_truncated = 0;
}

static void bridge_capture_error(subversionr_bridge_runtime *runtime, const svn_error_t *error) {
  bridge_clear_last_error(runtime);
  for (const svn_error_t *current = error; current != NULL; current = current->child) {
    if (runtime->last_error_entry_count == SUBVERSIONR_BRIDGE_ERROR_ENTRY_LIMIT) {
      runtime->last_error_truncated = 1;
      break;
    }
    subversionr_bridge_error_entry *entry =
      &runtime->last_error_entries[runtime->last_error_entry_count++];
    entry->code = (int)current->apr_err;
    const char *name = svn_error_symbolic_name(current->apr_err);
    entry->name = name != NULL ? name : "SVN_ERR_UNKNOWN";
  }
}

static void bridge_prepare_call(subversionr_bridge_runtime *runtime) {
  if (runtime == NULL) {
    return;
  }
  bridge_clear_last_error(runtime);
  apr_pool_clear(runtime->result_pool);
}

typedef struct bridge_info_receiver_baton {
  const svn_client_info2_t *info;
  apr_pool_t *result_pool;
} bridge_info_receiver_baton;

typedef struct bridge_cancel_baton bridge_cancel_baton;

typedef struct bridge_status_receiver_baton {
  apr_array_header_t *entries;
  apr_pool_t *result_pool;
  svn_client_ctx_t *ctx;
  bridge_cancel_baton *cancel_baton;
  int check_working_copy;
} bridge_status_receiver_baton;

typedef struct bridge_log_receiver_baton {
  apr_array_header_t *entries;
  apr_pool_t *result_pool;
} bridge_log_receiver_baton;

typedef struct bridge_blame_receiver_baton {
  apr_array_header_t *lines;
  apr_pool_t *result_pool;
  long long line_start;
  int line_limit;
  int has_more;
} bridge_blame_receiver_baton;

typedef struct bridge_operation_notify_baton {
  apr_array_header_t *touched_paths;
  apr_array_header_t *skipped_paths;
  apr_pool_t *result_pool;
} bridge_operation_notify_baton;

typedef struct bridge_property_entry_sort_key {
  const char *name;
  const svn_string_t *value;
} bridge_property_entry_sort_key;

typedef struct bridge_property_list_baton {
  apr_array_header_t *sort_keys;
  apr_pool_t *result_pool;
  int rejected_binary_property;
} bridge_property_list_baton;

typedef struct bridge_commit_log_baton {
  const char *message;
} bridge_commit_log_baton;

typedef struct bridge_commit_callback_baton {
  svn_revnum_t revision;
} bridge_commit_callback_baton;

typedef struct bridge_auth_prompt_baton {
  subversionr_bridge_auth_callbacks callbacks;
  apr_pool_t *pool;
  const char *working_copy_root;
  const char *default_username;
  int default_username_required;
  int callback_failed;
} bridge_auth_prompt_baton;

struct bridge_cancel_baton {
  const subversionr_bridge_cancel_callbacks *callbacks;
  int callback_failed;
};

typedef struct bridge_secret_cleanup_baton {
  char *data;
  size_t byte_count;
} bridge_secret_cleanup_baton;

static svn_error_t *bridge_cancel_check(void *baton);

static const char *bridge_status_kind_to_word(enum svn_wc_status_kind status) {
  switch (status) {
    case svn_wc_status_none:
      return "none";
    case svn_wc_status_unversioned:
      return "unversioned";
    case svn_wc_status_normal:
      return "normal";
    case svn_wc_status_added:
      return "added";
    case svn_wc_status_missing:
      return "missing";
    case svn_wc_status_deleted:
      return "deleted";
    case svn_wc_status_replaced:
      return "replaced";
    case svn_wc_status_modified:
      return "modified";
    case svn_wc_status_merged:
      return "merged";
    case svn_wc_status_conflicted:
      return "conflicted";
    case svn_wc_status_ignored:
      return "ignored";
    case svn_wc_status_obstructed:
      return "obstructed";
    case svn_wc_status_external:
      return "external";
    case svn_wc_status_incomplete:
      return "incomplete";
    default:
      return "unknown";
  }
}

static long long bridge_revision_to_i64(svn_revnum_t revision) {
  return SVN_IS_VALID_REVNUM(revision) ? (long long)revision : -1;
}

static const char *bridge_tristate_to_word(svn_tristate_t value) {
  switch (value) {
    case svn_tristate_true:
      return "true";
    case svn_tristate_false:
      return "false";
    case svn_tristate_unknown:
    default:
      return "unknown";
  }
}

static int bridge_log_changed_path_compare(const void *left, const void *right) {
  const subversionr_bridge_log_changed_path *left_path =
    (const subversionr_bridge_log_changed_path *)left;
  const subversionr_bridge_log_changed_path *right_path =
    (const subversionr_bridge_log_changed_path *)right;
  const char *left_value = left_path->path != NULL ? left_path->path : "";
  const char *right_value = right_path->path != NULL ? right_path->path : "";
  return strcmp(left_value, right_value);
}

static int bridge_property_entry_compare(const void *left, const void *right) {
  const bridge_property_entry_sort_key *left_entry =
    (const bridge_property_entry_sort_key *)left;
  const bridge_property_entry_sort_key *right_entry =
    (const bridge_property_entry_sort_key *)right;
  return strcmp(left_entry->name, right_entry->name);
}

static svn_error_t *bridge_property_list_receiver(
  void *baton,
  const char *path,
  apr_hash_t *prop_hash,
  apr_array_header_t *inherited_props,
  apr_pool_t *scratch_pool
) {
  (void)path;
  (void)inherited_props;
  bridge_property_list_baton *receiver_baton = (bridge_property_list_baton *)baton;
  if (receiver_baton == NULL || prop_hash == NULL) {
    return SVN_NO_ERROR;
  }

  for (apr_hash_index_t *hi = apr_hash_first(scratch_pool, prop_hash);
       hi != NULL;
       hi = apr_hash_next(hi)) {
    const void *key = NULL;
    void *value = NULL;
    apr_hash_this(hi, &key, NULL, &value);
    if (key == NULL || value == NULL) {
      continue;
    }
    const svn_string_t *property_value = (const svn_string_t *)value;
    if (memchr(property_value->data, '\0', property_value->len) != NULL) {
      receiver_baton->rejected_binary_property = 1;
      return svn_error_create(SVN_ERR_MALFORMED_FILE, NULL, "SVN property value contains NUL byte");
    }
    bridge_property_entry_sort_key sort_key = { 0 };
    sort_key.name = apr_pstrdup(receiver_baton->result_pool, (const char *)key);
    sort_key.value = svn_string_dup(property_value, receiver_baton->result_pool);
    APR_ARRAY_PUSH(receiver_baton->sort_keys, bridge_property_entry_sort_key) = sort_key;
  }
  return SVN_NO_ERROR;
}

#ifdef _WIN32
static const wchar_t *BRIDGE_PRELOAD_MODULES[BRIDGE_PRELOAD_MODULE_COUNT] = {
  L"libsvn_ra-1.dll",
  L"libsvn_fs_fs-1.dll",
  L"libsvn_fs_x-1.dll"
};
static HMODULE bridge_process_modules[BRIDGE_PRELOAD_MODULE_COUNT] = { 0 };

static int bridge_get_module_directory(wchar_t *directory, size_t directory_capacity) {
  if (directory == NULL || directory_capacity == 0) {
    return 0;
  }

  HMODULE bridge_module = NULL;
  if (!GetModuleHandleExW(
      GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      (LPCWSTR)&bridge_get_module_directory,
      &bridge_module
  )) {
    return 0;
  }

  const DWORD module_path_length =
    GetModuleFileNameW(bridge_module, directory, (DWORD)directory_capacity);
  if (module_path_length == 0 || module_path_length >= directory_capacity) {
    return 0;
  }

  wchar_t *last_separator = wcsrchr(directory, L'\\');
  wchar_t *last_forward_separator = wcsrchr(directory, L'/');
  if (last_separator == NULL || (last_forward_separator != NULL && last_forward_separator > last_separator)) {
    last_separator = last_forward_separator;
  }
  if (last_separator == NULL) {
    return 0;
  }

  last_separator[1] = L'\0';
  return 1;
}

static HMODULE bridge_load_module_from_directory(const wchar_t *directory, const wchar_t *module_name) {
  wchar_t module_path[MAX_PATH];
  const size_t module_path_capacity = sizeof(module_path) / sizeof(module_path[0]);

  if (wcscpy_s(module_path, module_path_capacity, directory) != 0) {
    return NULL;
  }
  if (wcscat_s(module_path, module_path_capacity, module_name) != 0) {
    return NULL;
  }

  return LoadLibraryExW(
    module_path,
    NULL,
    LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
  );
}

static void bridge_release_runtime_modules(HMODULE *modules, size_t module_count) {
  while (module_count > 0) {
    module_count--;
    if (modules[module_count] != NULL) {
      FreeLibrary(modules[module_count]);
      modules[module_count] = NULL;
    }
  }
}

static int bridge_preload_runtime_modules(HMODULE *modules, size_t module_count) {
  if (modules == NULL || module_count < BRIDGE_PRELOAD_MODULE_COUNT) {
    return 0;
  }

  wchar_t module_directory[MAX_PATH];
  const size_t module_directory_capacity = sizeof(module_directory) / sizeof(module_directory[0]);
  if (!bridge_get_module_directory(module_directory, module_directory_capacity)) {
    return 0;
  }

  for (size_t index = 0; index < BRIDGE_PRELOAD_MODULE_COUNT; index++) {
    modules[index] = bridge_load_module_from_directory(module_directory, BRIDGE_PRELOAD_MODULES[index]);
    if (modules[index] == NULL) {
      bridge_release_runtime_modules(modules, index);
      return 0;
    }
  }

  return 1;
}
#endif
static int bridge_process_initialized = 0;

static int bridge_initialize_process(void) {
  if (bridge_process_initialized) {
    return 0;
  }

  /* APR and libsvn module loaders are process-lifetime resources. */
#ifdef _WIN32
  if (!bridge_preload_runtime_modules(bridge_process_modules, BRIDGE_PRELOAD_MODULE_COUNT)) {
    return 7;
  }
#endif

  if (apr_initialize() != APR_SUCCESS) {
#ifdef _WIN32
    bridge_release_runtime_modules(bridge_process_modules, BRIDGE_PRELOAD_MODULE_COUNT);
#endif
    return 2;
  }

  bridge_process_initialized = 1;
  return 0;
}

static int bridge_depth_from_word(const char *depth, svn_depth_t *result) {
  if (depth == NULL || result == NULL) {
    return 0;
  }
  if (strcmp(depth, "empty") == 0) {
    *result = svn_depth_empty;
    return 1;
  }
  if (strcmp(depth, "files") == 0) {
    *result = svn_depth_files;
    return 1;
  }
  if (strcmp(depth, "immediates") == 0) {
    *result = svn_depth_immediates;
    return 1;
  }
  if (strcmp(depth, "infinity") == 0) {
    *result = svn_depth_infinity;
    return 1;
  }
  return 0;
}

static int bridge_update_depth_from_word(const char *depth, svn_depth_t *result) {
  if (depth == NULL || result == NULL) {
    return 0;
  }
  if (strcmp(depth, "workingCopy") == 0) {
    *result = svn_depth_unknown;
    return 1;
  }
  return bridge_depth_from_word(depth, result);
}

static int bridge_status_kind_is_actionable(enum svn_wc_status_kind kind) {
  return kind != svn_wc_status_none && kind != svn_wc_status_normal;
}

static int bridge_depth_is_sparse(svn_depth_t depth) {
  return depth == svn_depth_empty || depth == svn_depth_files || depth == svn_depth_immediates;
}

static int bridge_status_should_emit(const svn_client_status_t *status, int needs_lock) {
  if (status == NULL) {
    return 0;
  }

  return
    bridge_status_kind_is_actionable(status->node_status) ||
    bridge_status_kind_is_actionable(status->text_status) ||
    bridge_status_kind_is_actionable(status->prop_status) ||
    bridge_status_kind_is_actionable(status->repos_node_status) ||
    bridge_status_kind_is_actionable(status->repos_text_status) ||
    bridge_status_kind_is_actionable(status->repos_prop_status) ||
    status->conflicted ||
    status->switched ||
    status->lock != NULL ||
    status->repos_lock != NULL ||
    needs_lock ||
    bridge_depth_is_sparse(status->depth) ||
    status->copied ||
    status->moved_from_abspath != NULL ||
    status->file_external ||
    status->node_status == svn_wc_status_external;
}

static subversionr_bridge_lock_info *bridge_lock_info_dup(
  const svn_lock_t *lock,
  int is_remote,
  apr_pool_t *result_pool
) {
  if (lock == NULL) {
    return NULL;
  }

  subversionr_bridge_lock_info *info =
    apr_pcalloc(result_pool, sizeof(subversionr_bridge_lock_info));
  info->token = lock->token != NULL ? apr_pstrdup(result_pool, lock->token) : NULL;
  info->owner = lock->owner != NULL ? apr_pstrdup(result_pool, lock->owner) : NULL;
  info->comment = lock->comment != NULL ? apr_pstrdup(result_pool, lock->comment) : NULL;
  info->created_date = lock->creation_date != 0
    ? svn_time_to_cstring(lock->creation_date, result_pool)
    : NULL;
  info->expires_date = lock->expiration_date != 0
    ? svn_time_to_cstring(lock->expiration_date, result_pool)
    : NULL;
  info->is_remote = is_remote ? 1 : 0;
  return info;
}

static svn_error_t *bridge_status_has_needs_lock(
  svn_client_ctx_t *ctx,
  const char *entry_path,
  svn_node_kind_t kind,
  apr_pool_t *result_pool,
  apr_pool_t *scratch_pool,
  int *needs_lock
) {
  *needs_lock = 0;
  if (ctx == NULL || entry_path == NULL || kind != svn_node_file) {
    return SVN_NO_ERROR;
  }

  svn_opt_revision_t revision = { 0 };
  revision.kind = svn_opt_revision_working;
  apr_hash_t *props = NULL;
  apr_array_header_t *inherited_props = NULL;
  svn_revnum_t actual_revnum = SVN_INVALID_REVNUM;
  SVN_ERR(svn_client_propget5(
    &props,
    &inherited_props,
    SVN_PROP_NEEDS_LOCK,
    entry_path,
    &revision,
    &revision,
    &actual_revnum,
    svn_depth_empty,
    NULL,
    ctx,
    result_pool,
    scratch_pool
  ));
  *needs_lock = (props != NULL && apr_hash_count(props) > 0) ? 1 : 0;
  return SVN_NO_ERROR;
}

static int bridge_status_can_probe_needs_lock(
  const svn_client_status_t *status,
  svn_node_kind_t kind
) {
  if (status == NULL || kind != svn_node_file) {
    return 0;
  }
  if (
    status->node_status == svn_wc_status_unversioned ||
    status->node_status == svn_wc_status_ignored ||
    status->node_status == svn_wc_status_external ||
    status->node_status == svn_wc_status_deleted ||
    status->node_status == svn_wc_status_missing ||
    status->text_status == svn_wc_status_deleted ||
    status->text_status == svn_wc_status_missing
  ) {
    return 0;
  }
  return 1;
}

static int bridge_conflict_choice_from_word(const char *choice, svn_wc_conflict_choice_t *result) {
  if (choice == NULL || result == NULL) {
    return 0;
  }
  if (strcmp(choice, "working") == 0) {
    *result = svn_wc_conflict_choose_merged;
    return 1;
  }
  if (strcmp(choice, "base") == 0) {
    *result = svn_wc_conflict_choose_base;
    return 1;
  }
  if (strcmp(choice, "mineFull") == 0) {
    *result = svn_wc_conflict_choose_mine_full;
    return 1;
  }
  if (strcmp(choice, "theirsFull") == 0) {
    *result = svn_wc_conflict_choose_theirs_full;
    return 1;
  }
  if (strcmp(choice, "mineConflict") == 0) {
    *result = svn_wc_conflict_choose_mine_conflict;
    return 1;
  }
  if (strcmp(choice, "theirsConflict") == 0) {
    *result = svn_wc_conflict_choose_theirs_conflict;
    return 1;
  }
  return 0;
}

static svn_error_t *bridge_info_receiver(
  void *baton,
  const char *abspath_or_url,
  const svn_client_info2_t *info,
  apr_pool_t *scratch_pool
) {
  (void)abspath_or_url;

  bridge_info_receiver_baton *receiver_baton = (bridge_info_receiver_baton *)baton;
  receiver_baton->info = svn_client_info2_dup(info, receiver_baton->result_pool);
  return SVN_NO_ERROR;
}

static svn_error_t *bridge_status_receiver(
  void *baton,
  const char *path,
  const svn_client_status_t *status,
  apr_pool_t *scratch_pool
) {
  bridge_status_receiver_baton *receiver_baton = (bridge_status_receiver_baton *)baton;
  if (status == NULL) {
    return SVN_NO_ERROR;
  }
  const char *entry_path = path != NULL ? path : status->local_abspath;
  svn_node_kind_t kind = status->kind;
  if (kind == svn_node_unknown && entry_path != NULL) {
    SVN_ERR(svn_io_check_path(entry_path, &kind, scratch_pool));
  }
  int needs_lock = 0;
  if (receiver_baton->check_working_copy && bridge_status_can_probe_needs_lock(status, kind)) {
    SVN_ERR(bridge_status_has_needs_lock(
      receiver_baton->ctx,
      entry_path,
      kind,
      receiver_baton->result_pool,
      scratch_pool,
      &needs_lock
    ));
  }
  if (!bridge_status_should_emit(status, needs_lock)) {
    return SVN_NO_ERROR;
  }
  SVN_ERR(bridge_cancel_check(receiver_baton->cancel_baton));

  apr_pool_t *result_pool = receiver_baton->result_pool;
  subversionr_bridge_status_entry *entry =
    &APR_ARRAY_PUSH(receiver_baton->entries, subversionr_bridge_status_entry);

  entry->path = entry_path != NULL ? apr_pstrdup(result_pool, entry_path) : NULL;
  entry->kind = svn_node_kind_to_word(kind);
  entry->node_status = bridge_status_kind_to_word(status->node_status);
  entry->text_status = bridge_status_kind_to_word(status->text_status);
  entry->property_status = bridge_status_kind_to_word(status->prop_status);
  entry->repos_node_status = bridge_status_kind_to_word(status->repos_node_status);
  entry->repos_text_status = bridge_status_kind_to_word(status->repos_text_status);
  entry->repos_property_status = bridge_status_kind_to_word(status->repos_prop_status);
  entry->repos_kind = svn_node_kind_to_word(status->ood_kind);
  entry->repos_changed_revision = bridge_revision_to_i64(status->ood_changed_rev);
  entry->repos_changed_author = status->ood_changed_author != NULL
    ? apr_pstrdup(result_pool, status->ood_changed_author)
    : NULL;
  entry->repos_changed_date = status->ood_changed_date != 0
    ? svn_time_to_cstring(status->ood_changed_date, result_pool)
    : NULL;
  entry->revision = bridge_revision_to_i64(status->revision);
  entry->changed_revision = bridge_revision_to_i64(status->changed_rev);
  entry->changed_author = status->changed_author != NULL
    ? apr_pstrdup(result_pool, status->changed_author)
    : NULL;
  entry->changed_date = status->changed_date != 0
    ? svn_time_to_cstring(status->changed_date, result_pool)
    : NULL;
  entry->changelist = status->changelist != NULL
    ? apr_pstrdup(result_pool, status->changelist)
    : NULL;
  entry->lock = bridge_lock_info_dup(status->lock, 0, result_pool);
  entry->repos_lock = bridge_lock_info_dup(status->repos_lock, 1, result_pool);
  entry->needs_lock = needs_lock;
  entry->depth = svn_depth_to_word(status->depth);
  entry->conflicted = status->conflicted ? 1 : 0;
  entry->switched = status->switched ? 1 : 0;
  entry->external =
    (status->file_external || status->node_status == svn_wc_status_external) ? 1 : 0;
  entry->copied = status->copied ? 1 : 0;
  entry->copy_from_path = NULL;
  entry->copy_from_revision = -1;
  entry->moved_from_abspath = status->moved_from_abspath != NULL
    ? apr_pstrdup(result_pool, status->moved_from_abspath)
    : NULL;
  return SVN_NO_ERROR;
}

static svn_error_t *bridge_status_copy_from_info(
  svn_client_ctx_t *ctx,
  const subversionr_bridge_status_entry *entry,
  apr_pool_t *result_pool,
  apr_pool_t *scratch_pool,
  const char **copy_from_path,
  long long *copy_from_revision
) {
  *copy_from_path = NULL;
  *copy_from_revision = -1;
  if (entry == NULL || !entry->copied || entry->path == NULL) {
    return SVN_NO_ERROR;
  }

  svn_opt_revision_t peg_revision = { 0 };
  svn_opt_revision_t revision = { 0 };
  peg_revision.kind = svn_opt_revision_unspecified;
  revision.kind = svn_opt_revision_unspecified;
  bridge_info_receiver_baton receiver_baton = { 0 };
  receiver_baton.result_pool = scratch_pool;

  SVN_ERR(svn_client_info4(
    entry->path,
    &peg_revision,
    &revision,
    svn_depth_empty,
    FALSE,
    FALSE,
    FALSE,
    NULL,
    bridge_info_receiver,
    &receiver_baton,
    ctx,
    scratch_pool
  ));

  const svn_client_info2_t *svn_info = receiver_baton.info;
  const svn_wc_info_t *wc_info = svn_info != NULL ? svn_info->wc_info : NULL;
  if (wc_info == NULL || wc_info->copyfrom_url == NULL) {
    return SVN_NO_ERROR;
  }

  const char *source = wc_info->copyfrom_url;
  if (svn_info->repos_root_URL != NULL) {
    const char *relative_source =
      svn_uri_skip_ancestor(svn_info->repos_root_URL, wc_info->copyfrom_url, scratch_pool);
    if (relative_source != NULL) {
      source = relative_source[0] != '\0' ? relative_source : "/";
    }
  }
  *copy_from_path = apr_pstrdup(result_pool, source);
  *copy_from_revision = bridge_revision_to_i64(wc_info->copyfrom_rev);
  return SVN_NO_ERROR;
}

static svn_error_t *bridge_status_populate_copy_metadata(
  svn_client_ctx_t *ctx,
  apr_array_header_t *entries,
  apr_pool_t *result_pool,
  apr_pool_t *scratch_pool
) {
  if (entries == NULL) {
    return SVN_NO_ERROR;
  }

  for (int i = 0; i < entries->nelts; ++i) {
    subversionr_bridge_status_entry *entry =
      &APR_ARRAY_IDX(entries, i, subversionr_bridge_status_entry);
    const char *copy_from_path = NULL;
    long long copy_from_revision = -1;
    SVN_ERR(bridge_status_copy_from_info(
      ctx,
      entry,
      result_pool,
      scratch_pool,
      &copy_from_path,
      &copy_from_revision
    ));
    entry->copy_from_path = copy_from_path;
    entry->copy_from_revision = copy_from_revision;
  }

  return SVN_NO_ERROR;
}

static svn_error_t *bridge_log_receiver(
  void *baton,
  svn_log_entry_t *log_entry,
  apr_pool_t *scratch_pool
) {
  (void)scratch_pool;

  if (log_entry == NULL || !SVN_IS_VALID_REVNUM(log_entry->revision)) {
    return SVN_NO_ERROR;
  }

  bridge_log_receiver_baton *receiver_baton = (bridge_log_receiver_baton *)baton;
  apr_pool_t *result_pool = receiver_baton->result_pool;
  subversionr_bridge_log_entry *entry =
    &APR_ARRAY_PUSH(receiver_baton->entries, subversionr_bridge_log_entry);
  const svn_string_t *author = log_entry->revprops != NULL
    ? (const svn_string_t *)svn_hash_gets(log_entry->revprops, SVN_PROP_REVISION_AUTHOR)
    : NULL;
  const svn_string_t *date = log_entry->revprops != NULL
    ? (const svn_string_t *)svn_hash_gets(log_entry->revprops, SVN_PROP_REVISION_DATE)
    : NULL;
  const svn_string_t *message = log_entry->revprops != NULL
    ? (const svn_string_t *)svn_hash_gets(log_entry->revprops, SVN_PROP_REVISION_LOG)
    : NULL;

  entry->revision = bridge_revision_to_i64(log_entry->revision);
  entry->author = author != NULL && author->len > 0
    ? apr_pstrmemdup(result_pool, author->data, author->len)
    : NULL;
  entry->date = date != NULL ? apr_pstrmemdup(result_pool, date->data, date->len) : NULL;
  entry->message =
    message != NULL ? apr_pstrmemdup(result_pool, message->data, message->len) : NULL;
  entry->changed_paths = NULL;
  entry->changed_path_count = 0;
  entry->has_children = log_entry->has_children ? 1 : 0;
  entry->non_inheritable = log_entry->non_inheritable ? 1 : 0;
  entry->subtractive_merge = log_entry->subtractive_merge ? 1 : 0;

  if (log_entry->changed_paths2 != NULL && apr_hash_count(log_entry->changed_paths2) > 0) {
    apr_array_header_t *changed_paths = apr_array_make(
      result_pool,
      apr_hash_count(log_entry->changed_paths2),
      sizeof(subversionr_bridge_log_changed_path)
    );
    for (apr_hash_index_t *hi = apr_hash_first(result_pool, log_entry->changed_paths2);
         hi != NULL;
         hi = apr_hash_next(hi)) {
      const void *key = NULL;
      void *value = NULL;
      apr_hash_this(hi, &key, NULL, &value);
      const char *changed_path = (const char *)key;
      const svn_log_changed_path2_t *svn_changed_path =
        (const svn_log_changed_path2_t *)value;
      if (changed_path == NULL || svn_changed_path == NULL) {
        continue;
      }

      subversionr_bridge_log_changed_path *bridge_changed_path =
        &APR_ARRAY_PUSH(changed_paths, subversionr_bridge_log_changed_path);
      bridge_changed_path->path = apr_pstrdup(result_pool, changed_path);
      bridge_changed_path->action = apr_pstrmemdup(result_pool, &svn_changed_path->action, 1);
      bridge_changed_path->copy_from_path = svn_changed_path->copyfrom_path != NULL
        ? apr_pstrdup(result_pool, svn_changed_path->copyfrom_path)
        : NULL;
      bridge_changed_path->copy_from_revision =
        bridge_revision_to_i64(svn_changed_path->copyfrom_rev);
      bridge_changed_path->node_kind = svn_node_kind_to_word(svn_changed_path->node_kind);
      bridge_changed_path->text_modified =
        bridge_tristate_to_word(svn_changed_path->text_modified);
      bridge_changed_path->properties_modified =
        bridge_tristate_to_word(svn_changed_path->props_modified);
    }

    if (changed_paths->nelts > 1) {
      qsort(
        changed_paths->elts,
        (size_t)changed_paths->nelts,
        sizeof(subversionr_bridge_log_changed_path),
        bridge_log_changed_path_compare
      );
    }
    entry->changed_paths = (const subversionr_bridge_log_changed_path *)changed_paths->elts;
    entry->changed_path_count = (size_t)changed_paths->nelts;
  }

  return SVN_NO_ERROR;
}

static const char *bridge_revprop_to_cstr(
  apr_hash_t *rev_props,
  const char *name,
  apr_pool_t *result_pool
) {
  if (rev_props == NULL) {
    return NULL;
  }

  const svn_string_t *value = (const svn_string_t *)svn_hash_gets(rev_props, name);
  return value != NULL ? apr_pstrmemdup(result_pool, value->data, value->len) : NULL;
}

static svn_error_t *bridge_blame_receiver(
  void *baton,
  apr_int64_t line_no,
  svn_revnum_t revision,
  apr_hash_t *rev_props,
  svn_revnum_t merged_revision,
  apr_hash_t *merged_rev_props,
  const char *merged_path,
  const svn_string_t *line,
  svn_boolean_t local_change,
  apr_pool_t *pool
) {
  (void)pool;

  bridge_blame_receiver_baton *receiver_baton = (bridge_blame_receiver_baton *)baton;
  long long one_based_line = (long long)line_no + 1;
  if (one_based_line < receiver_baton->line_start) {
    return SVN_NO_ERROR;
  }

  if (receiver_baton->lines->nelts >= receiver_baton->line_limit) {
    receiver_baton->has_more = 1;
    return svn_error_create(SVN_ERR_CEASE_INVOCATION, NULL, NULL);
  }

  apr_pool_t *result_pool = receiver_baton->result_pool;
  subversionr_bridge_blame_line *entry =
    &APR_ARRAY_PUSH(receiver_baton->lines, subversionr_bridge_blame_line);
  entry->line_number = one_based_line;
  entry->revision = bridge_revision_to_i64(revision);
  entry->author = bridge_revprop_to_cstr(rev_props, SVN_PROP_REVISION_AUTHOR, result_pool);
  entry->date = bridge_revprop_to_cstr(rev_props, SVN_PROP_REVISION_DATE, result_pool);
  entry->merged_revision = bridge_revision_to_i64(merged_revision);
  entry->merged_author =
    bridge_revprop_to_cstr(merged_rev_props, SVN_PROP_REVISION_AUTHOR, result_pool);
  entry->merged_date =
    bridge_revprop_to_cstr(merged_rev_props, SVN_PROP_REVISION_DATE, result_pool);
  entry->merged_path = merged_path != NULL ? apr_pstrdup(result_pool, merged_path) : NULL;
  entry->line_data =
    (line != NULL && line->len > 0) ? apr_pmemdup(result_pool, line->data, line->len) : NULL;
  entry->line_byte_count = line != NULL ? (size_t)line->len : 0;
  entry->local_change = local_change ? 1 : 0;

  return SVN_NO_ERROR;
}

static int bridge_commit_target_is_versioned_file_or_dir(
  subversionr_bridge_runtime *runtime,
  const char *local_abspath,
  apr_pool_t *scratch_pool
) {
  svn_opt_revision_t peg_revision;
  svn_opt_revision_t revision;
  peg_revision.kind = svn_opt_revision_unspecified;
  revision.kind = svn_opt_revision_unspecified;
  bridge_info_receiver_baton receiver_baton = { 0 };
  receiver_baton.result_pool = scratch_pool;

  svn_error_t *info_err = svn_client_info4(
    local_abspath,
    &peg_revision,
    &revision,
    svn_depth_empty,
    FALSE,
    FALSE,
    FALSE,
    NULL,
    bridge_info_receiver,
    &receiver_baton,
    runtime->ctx,
    scratch_pool
  );
  if (info_err != NULL) {
    bridge_capture_error(runtime, info_err);
    svn_error_clear(info_err);
    return -1;
  }
  if (
    receiver_baton.info == NULL ||
    (receiver_baton.info->kind != svn_node_file && receiver_baton.info->kind != svn_node_dir)
  ) {
    return 0;
  }
  return 1;
}

static void bridge_operation_notify(
  void *baton,
  const svn_wc_notify_t *notify,
  apr_pool_t *scratch_pool
) {
  (void)scratch_pool;
  if (baton == NULL || notify == NULL || notify->path == NULL) {
    return;
  }

  bridge_operation_notify_baton *notify_baton = (bridge_operation_notify_baton *)baton;
  apr_array_header_t *target = NULL;
  if (
    notify->action == svn_wc_notify_skip ||
    notify->action == svn_wc_notify_update_skip_obstruction ||
    notify->action == svn_wc_notify_update_skip_working_only ||
    notify->action == svn_wc_notify_update_skip_access_denied ||
    notify->action == svn_wc_notify_failed_lock ||
    notify->action == svn_wc_notify_failed_unlock
  ) {
    target = notify_baton->skipped_paths;
  } else if (
    notify->action == svn_wc_notify_revert ||
    notify->action == svn_wc_notify_add ||
    notify->action == svn_wc_notify_delete ||
    notify->action == svn_wc_notify_resolved ||
    notify->action == svn_wc_notify_resolved_text ||
    notify->action == svn_wc_notify_resolved_prop ||
    notify->action == svn_wc_notify_resolved_tree ||
    notify->action == svn_wc_notify_update_delete ||
    notify->action == svn_wc_notify_update_add ||
    notify->action == svn_wc_notify_update_update ||
    notify->action == svn_wc_notify_update_replace ||
    notify->action == svn_wc_notify_commit_modified ||
    notify->action == svn_wc_notify_commit_added ||
    notify->action == svn_wc_notify_commit_deleted ||
    notify->action == svn_wc_notify_commit_replaced ||
    notify->action == svn_wc_notify_commit_copied ||
    notify->action == svn_wc_notify_commit_copied_replaced ||
    notify->action == svn_wc_notify_changelist_set ||
    notify->action == svn_wc_notify_changelist_clear ||
    notify->action == svn_wc_notify_locked ||
    notify->action == svn_wc_notify_unlocked
  ) {
    target = notify_baton->touched_paths;
  }
  if (target == NULL) {
    return;
  }

  APR_ARRAY_PUSH(target, const char *) = apr_pstrdup(notify_baton->result_pool, notify->path);
}

static int bridge_valid_commit_message(const char *message) {
  if (message == NULL || message[0] == '\0') {
    return 0;
  }

  int has_non_whitespace = 0;
  for (const char *cursor = message; *cursor != '\0'; cursor++) {
    if (*cursor == '\r') {
      return 0;
    }
    if (*cursor != ' ' && *cursor != '\t' && *cursor != '\n') {
      has_non_whitespace = 1;
    }
  }
  return has_non_whitespace;
}

static svn_error_t *bridge_commit_log_message(
  const char **log_msg,
  const char **tmp_file,
  const apr_array_header_t *commit_items,
  void *baton,
  apr_pool_t *pool
) {
  (void)commit_items;

  if (log_msg == NULL || tmp_file == NULL || baton == NULL) {
    return SVN_NO_ERROR;
  }

  bridge_commit_log_baton *log_baton = (bridge_commit_log_baton *)baton;
  *log_msg = apr_pstrdup(pool, log_baton->message);
  *tmp_file = NULL;
  return SVN_NO_ERROR;
}

static svn_error_t *bridge_commit_callback(
  const svn_commit_info_t *commit_info,
  void *baton,
  apr_pool_t *pool
) {
  (void)pool;

  if (commit_info == NULL || baton == NULL) {
    return SVN_NO_ERROR;
  }

  bridge_commit_callback_baton *callback_baton = (bridge_commit_callback_baton *)baton;
  callback_baton->revision = commit_info->revision;
  return SVN_NO_ERROR;
}

static int bridge_auth_callbacks_valid(const subversionr_bridge_auth_callbacks *callbacks) {
  return callbacks != NULL &&
    callbacks->abi_version == SUBVERSIONR_BRIDGE_AUTH_ABI_VERSION &&
    callbacks->baton != NULL &&
    callbacks->credential_callback != NULL &&
    callbacks->credential_response_dispose != NULL &&
    callbacks->certificate_callback != NULL;
}

static int bridge_cancel_callbacks_valid(const subversionr_bridge_cancel_callbacks *callbacks) {
  return callbacks != NULL &&
    callbacks->abi_version == SUBVERSIONR_BRIDGE_CANCEL_ABI_VERSION &&
    callbacks->cancel_callback != NULL;
}

static svn_error_t *bridge_auth_callback_error(void) {
  return svn_error_create(SVN_ERR_AUTHN_FAILED, NULL, "SubversionR auth callback failed");
}

static svn_error_t *bridge_auth_default_username_error(void) {
  return svn_error_create(
    SVN_ERR_AUTHN_FAILED,
    NULL,
    "SubversionR could not resolve the current SVN username"
  );
}

static apr_status_t bridge_zero_secret_cleanup(void *baton) {
  bridge_secret_cleanup_baton *cleanup = (bridge_secret_cleanup_baton *)baton;
  if (cleanup != NULL && cleanup->data != NULL) {
    volatile unsigned char *bytes = (volatile unsigned char *)cleanup->data;
    for (size_t index = 0; index < cleanup->byte_count; ++index) {
      bytes[index] = 0;
    }
  }
  return APR_SUCCESS;
}

static const char *bridge_copy_secret(apr_pool_t *pool, const char *secret) {
  char *copy = apr_pstrdup(pool, secret);
  bridge_secret_cleanup_baton *cleanup = apr_pcalloc(pool, sizeof(*cleanup));
  cleanup->data = copy;
  cleanup->byte_count = strlen(copy);
  apr_pool_cleanup_register(
    pool,
    cleanup,
    bridge_zero_secret_cleanup,
    apr_pool_cleanup_null
  );
  return copy;
}

static void bridge_dispose_credential_response(
  const subversionr_bridge_auth_callbacks *callbacks,
  subversionr_bridge_credential_response *response
) {
  if (
    callbacks != NULL &&
    callbacks->credential_response_dispose != NULL &&
    response != NULL
  ) {
    callbacks->credential_response_dispose(callbacks->baton, response);
  }
}

static svn_error_t *bridge_auth_simple_prompt(
  svn_auth_cred_simple_t **cred,
  void *baton,
  const char *realm,
  const char *username,
  svn_boolean_t may_save,
  apr_pool_t *pool
) {
  if (cred == NULL || baton == NULL) {
    return bridge_auth_callback_error();
  }
  *cred = NULL;

  bridge_auth_prompt_baton *prompt_baton = (bridge_auth_prompt_baton *)baton;
  subversionr_bridge_credential_request request = {
    realm,
    username,
    may_save ? 1 : 0,
    prompt_baton->working_copy_root
  };
  subversionr_bridge_credential_response response = { 0 };
  int status = prompt_baton->callbacks.credential_callback(
    prompt_baton->callbacks.baton,
    &request,
    &response
  );
  if (
    status != BRIDGE_AUTH_CALLBACK_OK ||
    response.username == NULL ||
    response.secret == NULL
  ) {
    prompt_baton->callback_failed = 1;
    bridge_dispose_credential_response(&prompt_baton->callbacks, &response);
    return bridge_auth_callback_error();
  }

  svn_auth_cred_simple_t *created = apr_pcalloc(pool, sizeof(*created));
  created->username = apr_pstrdup(pool, response.username);
  created->password = bridge_copy_secret(pool, response.secret);
  created->may_save = (may_save && response.may_save) ? TRUE : FALSE;
  *cred = created;
  prompt_baton->default_username = apr_pstrdup(prompt_baton->pool, response.username);
  bridge_dispose_credential_response(&prompt_baton->callbacks, &response);
  return SVN_NO_ERROR;
}

static svn_error_t *bridge_auth_username_prompt(
  svn_auth_cred_username_t **cred,
  void *baton,
  const char *realm,
  svn_boolean_t may_save,
  apr_pool_t *pool
) {
  (void)realm;
  (void)may_save;

  if (cred == NULL || baton == NULL) {
    return bridge_auth_callback_error();
  }
  *cred = NULL;

  bridge_auth_prompt_baton *prompt_baton = (bridge_auth_prompt_baton *)baton;
  if (
    prompt_baton->default_username == NULL ||
    prompt_baton->default_username[0] == '\0'
  ) {
    return bridge_auth_default_username_error();
  }

  svn_auth_cred_username_t *created = apr_pcalloc(pool, sizeof(*created));
  created->username = apr_pstrdup(pool, prompt_baton->default_username);
  created->may_save = FALSE;
  *cred = created;
  return SVN_NO_ERROR;
}

static svn_error_t *bridge_auth_ssl_server_trust_prompt(
  svn_auth_cred_ssl_server_trust_t **cred,
  void *baton,
  const char *realm,
  apr_uint32_t failures,
  const svn_auth_ssl_server_cert_info_t *cert_info,
  svn_boolean_t may_save,
  apr_pool_t *pool
) {
  if (cred == NULL || baton == NULL) {
    return bridge_auth_callback_error();
  }
  *cred = NULL;

  bridge_auth_prompt_baton *prompt_baton = (bridge_auth_prompt_baton *)baton;
  subversionr_bridge_certificate_request request = {
    realm,
    cert_info != NULL ? cert_info->hostname : NULL,
    cert_info != NULL ? cert_info->ascii_cert : NULL,
    cert_info != NULL ? cert_info->valid_from : NULL,
    cert_info != NULL ? cert_info->valid_until : NULL,
    cert_info != NULL ? cert_info->issuer_dname : NULL,
    NULL,
    failures,
    may_save ? 1 : 0,
    prompt_baton->working_copy_root
  };
  subversionr_bridge_certificate_response response = { 0 };
  int status = prompt_baton->callbacks.certificate_callback(
    prompt_baton->callbacks.baton,
    &request,
    &response
  );
  if (
    status != BRIDGE_AUTH_CALLBACK_OK ||
    response.accepted_failures != failures
  ) {
    prompt_baton->callback_failed = 1;
    return bridge_auth_callback_error();
  }

  svn_auth_cred_ssl_server_trust_t *created = apr_pcalloc(pool, sizeof(*created));
  created->accepted_failures = response.accepted_failures;
  created->may_save = (may_save && response.may_save) ? TRUE : FALSE;
  *cred = created;
  return SVN_NO_ERROR;
}

static svn_error_t *bridge_create_auth_baton(
  svn_auth_baton_t **auth_baton,
  bridge_auth_prompt_baton *prompt_baton,
  int require_default_username,
  apr_pool_t *pool
) {
  if (prompt_baton == NULL) {
    return bridge_auth_callback_error();
  }

  prompt_baton->default_username_required = require_default_username;
  prompt_baton->pool = pool;
  const char *default_username = svn_user_get_name(pool);
  prompt_baton->default_username =
    (default_username != NULL && default_username[0] != '\0') ? default_username : NULL;
  if (require_default_username && prompt_baton->default_username == NULL) {
    return bridge_auth_default_username_error();
  }

  svn_auth_provider_object_t *provider = NULL;
  apr_array_header_t *providers = apr_array_make(
    pool,
    3,
    sizeof(svn_auth_provider_object_t *)
  );

  svn_auth_get_simple_prompt_provider(
    &provider,
    bridge_auth_simple_prompt,
    prompt_baton,
    2,
    pool
  );
  APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;

  svn_auth_get_username_prompt_provider(
    &provider,
    bridge_auth_username_prompt,
    prompt_baton,
    2,
    pool
  );
  APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;

  svn_auth_get_ssl_server_trust_prompt_provider(
    &provider,
    bridge_auth_ssl_server_trust_prompt,
    prompt_baton,
    pool
  );
  APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;

  svn_auth_open(auth_baton, providers, pool);
  return SVN_NO_ERROR;
}

int subversionr_bridge_runtime_create(subversionr_bridge_runtime **runtime) {
  if (runtime == NULL) {
    return 1;
  }

  int process_status = bridge_initialize_process();
  if (process_status != 0) {
    return process_status;
  }

  apr_pool_t *pool = NULL;
  if (apr_pool_create(&pool, NULL) != APR_SUCCESS) {
    return 3;
  }

  apr_hash_t *config = NULL;
  svn_error_t *err = svn_config_get_config(&config, NULL, pool);
  if (err != NULL) {
    svn_error_clear(err);
    apr_pool_destroy(pool);
    return 6;
  }

  svn_client_ctx_t *ctx = NULL;
  err = svn_client_create_context2(&ctx, config, pool);
  if (err != NULL) {
    svn_error_clear(err);
    apr_pool_destroy(pool);
    return 4;
  }

  apr_pool_t *result_pool = NULL;
  if (apr_pool_create(&result_pool, pool) != APR_SUCCESS) {
    apr_pool_destroy(pool);
    return 5;
  }

  subversionr_bridge_runtime *created = apr_pcalloc(pool, sizeof(subversionr_bridge_runtime));
  created->pool = pool;
  created->result_pool = result_pool;
  created->ctx = ctx;
  *runtime = created;
  return 0;
}

void subversionr_bridge_runtime_destroy(subversionr_bridge_runtime *runtime) {
  if (runtime == NULL) {
    return;
  }

  apr_pool_t *pool = runtime->pool;
  apr_pool_destroy(pool);
}

int subversionr_bridge_last_error_diagnostics(
  subversionr_bridge_runtime *runtime,
  subversionr_bridge_error_diagnostics *diagnostics
) {
  if (runtime == NULL || diagnostics == NULL) {
    return 1;
  }
  diagnostics->entries = runtime->last_error_entries;
  diagnostics->entry_count = runtime->last_error_entry_count;
  diagnostics->truncated = runtime->last_error_truncated;
  return 0;
}

subversionr_bridge_version_info subversionr_bridge_version(void) {
  const svn_version_t *version = svn_subr_version();
  subversionr_bridge_version_info result = {
    version->major,
    version->minor,
    version->patch,
    SVN_VERSION
  };
  return result;
}

static int bridge_open_working_copy_impl(
  subversionr_bridge_runtime *runtime,
  const char *path,
  subversionr_bridge_wc_info *info
) {
  bridge_info_receiver_baton receiver_baton = { 0 };
  receiver_baton.result_pool = runtime->result_pool;
  const char *local_abspath = NULL;
  svn_error_t *err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  err = svn_client_info4(
    local_abspath,
    NULL,
    NULL,
    svn_depth_empty,
    FALSE,
    FALSE,
    FALSE,
    NULL,
    bridge_info_receiver,
    &receiver_baton,
    runtime->ctx,
    runtime->result_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  const svn_client_info2_t *svn_info = receiver_baton.info;
  if (svn_info == NULL || svn_info->repos_UUID == NULL || svn_info->repos_root_URL == NULL) {
    return 3;
  }

  int wc_format = 0;
  if (svn_info->wc_info != NULL && svn_info->wc_info->wcroot_abspath != NULL) {
    err = svn_wc_check_wc2(&wc_format, runtime->ctx->wc_ctx, svn_info->wc_info->wcroot_abspath, runtime->result_pool);
    if (err != NULL) {
      bridge_capture_error(runtime, err);
      svn_error_clear(err);
      return 4;
    }
  }

  info->repository_uuid = svn_info->repos_UUID;
  info->repository_root_url = svn_info->repos_root_URL;
  info->working_copy_root = svn_info->wc_info != NULL ? svn_info->wc_info->wcroot_abspath : NULL;
  info->format = wc_format;
  return 0;
}

int subversionr_bridge_open_working_copy(
  subversionr_bridge_runtime *runtime,
  const char *path,
  subversionr_bridge_wc_info *info
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || path == NULL || info == NULL) {
    return 1;
  }

  return bridge_open_working_copy_impl(runtime, path, info);
}

int subversionr_bridge_open_working_copy_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const subversionr_bridge_auth_callbacks *callbacks,
  subversionr_bridge_wc_info *info
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    path == NULL ||
    info == NULL ||
    !bridge_auth_callbacks_valid(callbacks)
  ) {
    return 1;
  }


  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_open_working_copy_impl(runtime, path, info);
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_probe_remote_url_impl(
  subversionr_bridge_runtime *runtime,
  const char *url
) {
  if (runtime == NULL || url == NULL || !svn_path_is_url(url)) {
    return 1;
  }

  bridge_info_receiver_baton receiver_baton = { 0 };
  receiver_baton.result_pool = runtime->result_pool;
  svn_opt_revision_t peg_revision = { 0 };
  svn_opt_revision_t operative_revision = { 0 };
  peg_revision.kind = svn_opt_revision_head;
  operative_revision.kind = svn_opt_revision_head;

  svn_error_t *err = svn_client_info4(
    url,
    &peg_revision,
    &operative_revision,
    svn_depth_empty,
    FALSE,
    FALSE,
    FALSE,
    NULL,
    bridge_info_receiver,
    &receiver_baton,
    runtime->ctx,
    runtime->result_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }
  if (receiver_baton.info == NULL) {
    return 3;
  }
  return 0;
}

int subversionr_bridge_probe_remote_url_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *url,
  const subversionr_bridge_auth_callbacks *callbacks
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    url == NULL ||
    !bridge_auth_callbacks_valid(callbacks)
  ) {
    return 1;
  }


  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = NULL;
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_probe_remote_url_impl(runtime, url);
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static svn_error_t *bridge_cancel_check(void *baton) {
  if (baton == NULL) {
    return svn_error_create(
      SVN_ERR_CANCELLED,
      NULL,
      "SubversionR cancel baton is missing"
    );
  }

  bridge_cancel_baton *cancel_baton = (bridge_cancel_baton *)baton;
  const subversionr_bridge_cancel_callbacks *callbacks = cancel_baton->callbacks;
  if (
    callbacks == NULL ||
    callbacks->abi_version != SUBVERSIONR_BRIDGE_CANCEL_ABI_VERSION ||
    callbacks->cancel_callback == NULL
  ) {
    cancel_baton->callback_failed = 1;
    return svn_error_create(
      SVN_ERR_CANCELLED,
      NULL,
      "SubversionR cancel callback is invalid"
    );
  }

  int callback_status = callbacks->cancel_callback(callbacks->baton);
  if (callback_status == SUBVERSIONR_BRIDGE_CANCEL_CALLBACK_CONTINUE) {
    return SVN_NO_ERROR;
  }
  if (callback_status == SUBVERSIONR_BRIDGE_CANCEL_CALLBACK_CANCEL) {
    return svn_error_create(
      SVN_ERR_CANCELLED,
      NULL,
      "SubversionR operation cancelled"
    );
  }

  cancel_baton->callback_failed = 1;
  return svn_error_create(
    SVN_ERR_CANCELLED,
    NULL,
    "SubversionR cancel callback failed"
  );
}

static int bridge_error_status_with_cancellation(
  subversionr_bridge_runtime *runtime,
  svn_error_t *err,
  bridge_cancel_baton *cancel_baton,
  int callback_failed_status,
  int cancelled_status
) {
  apr_status_t error_code = err->apr_err;
  bridge_capture_error(runtime, err);
  svn_error_clear(err);
  if (cancel_baton != NULL && cancel_baton->callback_failed) {
    return callback_failed_status;
  }
  if (error_code == SVN_ERR_CANCELLED) {
    return cancelled_status;
  }
  return 2;
}

static int bridge_error_is_auth_failure(const svn_error_t *err) {
  for (const svn_error_t *current = err; current != NULL; current = current->child) {
    switch (current->apr_err) {
      case SVN_ERR_RA_NOT_AUTHORIZED:
      case SVN_ERR_AUTHN_CREDS_UNAVAILABLE:
      case SVN_ERR_AUTHN_NO_PROVIDER:
      case SVN_ERR_AUTHN_PROVIDERS_EXHAUSTED:
      case SVN_ERR_AUTHN_CREDS_NOT_SAVED:
      case SVN_ERR_AUTHN_FAILED:
      case SVN_ERR_AUTHZ_ROOT_UNREADABLE:
      case SVN_ERR_AUTHZ_UNREADABLE:
      case SVN_ERR_AUTHZ_PARTIALLY_READABLE:
      case SVN_ERR_AUTHZ_INVALID_CONFIG:
      case SVN_ERR_AUTHZ_UNWRITABLE:
        return 1;
      default:
        break;
    }
  }
  return 0;
}

static int bridge_status_scan_impl(
  subversionr_bridge_runtime *runtime,
  const char *path,
  svn_depth_t scan_depth,
  svn_boolean_t get_all,
  svn_boolean_t check_out_of_date,
  svn_boolean_t check_working_copy,
  int classify_auth_failures,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_status_scan_info *snapshot
) {
  if (
    runtime == NULL ||
    path == NULL ||
    cancel_callbacks == NULL ||
    snapshot == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_STATUS_CANCEL_CALLBACK_FAILED;
  }
  const char *local_abspath = NULL;
  svn_error_t *err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  apr_array_header_t *entries =
    apr_array_make(runtime->result_pool, 16, sizeof(subversionr_bridge_status_entry));
  bridge_status_receiver_baton receiver_baton = { 0 };
  receiver_baton.entries = entries;
  receiver_baton.result_pool = runtime->result_pool;
  receiver_baton.ctx = runtime->ctx;
  receiver_baton.check_working_copy = check_working_copy ? 1 : 0;

  svn_opt_revision_t revision = { 0 };
  revision.kind = svn_opt_revision_unspecified;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  receiver_baton.cancel_baton = &cancel_baton;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;
  const svn_boolean_t no_ignore = FALSE;
  const svn_boolean_t ignore_externals = TRUE;
  const svn_boolean_t depth_as_sticky = FALSE;
  err = svn_client_status6(
    NULL,
    runtime->ctx,
    local_abspath,
    &revision,
    scan_depth,
    get_all,
    check_out_of_date,
    check_working_copy,
    no_ignore,
    ignore_externals,
    depth_as_sticky,
    NULL,
    bridge_status_receiver,
    &receiver_baton,
    runtime->result_pool
  );
  if (err == NULL) {
    err = bridge_status_populate_copy_metadata(
      runtime->ctx,
      entries,
      runtime->result_pool,
      runtime->result_pool
    );
  }
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;
  if (err != NULL) {
    if (classify_auth_failures && bridge_error_is_auth_failure(err)) {
      bridge_capture_error(runtime, err);
      svn_error_clear(err);
      return 12;
    }
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_STATUS_CANCEL_CALLBACK_FAILED,
      BRIDGE_STATUS_CANCELLED
    );
  }

  snapshot->entries = (const subversionr_bridge_status_entry *)entries->elts;
  snapshot->entry_count = (size_t)entries->nelts;
  return 0;
}

int subversionr_bridge_status_scan(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *depth,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_status_scan_info *snapshot
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL) {
    return 1;
  }
  svn_depth_t scan_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &scan_depth)) {
    return 5;
  }
  return bridge_status_scan_impl(
    runtime,
    path,
    scan_depth,
    TRUE,
    FALSE,
    TRUE,
    0,
    cancel_callbacks,
    snapshot
  );
}

int subversionr_bridge_status_remote_scan_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const subversionr_bridge_auth_callbacks *auth_callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_status_scan_info *snapshot
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    path == NULL ||
    snapshot == NULL ||
    !bridge_auth_callbacks_valid(auth_callbacks)
  ) {
    return 1;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 12;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *auth_callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 12;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_status_scan_impl(
    runtime,
    path,
    svn_depth_unknown,
    FALSE,
    TRUE,
    FALSE,
    1,
    cancel_callbacks,
    snapshot
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);
  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_content_revision(
  const char *revision,
  svn_opt_revision_t *peg_revision,
  svn_opt_revision_t *operative_revision
) {
  if (strcmp(revision, "base") == 0) {
    peg_revision->kind = svn_opt_revision_base;
    operative_revision->kind = svn_opt_revision_base;
    return 1;
  }
  if (strcmp(revision, "head") == 0) {
    peg_revision->kind = svn_opt_revision_base;
    operative_revision->kind = svn_opt_revision_head;
    return 1;
  }
  if (revision[0] == 'r') {
    const char *number_text = revision + 1;
    char *end = NULL;
    long number = 0;
    const char *cursor = number_text;
    if (number_text[0] == '\0' || (number_text[0] == '0' && number_text[1] != '\0')) {
      return 0;
    }
    while (*cursor != '\0') {
      if (*cursor < '0' || *cursor > '9') {
        return 0;
      }
      ++cursor;
    }
    errno = 0;
    number = strtol(number_text, &end, 10);
    if (errno == ERANGE || end == NULL || *end != '\0' || number < 0 || number > BRIDGE_MAX_SVN_REVNUM) {
      return 0;
    }
    peg_revision->kind = svn_opt_revision_base;
    operative_revision->kind = svn_opt_revision_number;
    operative_revision->value.number = (svn_revnum_t)number;
    return 1;
  }
  return 0;
}

static int bridge_log_revision(
  const char *revision,
  int allow_head,
  svn_opt_revision_t *result
) {
  if (allow_head && strcmp(revision, "head") == 0) {
    result->kind = svn_opt_revision_head;
    return 1;
  }
  if (revision[0] == 'r') {
    const char *number_text = revision + 1;
    char *end = NULL;
    long number = 0;
    const char *cursor = number_text;
    if (number_text[0] == '\0' || (number_text[0] == '0' && number_text[1] != '\0')) {
      return 0;
    }
    while (*cursor != '\0') {
      if (*cursor < '0' || *cursor > '9') {
        return 0;
      }
      ++cursor;
    }
    errno = 0;
    number = strtol(number_text, &end, 10);
    if (errno == ERANGE || end == NULL || *end != '\0' || number < 0 || number > BRIDGE_MAX_SVN_REVNUM) {
      return 0;
    }
    result->kind = svn_opt_revision_number;
    result->value.number = (svn_revnum_t)number;
    return 1;
  }
  return 0;
}

static int bridge_blame_revision(
  const char *revision,
  int allow_base,
  int allow_head,
  svn_opt_revision_t *result
) {
  if (allow_base && strcmp(revision, "base") == 0) {
    result->kind = svn_opt_revision_base;
    return 1;
  }
  if (allow_head && strcmp(revision, "head") == 0) {
    result->kind = svn_opt_revision_head;
    return 1;
  }
  return bridge_log_revision(revision, FALSE, result);
}

static int bridge_update_revision(const char *revision, svn_opt_revision_t *result) {
  if (revision == NULL || result == NULL) {
    return 0;
  }
  if (strcmp(revision, "head") == 0) {
    result->kind = svn_opt_revision_head;
    result->value.number = SVN_INVALID_REVNUM;
    return 1;
  }

  char *end = NULL;
  long number = 0;
  const char *cursor = revision;
  if (revision[0] == '\0' || (revision[0] == '0' && revision[1] != '\0')) {
    return 0;
  }
  while (*cursor != '\0') {
    if (*cursor < '0' || *cursor > '9') {
      return 0;
    }
    ++cursor;
  }
  errno = 0;
  number = strtol(revision, &end, 10);
  if (errno == ERANGE || end == NULL || *end != '\0' || number < 0 || number > BRIDGE_MAX_SVN_REVNUM) {
    return 0;
  }
  result->kind = svn_opt_revision_number;
  result->value.number = (svn_revnum_t)number;
  return 1;
}

static int bridge_blame_diff_options(
  const char *ignore_whitespace,
  int ignore_eol_style,
  svn_diff_file_options_t **diff_options,
  apr_pool_t *pool
) {
  svn_diff_file_options_t *options = svn_diff_file_options_create(pool);
  if (strcmp(ignore_whitespace, "none") == 0) {
    options->ignore_space = svn_diff_file_ignore_space_none;
  } else if (strcmp(ignore_whitespace, "change") == 0) {
    options->ignore_space = svn_diff_file_ignore_space_change;
  } else if (strcmp(ignore_whitespace, "all") == 0) {
    options->ignore_space = svn_diff_file_ignore_space_all;
  } else {
    return 0;
  }

  options->ignore_eol_style = ignore_eol_style ? TRUE : FALSE;
  *diff_options = options;
  return 1;
}

static int bridge_content_get_impl(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *revision,
  subversionr_bridge_content_info *content
) {
  svn_opt_revision_t peg_revision = { 0 };
  svn_opt_revision_t operative_revision = { 0 };
  if (runtime == NULL || path == NULL || revision == NULL || content == NULL) {
    return 1;
  }
  if (!bridge_content_revision(revision, &peg_revision, &operative_revision)) {
    return 6;
  }

  memset(content, 0, sizeof(*content));

  const char *local_abspath = NULL;
  svn_error_t *err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  svn_stringbuf_t *buffer = svn_stringbuf_create_empty(runtime->result_pool);
  svn_stream_t *out = svn_stream_from_stringbuf(buffer, runtime->result_pool);
  apr_hash_t *props = NULL;

  err = svn_client_cat3(
    &props,
    out,
    local_abspath,
    &peg_revision,
    &operative_revision,
    TRUE,
    runtime->ctx,
    runtime->result_pool,
    runtime->result_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  err = svn_stream_close(out);
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  const svn_string_t *mime_type =
    props != NULL ? (const svn_string_t *)svn_hash_gets(props, SVN_PROP_MIME_TYPE) : NULL;
  const char *mime_type_cstr = mime_type != NULL
    ? apr_pstrmemdup(runtime->result_pool, mime_type->data, mime_type->len)
    : NULL;

  content->data = (const unsigned char *)buffer->data;
  content->byte_count = (size_t)buffer->len;
  content->mime_type = mime_type_cstr;
  content->is_binary =
    (mime_type_cstr != NULL && svn_mime_type_is_binary(mime_type_cstr)) ? 1 : 0;
  return 0;
}

int subversionr_bridge_content_get_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *revision,
  const subversionr_bridge_auth_callbacks *callbacks,
  subversionr_bridge_content_info *content
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    path == NULL ||
    revision == NULL ||
    content == NULL ||
    !bridge_auth_callbacks_valid(callbacks)
  ) {
    return 1;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_content_get_impl(runtime, path, revision, content);
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

int subversionr_bridge_properties_list(
  subversionr_bridge_runtime *runtime,
  const char *path,
  subversionr_bridge_property_list *properties
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || path == NULL || properties == NULL) {
    return 1;
  }

  memset(properties, 0, sizeof(*properties));

  const char *local_abspath = NULL;
  svn_error_t *err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  bridge_property_list_baton property_baton = { 0 };
  property_baton.sort_keys =
    apr_array_make(runtime->result_pool, 0, sizeof(bridge_property_entry_sort_key));
  property_baton.result_pool = runtime->result_pool;
  svn_opt_revision_t revision;
  revision.kind = svn_opt_revision_working;
  err = svn_client_proplist4(
    local_abspath,
    &revision,
    &revision,
    svn_depth_empty,
    NULL,
    FALSE,
    bridge_property_list_receiver,
    &property_baton,
    runtime->ctx,
    runtime->result_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return property_baton.rejected_binary_property ? 3 : 2;
  }

  qsort(
    property_baton.sort_keys->elts,
    (size_t)property_baton.sort_keys->nelts,
    sizeof(bridge_property_entry_sort_key),
    bridge_property_entry_compare
  );

  apr_array_header_t *entries =
    apr_array_make(
      runtime->result_pool,
      property_baton.sort_keys->nelts,
      sizeof(subversionr_bridge_property_entry)
    );
  for (int index = 0; index < property_baton.sort_keys->nelts; index++) {
    bridge_property_entry_sort_key sort_key =
      APR_ARRAY_IDX(property_baton.sort_keys, index, bridge_property_entry_sort_key);
    subversionr_bridge_property_entry entry = { 0 };
    entry.name = sort_key.name;
    entry.value = apr_pstrmemdup(runtime->result_pool, sort_key.value->data, sort_key.value->len);
    entry.value_encoding = "utf8";
    APR_ARRAY_PUSH(entries, subversionr_bridge_property_entry) = entry;
  }

  properties->entries = (const subversionr_bridge_property_entry *)entries->elts;
  properties->entry_count = (size_t)entries->nelts;
  return 0;
}

static int bridge_history_log_impl(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *start_revision,
  const char *end_revision,
  int limit,
  int discover_changed_paths,
  int strict_node_history,
  int include_merged_revisions,
  subversionr_bridge_log_info *log
) {
  if (
    runtime == NULL ||
    path == NULL ||
    start_revision == NULL ||
    end_revision == NULL ||
    limit <= 0 ||
    limit > 500 ||
    log == NULL
  ) {
    return 1;
  }

  svn_opt_revision_t start = { 0 };
  svn_opt_revision_t end = { 0 };
  if (!bridge_log_revision(start_revision, TRUE, &start) ||
      !bridge_log_revision(end_revision, FALSE, &end)) {
    return 6;
  }

  memset(log, 0, sizeof(*log));

  const char *local_abspath = NULL;
  svn_error_t *err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  apr_array_header_t *targets =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  APR_ARRAY_PUSH(targets, const char *) = local_abspath;

  svn_opt_revision_range_t *range =
    apr_pcalloc(runtime->result_pool, sizeof(svn_opt_revision_range_t));
  range->start = start;
  range->end = end;
  apr_array_header_t *revision_ranges =
    apr_array_make(runtime->result_pool, 1, sizeof(svn_opt_revision_range_t *));
  APR_ARRAY_PUSH(revision_ranges, svn_opt_revision_range_t *) = range;

  apr_array_header_t *revprops =
    apr_array_make(runtime->result_pool, 3, sizeof(const char *));
  APR_ARRAY_PUSH(revprops, const char *) = SVN_PROP_REVISION_AUTHOR;
  APR_ARRAY_PUSH(revprops, const char *) = SVN_PROP_REVISION_DATE;
  APR_ARRAY_PUSH(revprops, const char *) = SVN_PROP_REVISION_LOG;

  apr_array_header_t *entries =
    apr_array_make(runtime->result_pool, limit, sizeof(subversionr_bridge_log_entry));
  bridge_log_receiver_baton receiver_baton = { 0 };
  receiver_baton.entries = entries;
  receiver_baton.result_pool = runtime->result_pool;

  svn_opt_revision_t peg_revision = { 0 };
  peg_revision.kind = svn_opt_revision_unspecified;
  err = svn_client_log5(
    targets,
    &peg_revision,
    revision_ranges,
    limit,
    discover_changed_paths ? TRUE : FALSE,
    strict_node_history ? TRUE : FALSE,
    include_merged_revisions ? TRUE : FALSE,
    revprops,
    bridge_log_receiver,
    &receiver_baton,
    runtime->ctx,
    runtime->result_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  log->entries = (const subversionr_bridge_log_entry *)entries->elts;
  log->entry_count = (size_t)entries->nelts;
  return 0;
}

int subversionr_bridge_history_log_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *start_revision,
  const char *end_revision,
  int limit,
  int discover_changed_paths,
  int strict_node_history,
  int include_merged_revisions,
  const subversionr_bridge_auth_callbacks *callbacks,
  subversionr_bridge_log_info *log
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    path == NULL ||
    start_revision == NULL ||
    end_revision == NULL ||
    limit <= 0 ||
    limit > 500 ||
    log == NULL ||
    !bridge_auth_callbacks_valid(callbacks)
  ) {
    return 1;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_history_log_impl(
    runtime,
    path,
    start_revision,
    end_revision,
    limit,
    discover_changed_paths,
    strict_node_history,
    include_merged_revisions,
    log
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_history_blame_impl(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *peg_revision,
  const char *start_revision,
  const char *end_revision,
  const char *ignore_whitespace,
  int ignore_eol_style,
  int ignore_mime_type,
  int include_merged_revisions,
  long long line_start,
  int line_limit,
  subversionr_bridge_blame_info *blame
) {
  if (
    runtime == NULL ||
    path == NULL ||
    peg_revision == NULL ||
    start_revision == NULL ||
    end_revision == NULL ||
    ignore_whitespace == NULL ||
    line_start <= 0 ||
    line_limit <= 0 ||
    line_limit > 5000 ||
    blame == NULL
  ) {
    return 1;
  }

  svn_opt_revision_t peg = { 0 };
  svn_opt_revision_t start = { 0 };
  svn_opt_revision_t end = { 0 };
  if (!bridge_blame_revision(peg_revision, TRUE, TRUE, &peg) ||
      !bridge_blame_revision(start_revision, FALSE, FALSE, &start) ||
      !bridge_blame_revision(end_revision, TRUE, TRUE, &end)) {
    return 6;
  }

  memset(blame, 0, sizeof(*blame));
  blame->resolved_start_revision = -1;
  blame->resolved_end_revision = -1;

  const char *local_abspath = NULL;
  svn_error_t *err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    return 2;
  }

  svn_diff_file_options_t *diff_options = NULL;
  if (!bridge_blame_diff_options(
        ignore_whitespace,
        ignore_eol_style,
        &diff_options,
        runtime->result_pool
      )) {
    return 1;
  }

  apr_array_header_t *lines =
    apr_array_make(runtime->result_pool, line_limit, sizeof(subversionr_bridge_blame_line));
  bridge_blame_receiver_baton receiver_baton = { 0 };
  receiver_baton.lines = lines;
  receiver_baton.result_pool = runtime->result_pool;
  receiver_baton.line_start = line_start;
  receiver_baton.line_limit = line_limit;

  svn_revnum_t resolved_start_revision = SVN_INVALID_REVNUM;
  svn_revnum_t resolved_end_revision = SVN_INVALID_REVNUM;
  err = svn_client_blame6(
    &resolved_start_revision,
    &resolved_end_revision,
    local_abspath,
    &peg,
    &start,
    &end,
    diff_options,
    ignore_mime_type ? TRUE : FALSE,
    include_merged_revisions ? TRUE : FALSE,
    bridge_blame_receiver,
    &receiver_baton,
    runtime->ctx,
    runtime->result_pool
  );
  if (err != NULL) {
    if (err->apr_err == SVN_ERR_CEASE_INVOCATION) {
      svn_error_clear(err);
    } else if (err->apr_err == SVN_ERR_CLIENT_IS_BINARY_FILE) {
      bridge_capture_error(runtime, err);
      svn_error_clear(err);
      return 9;
    } else {
      bridge_capture_error(runtime, err);
      svn_error_clear(err);
      return 2;
    }
  }

  if (!SVN_IS_VALID_REVNUM(resolved_start_revision) ||
      !SVN_IS_VALID_REVNUM(resolved_end_revision)) {
    return 2;
  }

  blame->resolved_start_revision = bridge_revision_to_i64(resolved_start_revision);
  blame->resolved_end_revision = bridge_revision_to_i64(resolved_end_revision);
  blame->lines = (const subversionr_bridge_blame_line *)lines->elts;
  blame->line_count = (size_t)lines->nelts;
  blame->has_more = receiver_baton.has_more;
  return 0;
}

int subversionr_bridge_history_blame_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *peg_revision,
  const char *start_revision,
  const char *end_revision,
  const char *ignore_whitespace,
  int ignore_eol_style,
  int ignore_mime_type,
  int include_merged_revisions,
  long long line_start,
  int line_limit,
  const subversionr_bridge_auth_callbacks *callbacks,
  subversionr_bridge_blame_info *blame
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    path == NULL ||
    peg_revision == NULL ||
    start_revision == NULL ||
    end_revision == NULL ||
    ignore_whitespace == NULL ||
    line_start <= 0 ||
    line_limit <= 0 ||
    line_limit > 5000 ||
    blame == NULL ||
    !bridge_auth_callbacks_valid(callbacks)
  ) {
    return 1;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_history_blame_impl(
    runtime,
    path,
    peg_revision,
    start_revision,
    end_revision,
    ignore_whitespace,
    ignore_eol_style,
    ignore_mime_type,
    include_merged_revisions,
    line_start,
    line_limit,
    blame
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

int subversionr_bridge_operation_revert(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *const *changelists,
  size_t changelist_count,
  int clear_changelists,
  int metadata_only,
  int added_keep_local,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || paths == NULL || path_count == 0 || depth == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (changelist_count > 0 && changelists == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  svn_depth_t revert_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &revert_depth)) {
    return 5;
  }

  memset(result, 0, sizeof(*result));

  apr_array_header_t *local_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    APR_ARRAY_PUSH(local_paths, const char *) = local_abspath;
  }

  apr_array_header_t *revert_changelists = NULL;
  if (changelist_count > 0) {
    revert_changelists =
      apr_array_make(runtime->result_pool, (int)changelist_count, sizeof(const char *));
    for (size_t index = 0; index < changelist_count; index++) {
      if (changelists[index] == NULL) {
        return 1;
      }
      APR_ARRAY_PUSH(revert_changelists, const char *) =
        apr_pstrdup(runtime->result_pool, changelists[index]);
    }
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_revert4(
    local_paths,
    revert_depth,
    revert_changelists,
    clear_changelists ? TRUE : FALSE,
    metadata_only ? TRUE : FALSE,
    added_keep_local ? TRUE : FALSE,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_add(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  int force,
  int no_ignore,
  int no_autoprops,
  int add_parents,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || paths == NULL || path_count == 0 || depth == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  svn_depth_t add_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &add_depth)) {
    return 5;
  }

  memset(result, 0, sizeof(*result));

  apr_array_header_t *local_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    APR_ARRAY_PUSH(local_paths, const char *) = local_abspath;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = SVN_NO_ERROR;
  for (int index = 0; index < local_paths->nelts; index++) {
    err = bridge_cancel_check(&cancel_baton);
    if (err != NULL) {
      break;
    }
    const char *local_abspath = APR_ARRAY_IDX(local_paths, index, const char *);
    err = svn_client_add5(
      local_abspath,
      add_depth,
      force ? TRUE : FALSE,
      no_ignore ? TRUE : FALSE,
      no_autoprops ? TRUE : FALSE,
      add_parents ? TRUE : FALSE,
      runtime->ctx,
      runtime->result_pool
    );
    if (err != NULL) {
      break;
    }
  }

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_remove(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  int force,
  int keep_local,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || paths == NULL || path_count == 0 || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  memset(result, 0, sizeof(*result));

  apr_array_header_t *local_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    APR_ARRAY_PUSH(local_paths, const char *) = local_abspath;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_delete4(
    local_paths,
    force ? TRUE : FALSE,
    keep_local ? TRUE : FALSE,
    NULL,
    NULL,
    NULL,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_move(
  subversionr_bridge_runtime *runtime,
  const char *source_path,
  const char *destination_path,
  int make_parents,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || source_path == NULL || destination_path == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  memset(result, 0, sizeof(*result));

  const char *source_abspath = NULL;
  svn_error_t *source_absolute_err = svn_dirent_get_absolute(&source_abspath, source_path, runtime->result_pool);
  if (source_absolute_err != NULL) {
    bridge_capture_error(runtime, source_absolute_err);
    svn_error_clear(source_absolute_err);
    return 2;
  }
  const char *destination_abspath = NULL;
  svn_error_t *destination_absolute_err = svn_dirent_get_absolute(&destination_abspath, destination_path, runtime->result_pool);
  if (destination_absolute_err != NULL) {
    bridge_capture_error(runtime, destination_absolute_err);
    svn_error_clear(destination_absolute_err);
    return 2;
  }

  apr_array_header_t *local_sources =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  APR_ARRAY_PUSH(local_sources, const char *) = source_abspath;

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 2, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 2, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = bridge_cancel_check(&cancel_baton);
  if (err == NULL) {
    err = svn_client_move7(
      local_sources,
      destination_abspath,
      FALSE,
      make_parents ? TRUE : FALSE,
      FALSE,
      FALSE,
      NULL,
      NULL,
      NULL,
      runtime->ctx,
      runtime->result_pool
    );
  }

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_resolve(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *choice,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || paths == NULL || path_count != 1 || depth == NULL || choice == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  svn_depth_t resolve_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &resolve_depth)) {
    return 5;
  }
  if (resolve_depth != svn_depth_empty) {
    return 5;
  }
  svn_wc_conflict_choice_t conflict_choice = svn_wc_conflict_choose_undefined;
  if (!bridge_conflict_choice_from_word(choice, &conflict_choice)) {
    return 7;
  }

  memset(result, 0, sizeof(*result));

  apr_array_header_t *local_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    APR_ARRAY_PUSH(local_paths, const char *) = local_abspath;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = SVN_NO_ERROR;
  for (int index = 0; index < local_paths->nelts; index++) {
    err = bridge_cancel_check(&cancel_baton);
    if (err != NULL) {
      break;
    }
    const char *local_abspath = APR_ARRAY_IDX(local_paths, index, const char *);
    err = svn_client_resolve(
      local_abspath,
      resolve_depth,
      conflict_choice,
      runtime->ctx,
      runtime->result_pool
    );
    if (err != NULL) {
      break;
    }
  }

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_cleanup(
  subversionr_bridge_runtime *runtime,
  const char *path,
  int break_locks,
  int fix_recorded_timestamps,
  int clear_dav_cache,
  int vacuum_pristines,
  int include_externals,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || path == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  memset(result, 0, sizeof(*result));

  const char *local_abspath = NULL;
  svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_cleanup2(
    local_abspath,
    break_locks ? TRUE : FALSE,
    fix_recorded_timestamps ? TRUE : FALSE,
    clear_dav_cache ? TRUE : FALSE,
    vacuum_pristines ? TRUE : FALSE,
    include_externals ? TRUE : FALSE,
    runtime->ctx,
    runtime->result_pool
  );
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;
  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 0, sizeof(const char *));
  APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_upgrade(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (runtime == NULL || path == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  memset(result, 0, sizeof(*result));

  const char *local_abspath = NULL;
  svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_upgrade(
    local_abspath,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;
  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 0, sizeof(const char *));
  APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

static int bridge_operation_update_impl(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *revision,
  const char *depth,
  int depth_is_sticky,
  int ignore_externals,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  if (runtime == NULL || path == NULL || revision == NULL || depth == NULL || cancel_callbacks == NULL || result == NULL || result_revision == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (depth_is_sticky != FALSE && depth_is_sticky != TRUE) {
    return 7;
  }
  if (ignore_externals != FALSE && ignore_externals != TRUE) {
    return 8;
  }

  svn_opt_revision_t target_revision;
  if (!bridge_update_revision(revision, &target_revision)) {
    return 6;
  }

  svn_depth_t update_depth = svn_depth_unknown;
  if (!bridge_update_depth_from_word(depth, &update_depth)) {
    return 5;
  }
  if (update_depth == svn_depth_unknown && depth_is_sticky) {
    return 7;
  }

  memset(result, 0, sizeof(*result));
  *result_revision = -1;

  const char *local_abspath = NULL;
  svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  apr_array_header_t *local_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  APR_ARRAY_PUSH(local_paths, const char *) = local_abspath;

  apr_array_header_t *notify_touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = notify_touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  apr_array_header_t *result_revs = NULL;
  svn_error_t *err = svn_client_update4(
    &result_revs,
    local_paths,
    &target_revision,
    update_depth,
    depth_is_sticky ? TRUE : FALSE,
    ignore_externals ? TRUE : FALSE,
    FALSE,
    TRUE,
    FALSE,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  if (result_revs != NULL && result_revs->nelts > 0) {
    svn_revnum_t update_revision = APR_ARRAY_IDX(result_revs, 0, svn_revnum_t);
    *result_revision = bridge_revision_to_i64(update_revision);
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_update(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *revision,
  const char *depth,
  int depth_is_sticky,
  int ignore_externals,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    path == NULL ||
    revision == NULL ||
    depth == NULL ||
    result == NULL ||
    result_revision == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_update_impl(
    runtime,
    path,
    revision,
    depth,
    depth_is_sticky,
    ignore_externals,
    cancel_callbacks,
    result,
    result_revision
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_repository_checkout_impl(
  subversionr_bridge_runtime *runtime,
  const char *url,
  const char *target_path,
  const char *revision,
  const char *depth,
  int ignore_externals,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  long long *result_revision
) {
  if (
    runtime == NULL ||
    url == NULL ||
    target_path == NULL ||
    revision == NULL ||
    depth == NULL ||
    cancel_callbacks == NULL ||
    result_revision == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (url[0] == '\0' || target_path[0] == '\0') {
    return 2;
  }
  if (ignore_externals != FALSE && ignore_externals != TRUE) {
    return 8;
  }

  svn_opt_revision_t target_revision;
  if (!bridge_update_revision(revision, &target_revision)) {
    return 6;
  }

  svn_depth_t checkout_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &checkout_depth)) {
    return 5;
  }

  *result_revision = -1;

  const char *local_abspath = NULL;
  svn_error_t *absolute_err =
    svn_dirent_get_absolute(&local_abspath, target_path, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_revnum_t checked_out_revision = SVN_INVALID_REVNUM;
  svn_error_t *err = svn_client_checkout3(
    &checked_out_revision,
    url,
    local_abspath,
    &target_revision,
    &target_revision,
    checkout_depth,
    ignore_externals ? TRUE : FALSE,
    FALSE,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  *result_revision = bridge_revision_to_i64(checked_out_revision);
  return 0;
}

int subversionr_bridge_repository_checkout_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *url,
  const char *target_path,
  const char *revision,
  const char *depth,
  int ignore_externals,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  long long *result_revision
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    url == NULL ||
    target_path == NULL ||
    revision == NULL ||
    depth == NULL ||
    result_revision == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, target_path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_repository_checkout_impl(
    runtime,
    url,
    target_path,
    revision,
    depth,
    ignore_externals,
    cancel_callbacks,
    result_revision
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_operation_property_apply(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *name,
  const char *value,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  if (runtime == NULL || path == NULL || name == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (!svn_prop_name_is_valid(name)) {
    return 4;
  }
  if (value != NULL && strchr(value, '\r') != NULL) {
    return 5;
  }

  memset(result, 0, sizeof(*result));

  const char *local_abspath = NULL;
  svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  apr_array_header_t *targets =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  APR_ARRAY_PUSH(targets, const char *) = local_abspath;

  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = bridge_cancel_check(&cancel_baton);
  if (err == NULL) {
    const svn_string_t *property_value =
      value != NULL ? svn_string_create(value, runtime->result_pool) : NULL;
    err = svn_client_propset_local(
      name,
      property_value,
      targets,
      svn_depth_empty,
      FALSE,
      NULL,
      runtime->ctx,
      runtime->result_pool
    );
  }

  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 0, sizeof(const char *));
  APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_property_set(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *name,
  const char *value,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (value == NULL) {
    return 1;
  }
  return bridge_operation_property_apply(runtime, path, name, value, cancel_callbacks, result);
}

int subversionr_bridge_operation_property_delete(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *name,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  return bridge_operation_property_apply(runtime, path, name, NULL, cancel_callbacks, result);
}

static int bridge_operation_changelist_apply(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *changelist,
  const char *const *changelists,
  size_t changelist_count,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  if (runtime == NULL || paths == NULL || path_count == 0 || depth == NULL || cancel_callbacks == NULL || result == NULL) {
    return 1;
  }
  if (changelist != NULL && changelist[0] == '\0') {
    return 1;
  }
  if (changelist_count > 0 && changelists == NULL) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  svn_depth_t changelist_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &changelist_depth)) {
    return 5;
  }

  memset(result, 0, sizeof(*result));

  apr_array_header_t *local_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    APR_ARRAY_PUSH(local_paths, const char *) = local_abspath;
  }

  apr_array_header_t *restrictive_changelists = NULL;
  if (changelist_count > 0) {
    restrictive_changelists =
      apr_array_make(runtime->result_pool, (int)changelist_count, sizeof(const char *));
    for (size_t index = 0; index < changelist_count; index++) {
      if (changelists[index] == NULL || changelists[index][0] == '\0') {
        return 1;
      }
      APR_ARRAY_PUSH(restrictive_changelists, const char *) =
        apr_pstrdup(runtime->result_pool, changelists[index]);
    }
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = bridge_cancel_check(&cancel_baton);
  if (err == NULL) {
    if (changelist != NULL) {
      err = svn_client_add_to_changelist(
        local_paths,
        changelist,
        changelist_depth,
        restrictive_changelists,
        runtime->ctx,
        runtime->result_pool
      );
    } else {
      err = svn_client_remove_from_changelists(
        local_paths,
        changelist_depth,
        restrictive_changelists,
        runtime->ctx,
        runtime->result_pool
      );
    }
  }

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_changelist_set(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *changelist,
  const char *const *changelists,
  size_t changelist_count,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (changelist == NULL) {
    return 1;
  }
  return bridge_operation_changelist_apply(
    runtime,
    paths,
    path_count,
    depth,
    changelist,
    changelists,
    changelist_count,
    cancel_callbacks,
    result
  );
}

int subversionr_bridge_operation_changelist_clear(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *const *changelists,
  size_t changelist_count,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  return bridge_operation_changelist_apply(
    runtime,
    paths,
    path_count,
    depth,
    NULL,
    changelists,
    changelist_count,
    cancel_callbacks,
    result
  );
}

static int bridge_operation_lock_impl(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *comment,
  int steal_lock,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  if (
    runtime == NULL ||
    paths == NULL ||
    path_count == 0 ||
    cancel_callbacks == NULL ||
    result == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (steal_lock != FALSE && steal_lock != TRUE) {
    return 7;
  }

  memset(result, 0, sizeof(*result));

  apr_array_header_t *targets =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err =
      svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    APR_ARRAY_PUSH(targets, const char *) = local_abspath;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 0, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_lock(
    targets,
    comment,
    steal_lock ? TRUE : FALSE,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_lock_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *comment,
  int steal_lock,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    paths == NULL ||
    path_count == 0 ||
    result == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = paths[0] != NULL ? apr_pstrdup(auth_pool, paths[0]) : NULL;
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    1,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_lock_impl(
    runtime,
    paths,
    path_count,
    comment,
    steal_lock,
    cancel_callbacks,
    result
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_operation_unlock_impl(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  int break_lock,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  if (
    runtime == NULL ||
    paths == NULL ||
    path_count == 0 ||
    cancel_callbacks == NULL ||
    result == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (break_lock != FALSE && break_lock != TRUE) {
    return 7;
  }

  memset(result, 0, sizeof(*result));

  apr_array_header_t *targets =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err =
      svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    APR_ARRAY_PUSH(targets, const char *) = local_abspath;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 0, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_unlock(
    targets,
    break_lock ? TRUE : FALSE,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_unlock_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  int break_lock,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    paths == NULL ||
    path_count == 0 ||
    result == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = paths[0] != NULL ? apr_pstrdup(auth_pool, paths[0]) : NULL;
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    1,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_unlock_impl(
    runtime,
    paths,
    path_count,
    break_lock,
    cancel_callbacks,
    result
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_operation_branch_create_impl(
  subversionr_bridge_runtime *runtime,
  const char *source_url,
  const char *destination_url,
  const char *revision,
  const char *message,
  int make_parents,
  int ignore_externals,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  if (
    runtime == NULL ||
    source_url == NULL ||
    destination_url == NULL ||
    revision == NULL ||
    message == NULL ||
    cancel_callbacks == NULL ||
    result == NULL ||
    result_revision == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (source_url[0] == '\0' || destination_url[0] == '\0') {
    return 2;
  }
  if (make_parents != FALSE && make_parents != TRUE) {
    return 7;
  }
  if (ignore_externals != FALSE && ignore_externals != TRUE) {
    return 8;
  }
  if (!bridge_valid_commit_message(message)) {
    return 3;
  }

  svn_opt_revision_t target_revision;
  if (!bridge_update_revision(revision, &target_revision)) {
    return 6;
  }

  memset(result, 0, sizeof(*result));
  *result_revision = -1;

  svn_client_copy_source_t *source =
    apr_pcalloc(runtime->result_pool, sizeof(*source));
  source->path = apr_pstrdup(runtime->result_pool, source_url);
  source->revision = &target_revision;
  source->peg_revision = &target_revision;

  apr_array_header_t *sources =
    apr_array_make(runtime->result_pool, 1, sizeof(svn_client_copy_source_t *));
  APR_ARRAY_PUSH(sources, svn_client_copy_source_t *) = source;

  bridge_commit_log_baton log_baton = { 0 };
  log_baton.message = message;
  bridge_commit_callback_baton commit_baton = { 0 };
  commit_baton.revision = SVN_INVALID_REVNUM;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;

  svn_client_get_commit_log3_t previous_log_msg_func3 = runtime->ctx->log_msg_func3;
  void *previous_log_msg_baton3 = runtime->ctx->log_msg_baton3;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->log_msg_func3 = bridge_commit_log_message;
  runtime->ctx->log_msg_baton3 = &log_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_copy7(
    sources,
    destination_url,
    FALSE,
    make_parents ? TRUE : FALSE,
    ignore_externals ? TRUE : FALSE,
    FALSE,
    FALSE,
    NULL,
    NULL,
    bridge_commit_callback,
    &commit_baton,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->log_msg_func3 = previous_log_msg_func3;
  runtime->ctx->log_msg_baton3 = previous_log_msg_baton3;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  if (!SVN_IS_VALID_REVNUM(commit_baton.revision)) {
    return 9;
  }
  *result_revision = bridge_revision_to_i64(commit_baton.revision);

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 0, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 0, sizeof(const char *));
  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_branch_create_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *working_copy_root,
  const char *source_url,
  const char *destination_url,
  const char *revision,
  const char *message,
  int make_parents,
  int ignore_externals,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    working_copy_root == NULL ||
    source_url == NULL ||
    destination_url == NULL ||
    revision == NULL ||
    message == NULL ||
    result == NULL ||
    result_revision == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, working_copy_root);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_branch_create_impl(
    runtime,
    source_url,
    destination_url,
    revision,
    message,
    make_parents,
    ignore_externals,
    cancel_callbacks,
    result,
    result_revision
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_operation_switch_impl(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *url,
  const char *revision,
  const char *depth,
  int depth_is_sticky,
  int ignore_externals,
  int ignore_ancestry,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  if (
    runtime == NULL ||
    path == NULL ||
    url == NULL ||
    revision == NULL ||
    depth == NULL ||
    cancel_callbacks == NULL ||
    result == NULL ||
    result_revision == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (url[0] == '\0') {
    return 2;
  }
  if (depth_is_sticky != FALSE && depth_is_sticky != TRUE) {
    return 7;
  }
  if (ignore_externals != FALSE && ignore_externals != TRUE) {
    return 8;
  }
  if (ignore_ancestry != FALSE && ignore_ancestry != TRUE) {
    return 13;
  }

  svn_opt_revision_t target_revision;
  if (!bridge_update_revision(revision, &target_revision)) {
    return 6;
  }

  svn_depth_t switch_depth = svn_depth_unknown;
  if (!bridge_update_depth_from_word(depth, &switch_depth)) {
    return 5;
  }
  if (switch_depth == svn_depth_unknown && depth_is_sticky) {
    return 7;
  }

  memset(result, 0, sizeof(*result));
  *result_revision = -1;

  const char *local_abspath = NULL;
  svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, path, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_revnum_t switch_revision = SVN_INVALID_REVNUM;
  svn_error_t *err = svn_client_switch3(
    &switch_revision,
    local_abspath,
    url,
    &target_revision,
    &target_revision,
    switch_depth,
    depth_is_sticky ? TRUE : FALSE,
    ignore_externals ? TRUE : FALSE,
    FALSE,
    ignore_ancestry ? TRUE : FALSE,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  if (!SVN_IS_VALID_REVNUM(switch_revision)) {
    return 9;
  }
  *result_revision = bridge_revision_to_i64(switch_revision);
  if (touched_paths->nelts == 0) {
    APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_switch_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *url,
  const char *revision,
  const char *depth,
  int depth_is_sticky,
  int ignore_externals,
  int ignore_ancestry,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    path == NULL ||
    url == NULL ||
    revision == NULL ||
    depth == NULL ||
    result == NULL ||
    result_revision == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_switch_impl(
    runtime,
    path,
    url,
    revision,
    depth,
    depth_is_sticky,
    ignore_externals,
    ignore_ancestry,
    cancel_callbacks,
    result,
    result_revision
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_operation_relocate_impl(
  subversionr_bridge_runtime *runtime,
  const char *working_copy_root,
  const char *from_prefix,
  const char *to_prefix,
  int ignore_externals,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  if (
    runtime == NULL ||
    working_copy_root == NULL ||
    from_prefix == NULL ||
    to_prefix == NULL ||
    cancel_callbacks == NULL ||
    result == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (from_prefix[0] == '\0' || to_prefix[0] == '\0') {
    return 2;
  }
  if (ignore_externals != FALSE && ignore_externals != TRUE) {
    return 8;
  }

  memset(result, 0, sizeof(*result));

  const char *local_abspath = NULL;
  svn_error_t *absolute_err =
    svn_dirent_get_absolute(&local_abspath, working_copy_root, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_relocate2(
    local_abspath,
    from_prefix,
    to_prefix,
    ignore_externals ? TRUE : FALSE,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  if (touched_paths->nelts == 0) {
    APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_relocate_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *working_copy_root,
  const char *from_prefix,
  const char *to_prefix,
  int ignore_externals,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    working_copy_root == NULL ||
    from_prefix == NULL ||
    to_prefix == NULL ||
    result == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, working_copy_root);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_relocate_impl(
    runtime,
    working_copy_root,
    from_prefix,
    to_prefix,
    ignore_externals,
    cancel_callbacks,
    result
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_operation_merge_range_impl(
  subversionr_bridge_runtime *runtime,
  const char *source_url,
  const char *target_path,
  long long start_revision,
  long long end_revision,
  const char *depth,
  int ignore_mergeinfo,
  int diff_ignore_ancestry,
  int force_delete,
  int record_only,
  int dry_run,
  int allow_mixed_revisions,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  if (
    runtime == NULL ||
    source_url == NULL ||
    target_path == NULL ||
    depth == NULL ||
    cancel_callbacks == NULL ||
    result == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (source_url[0] == '\0') {
    return 2;
  }
  if (
    start_revision < 0 ||
    end_revision < 0 ||
    start_revision > BRIDGE_MAX_SVN_REVNUM ||
    end_revision > BRIDGE_MAX_SVN_REVNUM ||
    start_revision == end_revision
  ) {
    return 6;
  }
  if (
    (ignore_mergeinfo != FALSE && ignore_mergeinfo != TRUE) ||
    (diff_ignore_ancestry != FALSE && diff_ignore_ancestry != TRUE) ||
    (force_delete != FALSE && force_delete != TRUE) ||
    (record_only != FALSE && record_only != TRUE) ||
    (dry_run != FALSE && dry_run != TRUE) ||
    (allow_mixed_revisions != FALSE && allow_mixed_revisions != TRUE)
  ) {
    return 7;
  }

  svn_depth_t merge_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &merge_depth)) {
    return 5;
  }

  memset(result, 0, sizeof(*result));

  const char *local_abspath = NULL;
  svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, target_path, runtime->result_pool);
  if (absolute_err != NULL) {
    bridge_capture_error(runtime, absolute_err);
    svn_error_clear(absolute_err);
    return 2;
  }

  svn_opt_revision_range_t *range =
    apr_pcalloc(runtime->result_pool, sizeof(svn_opt_revision_range_t));
  range->start.kind = svn_opt_revision_number;
  range->start.value.number = (svn_revnum_t)start_revision;
  range->end.kind = svn_opt_revision_number;
  range->end.value.number = (svn_revnum_t)end_revision;
  apr_array_header_t *revision_ranges =
    apr_array_make(runtime->result_pool, 1, sizeof(svn_opt_revision_range_t *));
  APR_ARRAY_PUSH(revision_ranges, svn_opt_revision_range_t *) = range;

  svn_opt_revision_t source_peg_revision = { 0 };
  source_peg_revision.kind = svn_opt_revision_head;

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, 1, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_merge_peg5(
    source_url,
    revision_ranges,
    &source_peg_revision,
    local_abspath,
    merge_depth,
    ignore_mergeinfo ? TRUE : FALSE,
    diff_ignore_ancestry ? TRUE : FALSE,
    force_delete ? TRUE : FALSE,
    record_only ? TRUE : FALSE,
    dry_run ? TRUE : FALSE,
    allow_mixed_revisions ? TRUE : FALSE,
    NULL,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  if (touched_paths->nelts == 0) {
    APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_merge_range_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *source_url,
  const char *target_path,
  long long start_revision,
  long long end_revision,
  const char *depth,
  int ignore_mergeinfo,
  int diff_ignore_ancestry,
  int force_delete,
  int record_only,
  int dry_run,
  int allow_mixed_revisions,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    source_url == NULL ||
    target_path == NULL ||
    depth == NULL ||
    result == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = apr_pstrdup(auth_pool, target_path);
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_merge_range_impl(
    runtime,
    source_url,
    target_path,
    start_revision,
    end_revision,
    depth,
    ignore_mergeinfo,
    diff_ignore_ancestry,
    force_delete,
    record_only,
    dry_run,
    allow_mixed_revisions,
    cancel_callbacks,
    result
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}

static int bridge_operation_commit_impl(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *message,
  const char *depth,
  const char *const *changelists,
  size_t changelist_count,
  int keep_locks,
  int keep_changelists,
  int commit_as_operations,
  int include_file_externals,
  int include_dir_externals,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  if (
    runtime == NULL ||
    paths == NULL ||
    path_count == 0 ||
    message == NULL ||
    depth == NULL ||
    cancel_callbacks == NULL ||
    result == NULL ||
    result_revision == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }
  if (
    keep_locks ||
    keep_changelists ||
    commit_as_operations ||
    include_file_externals ||
    include_dir_externals
  ) {
    return 7;
  }
  if (!bridge_valid_commit_message(message)) {
    return 8;
  }

  svn_depth_t commit_depth = svn_depth_unknown;
  if (!bridge_depth_from_word(depth, &commit_depth) || commit_depth != svn_depth_empty) {
    return 5;
  }

  memset(result, 0, sizeof(*result));
  *result_revision = -1;

  apr_array_header_t *commit_changelists = NULL;
  if (changelist_count > 0) {
    if (changelists == NULL) {
      return 1;
    }
    commit_changelists =
      apr_array_make(runtime->result_pool, (int)changelist_count, sizeof(const char *));
    for (size_t index = 0; index < changelist_count; index++) {
      if (changelists[index] == NULL || changelists[index][0] == '\0') {
        return 6;
      }
      APR_ARRAY_PUSH(commit_changelists, const char *) =
        apr_pstrdup(runtime->result_pool, changelists[index]);
    }
  }

  apr_array_header_t *local_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  for (size_t index = 0; index < path_count; index++) {
    if (paths[index] == NULL) {
      return 1;
    }
    const char *local_abspath = NULL;
    svn_error_t *absolute_err = svn_dirent_get_absolute(&local_abspath, paths[index], runtime->result_pool);
    if (absolute_err != NULL) {
      bridge_capture_error(runtime, absolute_err);
      svn_error_clear(absolute_err);
      return 2;
    }
    int target_is_versioned_file_or_dir =
      bridge_commit_target_is_versioned_file_or_dir(runtime, local_abspath, runtime->result_pool);
    if (target_is_versioned_file_or_dir < 0) {
      return 2;
    }
    if (!target_is_versioned_file_or_dir) {
      return 10;
    }
    APR_ARRAY_PUSH(local_paths, const char *) = local_abspath;
  }

  apr_array_header_t *touched_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  apr_array_header_t *skipped_paths =
    apr_array_make(runtime->result_pool, (int)path_count, sizeof(const char *));
  bridge_operation_notify_baton notify_baton = { 0 };
  notify_baton.touched_paths = touched_paths;
  notify_baton.skipped_paths = skipped_paths;
  notify_baton.result_pool = runtime->result_pool;

  bridge_commit_log_baton log_baton = { 0 };
  log_baton.message = message;
  bridge_commit_callback_baton commit_baton = { 0 };
  commit_baton.revision = SVN_INVALID_REVNUM;

  svn_wc_notify_func2_t previous_notify_func2 = runtime->ctx->notify_func2;
  void *previous_notify_baton2 = runtime->ctx->notify_baton2;
  svn_client_get_commit_log3_t previous_log_msg_func3 = runtime->ctx->log_msg_func3;
  void *previous_log_msg_baton3 = runtime->ctx->log_msg_baton3;
  bridge_cancel_baton cancel_baton = { 0 };
  cancel_baton.callbacks = cancel_callbacks;
  svn_cancel_func_t previous_cancel_func = runtime->ctx->cancel_func;
  void *previous_cancel_baton = runtime->ctx->cancel_baton;
  runtime->ctx->notify_func2 = bridge_operation_notify;
  runtime->ctx->notify_baton2 = &notify_baton;
  runtime->ctx->log_msg_func3 = bridge_commit_log_message;
  runtime->ctx->log_msg_baton3 = &log_baton;
  runtime->ctx->cancel_func = bridge_cancel_check;
  runtime->ctx->cancel_baton = &cancel_baton;

  svn_error_t *err = svn_client_commit6(
    local_paths,
    commit_depth,
    keep_locks ? TRUE : FALSE,
    keep_changelists ? TRUE : FALSE,
    commit_as_operations ? TRUE : FALSE,
    include_file_externals ? TRUE : FALSE,
    include_dir_externals ? TRUE : FALSE,
    commit_changelists,
    NULL,
    bridge_commit_callback,
    &commit_baton,
    runtime->ctx,
    runtime->result_pool
  );

  runtime->ctx->notify_func2 = previous_notify_func2;
  runtime->ctx->notify_baton2 = previous_notify_baton2;
  runtime->ctx->log_msg_func3 = previous_log_msg_func3;
  runtime->ctx->log_msg_baton3 = previous_log_msg_baton3;
  runtime->ctx->cancel_func = previous_cancel_func;
  runtime->ctx->cancel_baton = previous_cancel_baton;

  if (err != NULL) {
    return bridge_error_status_with_cancellation(
      runtime,
      err,
      &cancel_baton,
      BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED,
      BRIDGE_OPERATION_CANCELLED
    );
  }

  if (!SVN_IS_VALID_REVNUM(commit_baton.revision)) {
    return 9;
  }
  *result_revision = bridge_revision_to_i64(commit_baton.revision);

  if (touched_paths->nelts == 0) {
    for (int index = 0; index < local_paths->nelts; index++) {
      const char *local_abspath = APR_ARRAY_IDX(local_paths, index, const char *);
      APR_ARRAY_PUSH(touched_paths, const char *) = apr_pstrdup(runtime->result_pool, local_abspath);
    }
  }

  result->touched_paths = (const char *const *)touched_paths->elts;
  result->touched_path_count = (size_t)touched_paths->nelts;
  result->skipped_paths = (const char *const *)skipped_paths->elts;
  result->skipped_path_count = (size_t)skipped_paths->nelts;
  return 0;
}

int subversionr_bridge_operation_commit_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *message,
  const char *depth,
  const char *const *changelists,
  size_t changelist_count,
  int keep_locks,
  int keep_changelists,
  int commit_as_operations,
  int include_file_externals,
  int include_dir_externals,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result,
  long long *result_revision
) {
  bridge_prepare_call(runtime);

  if (
    runtime == NULL ||
    paths == NULL ||
    path_count == 0 ||
    message == NULL ||
    depth == NULL ||
    result == NULL ||
    result_revision == NULL ||
    !bridge_auth_callbacks_valid(callbacks) ||
    cancel_callbacks == NULL
  ) {
    return 1;
  }
  if (!bridge_cancel_callbacks_valid(cancel_callbacks)) {
    return BRIDGE_OPERATION_CANCEL_CALLBACK_FAILED;
  }

  apr_pool_t *auth_pool = NULL;
  if (apr_pool_create(&auth_pool, runtime->pool) != APR_SUCCESS) {
    return 10;
  }

  bridge_auth_prompt_baton *prompt_baton =
    apr_pcalloc(auth_pool, sizeof(*prompt_baton));
  prompt_baton->callbacks = *callbacks;
  prompt_baton->working_copy_root = paths[0] != NULL ? apr_pstrdup(auth_pool, paths[0]) : NULL;
  prompt_baton->callback_failed = 0;

  svn_auth_baton_t *auth_baton = NULL;
  svn_error_t *err = bridge_create_auth_baton(
    &auth_baton,
    prompt_baton,
    0,
    auth_pool
  );
  if (err != NULL) {
    bridge_capture_error(runtime, err);
    svn_error_clear(err);
    apr_pool_destroy(auth_pool);
    return 10;
  }

  svn_auth_baton_t *previous_auth_baton = runtime->ctx->auth_baton;
  runtime->ctx->auth_baton = auth_baton;
  int status = bridge_operation_commit_impl(
    runtime,
    paths,
    path_count,
    message,
    depth,
    changelists,
    changelist_count,
    keep_locks,
    keep_changelists,
    commit_as_operations,
    include_file_externals,
    include_dir_externals,
    cancel_callbacks,
    result,
    result_revision
  );
  runtime->ctx->auth_baton = previous_auth_baton;

  int callback_failed = prompt_baton->callback_failed;
  apr_pool_destroy(auth_pool);

  if (status != 0 && callback_failed) {
    return 10;
  }
  return status;
}
