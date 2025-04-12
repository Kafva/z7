# z7
Gzip implementation in Zig. Compatible with zig 0.14.0.

```bash
zig build run -- --help
```

## Unit tests

```bash
# Flags:
#   -Ddebug=true      Print debug logs
#   -Dquiet=true      Quiet test result output
zig build test --summary all && ./zig-out/bin/z7-test

# To only build tests for a specific file
zig build test --summary all -- tests/flags_test.zig && ./zig-out/bin/z7-test

# Unit tests can be easily ran in a debugger
lldb ./zig-out/bin/z7-test
```
