# Local build customizations, auto-included by the top-level CMakeLists.txt
# if this file exists. See the `include()` guard near the top of that file.
#
# Nothing here is specific to any one fork's tuning goals -- this is a
# generic drop point for build-time customizations that shouldn't require
# editing CMakeLists.txt itself.

# Refuse in-source builds. An in-source `cmake .` (or `cmake -S . -B .`)
# scatters CMakeFiles/, Makefiles, cmake_install.cmake, etc. throughout the
# tracked source tree instead of an out-of-tree build directory.
if (CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    message(FATAL_ERROR
        "In-source builds are not allowed. Configure into a separate "
        "directory instead, e.g.: cmake -S . -B build")
endif()
