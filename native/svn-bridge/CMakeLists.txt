cmake_minimum_required(VERSION 4.3)
project(subversionr_svn_bridge LANGUAGES C)

if(NOT DEFINED SVN_ROOT)
  message(FATAL_ERROR "SVN_ROOT is required and must point to the verified Apache Subversion install prefix.")
endif()

find_path(SVN_INCLUDE_DIR svn_client.h PATHS "${SVN_ROOT}/include/subversion-1" NO_DEFAULT_PATH REQUIRED)
find_path(APR_INCLUDE_DIR apr_pools.h PATHS "${SVN_ROOT}/include/apr-1" "${SVN_ROOT}/include/apr-1.0" "${SVN_ROOT}/include" NO_DEFAULT_PATH REQUIRED)
find_library(SVN_CLIENT_LIBRARY NAMES libsvn_client-1 PATHS "${SVN_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(SVN_RA_LIBRARY NAMES libsvn_ra-1 PATHS "${SVN_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(SVN_WC_LIBRARY NAMES libsvn_wc-1 PATHS "${SVN_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(SVN_DIFF_LIBRARY NAMES libsvn_diff-1 PATHS "${SVN_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(SVN_SUBR_LIBRARY NAMES libsvn_subr-1 PATHS "${SVN_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(APR_LIBRARY NAMES libapr-1 apr-1 PATHS "${SVN_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)
find_library(APR_UTIL_LIBRARY NAMES libaprutil-1 aprutil-1 PATHS "${SVN_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)

add_library(subversionr_svn_bridge SHARED src/subversionr_bridge.c)
target_include_directories(subversionr_svn_bridge PRIVATE include "${SVN_INCLUDE_DIR}" "${APR_INCLUDE_DIR}")
target_link_libraries(
  subversionr_svn_bridge
  PRIVATE
    "${SVN_CLIENT_LIBRARY}"
    "${SVN_RA_LIBRARY}"
    "${SVN_WC_LIBRARY}"
    "${SVN_DIFF_LIBRARY}"
    "${SVN_SUBR_LIBRARY}"
    "${APR_LIBRARY}"
    "${APR_UTIL_LIBRARY}"
)
target_compile_definitions(subversionr_svn_bridge PRIVATE SUBVERSIONR_SVN_BRIDGE_EXPORTS)
if(MSVC)
  target_link_options(subversionr_svn_bridge PRIVATE "$<$<CONFIG:Release>:/Brepro>")
endif()
