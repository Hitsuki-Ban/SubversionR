#ifndef SUBVERSIONR_BRIDGE_H
#define SUBVERSIONR_BRIDGE_H

#ifdef _WIN32
#ifdef SUBVERSIONR_SVN_BRIDGE_EXPORTS
#define SUBVERSIONR_BRIDGE_API __declspec(dllexport)
#else
#define SUBVERSIONR_BRIDGE_API __declspec(dllimport)
#endif
#else
#define SUBVERSIONR_BRIDGE_API
#endif

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct subversionr_bridge_runtime subversionr_bridge_runtime;

enum {
  SUBVERSIONR_BRIDGE_AUTH_ABI_VERSION = 1
};

enum {
  SUBVERSIONR_BRIDGE_CANCEL_ABI_VERSION = 1
};

enum {
  SUBVERSIONR_BRIDGE_CANCEL_CALLBACK_CONTINUE = 0,
  SUBVERSIONR_BRIDGE_CANCEL_CALLBACK_CANCEL = 1,
  SUBVERSIONR_BRIDGE_CANCEL_CALLBACK_INVALID = 2
};

typedef struct subversionr_bridge_version_info {
  int major;
  int minor;
  int patch;
  const char *display;
} subversionr_bridge_version_info;

typedef struct subversionr_bridge_wc_info {
  const char *repository_uuid;
  const char *repository_root_url;
  const char *working_copy_root;
  int format;
} subversionr_bridge_wc_info;

typedef struct subversionr_bridge_credential_request {
  const char *realm;
  const char *username;
  int may_save;
  const char *working_copy_root;
} subversionr_bridge_credential_request;

typedef struct subversionr_bridge_credential_response {
  const char *username;
  const char *secret;
  int may_save;
} subversionr_bridge_credential_response;

typedef struct subversionr_bridge_certificate_request {
  const char *realm;
  const char *host;
  const char *ascii_cert;
  const char *valid_from;
  const char *valid_to;
  const char *issuer;
  /* ABI v1 leaves this NULL; consumers derive identity from ascii_cert. */
  const char *subject;
  unsigned int failures;
  int may_save;
  const char *working_copy_root;
} subversionr_bridge_certificate_request;

typedef struct subversionr_bridge_certificate_response {
  unsigned int accepted_failures;
  int may_save;
} subversionr_bridge_certificate_response;

typedef int (*subversionr_bridge_credential_callback)(
  void *baton,
  const subversionr_bridge_credential_request *request,
  subversionr_bridge_credential_response *response
);

typedef void (*subversionr_bridge_credential_response_dispose)(
  void *baton,
  subversionr_bridge_credential_response *response
);

typedef int (*subversionr_bridge_certificate_callback)(
  void *baton,
  const subversionr_bridge_certificate_request *request,
  subversionr_bridge_certificate_response *response
);

typedef struct subversionr_bridge_auth_callbacks {
  unsigned int abi_version;
  void *baton;
  subversionr_bridge_credential_callback credential_callback;
  subversionr_bridge_credential_response_dispose credential_response_dispose;
  subversionr_bridge_certificate_callback certificate_callback;
} subversionr_bridge_auth_callbacks;

typedef int (*subversionr_bridge_cancel_callback)(void *baton);

typedef struct subversionr_bridge_cancel_callbacks {
  unsigned int abi_version;
  void *baton;
  subversionr_bridge_cancel_callback cancel_callback;
} subversionr_bridge_cancel_callbacks;

typedef struct subversionr_bridge_lock_info {
  const char *token;
  const char *owner;
  const char *comment;
  const char *created_date;
  const char *expires_date;
  int is_remote;
} subversionr_bridge_lock_info;

typedef struct subversionr_bridge_status_entry {
  const char *path;
  const char *kind;
  const char *node_status;
  const char *text_status;
  const char *property_status;
  const char *repos_node_status;
  const char *repos_text_status;
  const char *repos_property_status;
  const char *repos_kind;
  long long repos_changed_revision;
  const char *repos_changed_author;
  const char *repos_changed_date;
  long long revision;
  long long changed_revision;
  const char *changed_author;
  const char *changed_date;
  const char *changelist;
  const subversionr_bridge_lock_info *lock;
  const subversionr_bridge_lock_info *repos_lock;
  int needs_lock;
  const char *depth;
  int conflicted;
  int switched;
  int external;
  int copied;
  const char *copy_from_path;
  long long copy_from_revision;
  const char *moved_from_abspath;
} subversionr_bridge_status_entry;

typedef struct subversionr_bridge_status_scan_info {
  const subversionr_bridge_status_entry *entries;
  size_t entry_count;
} subversionr_bridge_status_scan_info;

/* Pointers returned in this struct are owned by the runtime result pool and
   remain valid only until the next bridge call that clears that pool. */
typedef struct subversionr_bridge_content_info {
  const unsigned char *data;
  size_t byte_count;
  const char *mime_type;
  int is_binary;
} subversionr_bridge_content_info;

typedef struct subversionr_bridge_property_entry {
  const char *name;
  const char *value;
  const char *value_encoding;
} subversionr_bridge_property_entry;

/* Pointers returned in this struct are owned by the runtime result pool and
   remain valid only until the next bridge call that clears that pool. */
typedef struct subversionr_bridge_property_list {
  const subversionr_bridge_property_entry *entries;
  size_t entry_count;
} subversionr_bridge_property_list;

typedef struct subversionr_bridge_log_changed_path {
  const char *path;
  const char *action;
  const char *copy_from_path;
  long long copy_from_revision;
  const char *node_kind;
  const char *text_modified;
  const char *properties_modified;
} subversionr_bridge_log_changed_path;

typedef struct subversionr_bridge_log_entry {
  long long revision;
  const char *author;
  const char *date;
  const char *message;
  const subversionr_bridge_log_changed_path *changed_paths;
  size_t changed_path_count;
  int has_children;
  int non_inheritable;
  int subtractive_merge;
} subversionr_bridge_log_entry;

/* Pointers returned in this struct are owned by the runtime result pool and
   remain valid only until the next bridge call that clears that pool. */
typedef struct subversionr_bridge_log_info {
  const subversionr_bridge_log_entry *entries;
  size_t entry_count;
} subversionr_bridge_log_info;

typedef struct subversionr_bridge_blame_line {
  long long line_number;
  long long revision;
  const char *author;
  const char *date;
  long long merged_revision;
  const char *merged_author;
  const char *merged_date;
  const char *merged_path;
  const unsigned char *line_data;
  size_t line_byte_count;
  int local_change;
} subversionr_bridge_blame_line;

/* Pointers returned in this struct are owned by the runtime result pool and
   remain valid only until the next bridge call that clears that pool. */
typedef struct subversionr_bridge_blame_info {
  long long resolved_start_revision;
  long long resolved_end_revision;
  const subversionr_bridge_blame_line *lines;
  size_t line_count;
  int has_more;
} subversionr_bridge_blame_info;

/* Pointers returned in this struct are owned by the runtime result pool and
   remain valid only until the next bridge call that clears that pool. */
typedef struct subversionr_bridge_operation_result {
  const char *const *touched_paths;
  size_t touched_path_count;
  const char *const *skipped_paths;
  size_t skipped_path_count;
} subversionr_bridge_operation_result;

SUBVERSIONR_BRIDGE_API int subversionr_bridge_runtime_create(subversionr_bridge_runtime **runtime);
SUBVERSIONR_BRIDGE_API void subversionr_bridge_runtime_destroy(subversionr_bridge_runtime *runtime);
SUBVERSIONR_BRIDGE_API subversionr_bridge_version_info subversionr_bridge_version(void);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_open_working_copy(
  subversionr_bridge_runtime *runtime,
  const char *path,
  subversionr_bridge_wc_info *info
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_open_working_copy_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const subversionr_bridge_auth_callbacks *callbacks,
  subversionr_bridge_wc_info *info
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_probe_remote_url_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *url,
  const subversionr_bridge_auth_callbacks *callbacks
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_status_scan(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *depth,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_status_scan_info *snapshot
);

SUBVERSIONR_BRIDGE_API int subversionr_bridge_status_remote_scan_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const subversionr_bridge_auth_callbacks *auth_callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_status_scan_info *snapshot
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_content_get_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *revision,
  const subversionr_bridge_auth_callbacks *callbacks,
  subversionr_bridge_content_info *content
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_properties_list(
  subversionr_bridge_runtime *runtime,
  const char *path,
  subversionr_bridge_property_list *properties
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_history_log_with_auth(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_history_blame_with_auth(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_revert(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_add(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_remove(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  int force,
  int keep_local,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_move(
  subversionr_bridge_runtime *runtime,
  const char *source_path,
  const char *destination_path,
  int make_parents,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_resolve(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *choice,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_cleanup(
  subversionr_bridge_runtime *runtime,
  const char *path,
  int break_locks,
  int fix_recorded_timestamps,
  int clear_dav_cache,
  int vacuum_pristines,
  int include_externals,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_upgrade(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_update(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_repository_checkout_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *url,
  const char *target_path,
  const char *revision,
  const char *depth,
  int ignore_externals,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  long long *result_revision
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_property_set(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *name,
  const char *value,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_property_delete(
  subversionr_bridge_runtime *runtime,
  const char *path,
  const char *name,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_changelist_set(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *changelist,
  const char *const *changelists,
  size_t changelist_count,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_changelist_clear(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *depth,
  const char *const *changelists,
  size_t changelist_count,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_lock_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  const char *comment,
  int steal_lock,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_unlock_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *const *paths,
  size_t path_count,
  int break_lock,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_branch_create_with_auth(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_switch_with_auth(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_relocate_with_auth(
  subversionr_bridge_runtime *runtime,
  const char *working_copy_root,
  const char *from_prefix,
  const char *to_prefix,
  int ignore_externals,
  const subversionr_bridge_auth_callbacks *callbacks,
  const subversionr_bridge_cancel_callbacks *cancel_callbacks,
  subversionr_bridge_operation_result *result
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_merge_range_with_auth(
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
);
SUBVERSIONR_BRIDGE_API int subversionr_bridge_operation_commit_with_auth(
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
);

#ifdef __cplusplus
}
#endif

#endif
