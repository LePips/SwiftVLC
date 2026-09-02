cmake_minimum_required(VERSION 3.16)

foreach(required_variable CMAKE_ASM_NASM_COMPILER AOM_TARGET_CPU AOM_TARGET_SYSTEM)
  if(NOT DEFINED ${required_variable} OR "${${required_variable}}" STREQUAL "")
    message(FATAL_ERROR "Missing required probe input: ${required_variable}")
  endif()
endforeach()

# Copied verbatim from libaom v3.13.2's aom_optimization.cmake. Keeping the
# consumer logic here lets the source contract exercise NASM 3's split help
# topics without configuring or compiling the full dependency.
function(test_nasm)
  execute_process(COMMAND ${CMAKE_ASM_NASM_COMPILER} -hO
                  OUTPUT_VARIABLE nasm_helptext)

  if(NOT "${nasm_helptext}" MATCHES "-Ox")
    message(
      FATAL_ERROR "Unsupported nasm: multipass optimization not supported.")
  endif()

  execute_process(COMMAND ${CMAKE_ASM_NASM_COMPILER} -hf
                  OUTPUT_VARIABLE nasm_helptext)
  if("${AOM_TARGET_CPU}" STREQUAL "x86")
    if("${AOM_TARGET_SYSTEM}" STREQUAL "Darwin")
      if(NOT "${nasm_helptext}" MATCHES "macho32")
        message(
          FATAL_ERROR "Unsupported nasm: macho32 object format not supported.")
      endif()
    elseif("${AOM_TARGET_SYSTEM}" STREQUAL "MSYS"
           OR "${AOM_TARGET_SYSTEM}" STREQUAL "Windows")
      if(NOT "${nasm_helptext}" MATCHES "win32")
        message(
          FATAL_ERROR "Unsupported nasm: win32 object format not supported.")
      endif()
    else()
      if(NOT "${nasm_helptext}" MATCHES "elf32")
        message(
          FATAL_ERROR "Unsupported nasm: elf32 object format not supported.")
      endif()
    endif()
  else()
    if("${AOM_TARGET_SYSTEM}" STREQUAL "Darwin")
      if(NOT "${nasm_helptext}" MATCHES "macho64")
        message(
          FATAL_ERROR "Unsupported nasm: macho64 object format not supported.")
      endif()
    elseif("${AOM_TARGET_SYSTEM}" STREQUAL "MSYS"
           OR "${AOM_TARGET_SYSTEM}" STREQUAL "Windows")
      if(NOT "${nasm_helptext}" MATCHES "win64")
        message(
          FATAL_ERROR "Unsupported nasm: win64 object format not supported.")
      endif()
    else()
      if(NOT "${nasm_helptext}" MATCHES "elf64")
        message(
          FATAL_ERROR "Unsupported nasm: elf64 object format not supported.")
      endif()
    endif()
  endif()
endfunction()

test_nasm()
