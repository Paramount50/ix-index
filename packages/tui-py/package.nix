{
  id = "tui-py";
  inRustWorkspace = true;
  # The PyO3 extension cdylib links cleanly only where undefined symbols are
  # allowed in a shared object (Linux), the same constraint that keeps ix's
  # native SDK wheels Linux-only. macOS needs `-undefined dynamic_lookup`, which
  # the shared cargo-unit graph does not thread through, so the wheel is built on
  # Linux (manylinux). Local macOS dev uses the editable build, not this package.
  flake.systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
  packageSet.systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];
}
