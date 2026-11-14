#!/usr/bin/env bats

load 'helper'

setup() {
  source_script cli/pdf-prep/install.sh
  unset PDFPREP_TORCH
  nvidia_supported() { return 1; }
  amd_linux_supported() { return 0; }
}

@test "pdf-prep: Windows AMD uses CPU even when an AMD probe would match" {
  run detect_torch_build windows
  assert_success
  assert_output "cpu"
}

@test "pdf-prep: Linux AMD selection remains available" {
  run detect_torch_build linux
  assert_success
  assert_output "rocm-linux"
}

@test "pdf-prep: removed Windows ROCm override cannot install vulnerable wheels" {
  export PDFPREP_TORCH=rocm-windows
  run detect_torch_build windows
  assert_failure
  assert_output --partial "PDFPREP_TORCH must be one of:"
}
