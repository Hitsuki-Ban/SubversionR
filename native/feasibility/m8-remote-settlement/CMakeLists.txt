cmake_minimum_required(VERSION 4.3)
project(subversionr_m8_remote_settlement_probe LANGUAGES C)

if(NOT DEFINED SVN_ROOT)
  message(FATAL_ERROR "SVN_ROOT is required and must point to the verified Apache Subversion stage.")
endif()

find_path(
  SVN_INCLUDE_DIR
  svn_client.h
  PATHS "${SVN_ROOT}/include/subversion-1"
  NO_DEFAULT_PATH
  REQUIRED
)
find_path(
  APR_INCLUDE_DIR
  apr_pools.h
  PATHS "${SVN_ROOT}/include"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(
  SVN_CLIENT_LIBRARY
  NAMES libsvn_client-1
  PATHS "${SVN_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(
  SVN_RA_LIBRARY
  NAMES libsvn_ra-1
  PATHS "${SVN_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(
  SVN_SUBR_LIBRARY
  NAMES libsvn_subr-1
  PATHS "${SVN_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(
  APR_LIBRARY
  NAMES libapr-1 apr-1
  PATHS "${SVN_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED
)

add_executable(m8_remote_settlement_probe probe.c)
target_compile_features(m8_remote_settlement_probe PRIVATE c_std_11)
target_include_directories(
  m8_remote_settlement_probe
  PRIVATE
    "${SVN_INCLUDE_DIR}"
    "${APR_INCLUDE_DIR}"
)
target_link_libraries(
  m8_remote_settlement_probe
  PRIVATE
    "${SVN_CLIENT_LIBRARY}"
    "${SVN_RA_LIBRARY}"
    "${SVN_SUBR_LIBRARY}"
    "${APR_LIBRARY}"
)

if(MSVC)
  target_compile_options(m8_remote_settlement_probe PRIVATE /utf-8 /W4 /WX)
endif()
