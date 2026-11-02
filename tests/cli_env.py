"""Give a CLI check the environment that `zig build test-cli` passes to it."""

import os
import sys


def cli_env(**variables):
    """Return the environment with the given variables, or exit when the check does not run under `zig build test-cli`."""
    if os.environ.get("BBR_TEST_CLI") != "1":
        sys.exit(f"{sys.argv[0]}: run with `zig build test-cli`, which clears the caller's Credentials, Profile, and XDG homes.")
    return dict(os.environ, **variables)
