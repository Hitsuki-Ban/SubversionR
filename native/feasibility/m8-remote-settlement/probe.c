#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <apr_general.h>
#include <apr_hash.h>
#include <apr_pools.h>
#include <apr_tables.h>

#include <svn_auth.h>
#include <svn_client.h>
#include <svn_config.h>
#include <svn_dso.h>
#include <svn_error.h>
#include <svn_pools.h>
#include <svn_ra.h>
#include <svn_types.h>

#define PROBE_MAX_CREDENTIALS 2
#define PROBE_MAX_ERROR_CODES 8

typedef enum probe_mode_t
{
  PROBE_MODE_UNSET = 0,
  PROBE_MODE_CRAM,
  PROBE_MODE_BASIC,
  PROBE_MODE_RA_OPEN
} probe_mode_t;

typedef struct credential_input_t
{
  const char *username;
  const char *password;
} credential_input_t;

typedef struct probe_options_t
{
  probe_mode_t mode;
  const char *mode_name;
  const char *url;
  credential_input_t credentials[PROBE_MAX_CREDENTIALS];
  int credential_count;
  svn_boolean_t trust_enabled;
  apr_uint32_t accepted_tls_failures;
  const char *post_open_check_path;
} probe_options_t;

typedef struct simple_iter_baton_t
{
  probe_options_t *options;
  int next_slot;
} simple_iter_baton_t;

typedef struct simple_credential_t
{
  svn_auth_cred_simple_t credential;
  int slot;
} simple_credential_t;

static void
emit_provider_event(const char *event,
                    const char *kind,
                    int slot,
                    svn_boolean_t available)
{
  if (slot >= 0)
    printf("{\"event\":\"%s\",\"kind\":\"%s\",\"slot\":%d,\"available\":%s}\n",
           event, kind, slot, available ? "true" : "false");
  else
    printf("{\"event\":\"%s\",\"kind\":\"%s\",\"available\":%s}\n",
           event, kind, available ? "true" : "false");
  fflush(stdout);
}

static void
emit_simple_save(int slot)
{
  printf("{\"event\":\"provider.save\",\"kind\":\"simple\",\"slot\":%d}\n",
         slot);
  fflush(stdout);
}

static void
emit_ra_failure(const svn_error_t *error)
{
  const svn_error_t *current = error;
  int count = 0;

  printf("{\"event\":\"ra.failed\",\"svnErrorCodes\":[");
  while (current != NULL && count < PROBE_MAX_ERROR_CODES)
    {
      if (count != 0)
        printf(",");
      printf("%ld", (long)current->apr_err);
      current = current->child;
      count += 1;
    }
  printf("],\"truncated\":%s}\n", current == NULL ? "false" : "true");
  fflush(stdout);
}

static svn_error_t *
make_simple_credential(void **credentials,
                       probe_options_t *options,
                       int slot,
                       apr_pool_t *pool)
{
  simple_credential_t *wrapped;

  if (slot < 0 || slot >= options->credential_count)
    {
      *credentials = NULL;
      return SVN_NO_ERROR;
    }

  wrapped = apr_pcalloc(pool, sizeof(*wrapped));
  wrapped->credential.username = apr_pstrdup(
      pool, options->credentials[slot].username);
  wrapped->credential.password = apr_pstrdup(
      pool, options->credentials[slot].password);
  wrapped->credential.may_save = TRUE;
  wrapped->slot = slot;
  *credentials = &wrapped->credential;
  return SVN_NO_ERROR;
}

static svn_error_t *
simple_first_credentials(void **credentials,
                         void **iter_baton,
                         void *provider_baton,
                         apr_hash_t *parameters,
                         const char *realmstring,
                         apr_pool_t *pool)
{
  probe_options_t *options = provider_baton;
  simple_iter_baton_t *iterator;

  (void)parameters;
  (void)realmstring;

  iterator = apr_pcalloc(pool, sizeof(*iterator));
  iterator->options = options;
  iterator->next_slot = 1;
  *iter_baton = iterator;

  if (options->credential_count == 0)
    {
      *credentials = NULL;
      emit_provider_event("provider.first", "simple", -1, FALSE);
      return SVN_NO_ERROR;
    }

  emit_provider_event("provider.first", "simple", 0, TRUE);
  return make_simple_credential(credentials, options, 0, pool);
}

static svn_error_t *
simple_next_credentials(void **credentials,
                        void *iter_baton,
                        void *provider_baton,
                        apr_hash_t *parameters,
                        const char *realmstring,
                        apr_pool_t *pool)
{
  simple_iter_baton_t *iterator = iter_baton;
  int slot;

  (void)provider_baton;
  (void)parameters;
  (void)realmstring;

  slot = iterator->next_slot;
  iterator->next_slot += 1;
  if (slot >= iterator->options->credential_count)
    {
      *credentials = NULL;
      emit_provider_event("provider.next", "simple", -1, FALSE);
      return SVN_NO_ERROR;
    }

  emit_provider_event("provider.next", "simple", slot, TRUE);
  return make_simple_credential(credentials, iterator->options, slot, pool);
}

static svn_error_t *
simple_save_credentials(svn_boolean_t *saved,
                        void *credentials,
                        void *provider_baton,
                        apr_hash_t *parameters,
                        const char *realmstring,
                        apr_pool_t *pool)
{
  simple_credential_t *wrapped = credentials;

  (void)provider_baton;
  (void)parameters;
  (void)realmstring;
  (void)pool;

  emit_simple_save(wrapped->slot);
  *saved = TRUE;
  return SVN_NO_ERROR;
}

static svn_error_t *
trust_first_credentials(void **credentials,
                        void **iter_baton,
                        void *provider_baton,
                        apr_hash_t *parameters,
                        const char *realmstring,
                        apr_pool_t *pool)
{
  probe_options_t *options = provider_baton;
  apr_uint32_t *failures;
  svn_auth_cred_ssl_server_trust_t *credential;

  (void)realmstring;

  *iter_baton = NULL;
  failures = apr_hash_get(parameters,
                          SVN_AUTH_PARAM_SSL_SERVER_FAILURES,
                          APR_HASH_KEY_STRING);
  if (failures == NULL)
    return svn_error_create(SVN_ERR_AUTHN_FAILED, NULL,
                            "TLS trust provider was invoked without a failure mask");

  if (!options->trust_enabled ||
      (*failures & ~options->accepted_tls_failures) != 0)
    {
      *credentials = NULL;
      emit_provider_event("provider.first", "ssl-server-trust", -1, FALSE);
      return SVN_NO_ERROR;
    }

  credential = apr_pcalloc(pool, sizeof(*credential));
  credential->may_save = TRUE;
  credential->accepted_failures = *failures;
  *credentials = credential;
  emit_provider_event("provider.first", "ssl-server-trust", -1, TRUE);
  return SVN_NO_ERROR;
}

static svn_error_t *
trust_save_credentials(svn_boolean_t *saved,
                       void *credentials,
                       void *provider_baton,
                       apr_hash_t *parameters,
                       const char *realmstring,
                       apr_pool_t *pool)
{
  (void)credentials;
  (void)provider_baton;
  (void)parameters;
  (void)realmstring;
  (void)pool;

  printf("{\"event\":\"provider.save\",\"kind\":\"ssl-server-trust\"}\n");
  fflush(stdout);
  *saved = TRUE;
  return SVN_NO_ERROR;
}

static const svn_auth_provider_t simple_provider_vtable = {
  SVN_AUTH_CRED_SIMPLE,
  simple_first_credentials,
  simple_next_credentials,
  simple_save_credentials
};

static const svn_auth_provider_t trust_provider_vtable = {
  SVN_AUTH_CRED_SSL_SERVER_TRUST,
  trust_first_credentials,
  NULL,
  trust_save_credentials
};

static svn_boolean_t
starts_with(const char *value, const char *prefix)
{
  size_t prefix_length = strlen(prefix);
  return strncmp(value, prefix, prefix_length) == 0;
}

static svn_boolean_t
is_credential_environment_name(const char *value)
{
  const char *prefix = "SUBVERSIONR_M8_";
  const char *current;

  if (!starts_with(value, prefix))
    return FALSE;

  current = value + strlen(prefix);
  if (*current == '\0')
    return FALSE;

  while (*current != '\0')
    {
      if (!((*current >= 'A' && *current <= 'Z') ||
            (*current >= '0' && *current <= '9') ||
            *current == '_'))
        return FALSE;
      current += 1;
    }

  return TRUE;
}

static svn_boolean_t
url_has_userinfo_or_control(const char *url)
{
  const char *current;
  const char *authority;

  for (current = url; *current != '\0'; ++current)
    if (iscntrl((unsigned char)*current))
      return TRUE;

  authority = strstr(url, "://");
  if (authority == NULL)
    return FALSE;
  authority += 3;
  for (current = authority;
       *current != '\0' && *current != '/' && *current != '?' &&
       *current != '#';
       ++current)
    if (*current == '@')
      return TRUE;

  return FALSE;
}

static svn_boolean_t
is_safe_relative_probe_path(const char *path)
{
  const char *current;

  if (path[0] == '\0' || path[0] == '/' || path[0] == '\\' ||
      strlen(path) > 256)
    return FALSE;
  for (current = path; *current != '\0'; ++current)
    if (iscntrl((unsigned char)*current) || *current == '\\')
      return FALSE;
  if (strcmp(path, "..") == 0 || starts_with(path, "../") ||
      strstr(path, "/../") != NULL ||
      (strlen(path) >= 3 && strcmp(path + strlen(path) - 3, "/..") == 0))
    return FALSE;
  return TRUE;
}

static svn_boolean_t
parse_uint32(const char *value, apr_uint32_t *parsed)
{
  char *end = NULL;
  unsigned long result;

  if (value[0] == '\0' || value[0] == '-')
    return FALSE;

  errno = 0;
  result = strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || result == 0 ||
      result > UINT_MAX)
    return FALSE;

  *parsed = (apr_uint32_t)result;
  return TRUE;
}

static void
print_usage(void)
{
  fprintf(stderr,
          "usage: m8_remote_settlement_probe --mode cram|basic|ra-open "
          "--url URL [--credential-env USER ENV_NAME] "
          "[--credential-env USER ENV_NAME] [--accept-tls-failures MASK] "
          "[--post-open-check-path RELPATH]\n");
}

static svn_boolean_t
parse_options(int argc, const char *const *argv, probe_options_t *options)
{
  int index;
  svn_boolean_t mode_seen = FALSE;
  svn_boolean_t url_seen = FALSE;

  memset(options, 0, sizeof(*options));
  for (index = 1; index < argc; ++index)
    {
      if (strcmp(argv[index], "--mode") == 0)
        {
          if (mode_seen || index + 1 >= argc)
            return FALSE;
          mode_seen = TRUE;
          options->mode_name = argv[++index];
          if (strcmp(options->mode_name, "cram") == 0)
            options->mode = PROBE_MODE_CRAM;
          else if (strcmp(options->mode_name, "basic") == 0)
            options->mode = PROBE_MODE_BASIC;
          else if (strcmp(options->mode_name, "ra-open") == 0)
            options->mode = PROBE_MODE_RA_OPEN;
          else
            return FALSE;
        }
      else if (strcmp(argv[index], "--url") == 0)
        {
          if (url_seen || index + 1 >= argc)
            return FALSE;
          url_seen = TRUE;
          options->url = argv[++index];
        }
      else if (strcmp(argv[index], "--credential-env") == 0)
        {
          int slot = options->credential_count;
          const char *environment_name;
          const char *password;

          if (slot >= PROBE_MAX_CREDENTIALS || index + 2 >= argc)
            return FALSE;
          options->credentials[slot].username = argv[++index];
          environment_name = argv[++index];
          if (options->credentials[slot].username[0] == '\0')
            return FALSE;
          if (!is_credential_environment_name(environment_name))
            return FALSE;
          password = getenv(environment_name);
          if (password == NULL || password[0] == '\0')
            return FALSE;
          options->credentials[slot].password = password;
          options->credential_count += 1;
        }
      else if (strcmp(argv[index], "--accept-tls-failures") == 0)
        {
          if (options->trust_enabled || index + 1 >= argc)
            return FALSE;
          options->trust_enabled = TRUE;
          if (!parse_uint32(argv[++index], &options->accepted_tls_failures))
            return FALSE;
        }
      else if (strcmp(argv[index], "--post-open-check-path") == 0)
        {
          if (options->post_open_check_path != NULL || index + 1 >= argc)
            return FALSE;
          options->post_open_check_path = argv[++index];
          if (!is_safe_relative_probe_path(options->post_open_check_path))
            return FALSE;
        }
      else
        return FALSE;
    }

  if (!mode_seen || !url_seen || options->url[0] == '\0' ||
      url_has_userinfo_or_control(options->url))
    return FALSE;

  if ((options->mode == PROBE_MODE_CRAM ||
       options->mode == PROBE_MODE_BASIC) &&
      options->credential_count == 0)
    return FALSE;

  if (options->mode == PROBE_MODE_CRAM)
    {
      if (!starts_with(options->url, "svn://") || options->trust_enabled)
        return FALSE;
    }
  else if (options->mode == PROBE_MODE_BASIC)
    {
      if (!starts_with(options->url, "http://") &&
          !starts_with(options->url, "https://"))
        return FALSE;
    }
  else if (!starts_with(options->url, "svn://") &&
           !starts_with(options->url, "http://") &&
           !starts_with(options->url, "https://"))
    return FALSE;

  if (options->trust_enabled && !starts_with(options->url, "https://"))
    return FALSE;

  return TRUE;
}

static svn_error_t *
create_empty_config(apr_hash_t **config_hash,
                    probe_options_t *options,
                    apr_pool_t *pool)
{
  svn_config_t *config;
  svn_config_t *servers;

  *config_hash = apr_hash_make(pool);
  SVN_ERR(svn_config_create2(&config, FALSE, FALSE, pool));
  SVN_ERR(svn_config_create2(&servers, FALSE, FALSE, pool));
  svn_config_set(config, SVN_CONFIG_SECTION_AUTH,
                 SVN_CONFIG_OPTION_STORE_AUTH_CREDS, SVN_CONFIG_FALSE);
  svn_config_set(config, SVN_CONFIG_SECTION_AUTH,
                 SVN_CONFIG_OPTION_STORE_PASSWORDS, SVN_CONFIG_FALSE);
  if (options->mode == PROBE_MODE_BASIC)
    svn_config_set(servers, SVN_CONFIG_SECTION_GLOBAL,
                   SVN_CONFIG_OPTION_HTTP_AUTH_TYPES, "basic");

  apr_hash_set(*config_hash, SVN_CONFIG_CATEGORY_CONFIG,
               APR_HASH_KEY_STRING, config);
  apr_hash_set(*config_hash, SVN_CONFIG_CATEGORY_SERVERS,
               APR_HASH_KEY_STRING, servers);
  return SVN_NO_ERROR;
}

static svn_error_t *
run_probe(probe_options_t *options, apr_pool_t *pool)
{
  apr_array_header_t *providers;
  apr_hash_t *config_hash;
  svn_auth_baton_t *auth_baton;
  svn_auth_provider_object_t *simple_provider;
  svn_auth_provider_object_t *trust_provider;
  svn_client_ctx_t *context;
  svn_ra_session_t *session;

  SVN_ERR(create_empty_config(&config_hash, options, pool));

  providers = apr_array_make(pool, 2,
                             sizeof(svn_auth_provider_object_t *));
  simple_provider = apr_pcalloc(pool, sizeof(*simple_provider));
  simple_provider->vtable = &simple_provider_vtable;
  simple_provider->provider_baton = options;
  APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = simple_provider;

  trust_provider = apr_pcalloc(pool, sizeof(*trust_provider));
  trust_provider->vtable = &trust_provider_vtable;
  trust_provider->provider_baton = options;
  APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = trust_provider;

  svn_auth_open(&auth_baton, providers, pool);
  SVN_ERR(svn_client_create_context2(&context, config_hash, pool));
  context->auth_baton = auth_baton;

  SVN_ERR(svn_client_open_ra_session2(&session, options->url, NULL,
                                      context, pool, pool));
  printf("{\"event\":\"ra.opened\",\"mode\":\"%s\"}\n",
         options->mode_name);
  fflush(stdout);

  if (options->post_open_check_path != NULL)
    {
      svn_node_kind_t kind;
      const char *kind_name;

      SVN_ERR(svn_ra_check_path(session, options->post_open_check_path,
                                SVN_INVALID_REVNUM, &kind, pool));
      switch (kind)
        {
          case svn_node_none:
            kind_name = "none";
            break;
          case svn_node_file:
            kind_name = "file";
            break;
          case svn_node_dir:
            kind_name = "dir";
            break;
          default:
            kind_name = "unknown";
            break;
        }
      printf("{\"event\":\"ra.check-path\",\"kind\":\"%s\"}\n",
             kind_name);
      fflush(stdout);
    }
  return SVN_NO_ERROR;
}

int
main(int argc, char **argv)
{
  probe_options_t options;
  apr_status_t apr_status;
  apr_pool_t *pool;
  svn_error_t *error;

  if (!parse_options(argc, argv, &options))
    {
      print_usage();
      return 2;
    }

  printf("{\"event\":\"probe.started\",\"mode\":\"%s\"}\n",
         options.mode_name);
  fflush(stdout);

  apr_status = apr_initialize();
  if (apr_status != APR_SUCCESS)
    {
      fprintf(stderr, "APR initialization failed with status %ld.\n",
              (long)apr_status);
      return 3;
    }

  pool = svn_pool_create(NULL);
  error = svn_dso_initialize2();
  if (error == SVN_NO_ERROR)
    error = svn_ra_initialize(pool);
  if (error == SVN_NO_ERROR)
    error = run_probe(&options, pool);

  if (error != SVN_NO_ERROR)
    {
      emit_ra_failure(error);
      svn_error_clear(error);
      svn_pool_destroy(pool);
      apr_terminate();
      return 1;
    }

  printf("{\"event\":\"probe.completed\"}\n");
  fflush(stdout);
  svn_pool_destroy(pool);
  apr_terminate();
  return 0;
}
