# z7
Gzip implementation in Zig. Compatible with zig 0.14.0.

```bash
zig build run -- --help
```

## Unit tests

```bash
# Flags:
#   -Ddebug=true      Print debug logs
#   -Dverbose=true    Print verbose results for each test case
zig build test --summary all && ./zig-out/bin/z7-test

# To only build tests for a specific file
zig build test --summary all -- src/flags_test.zig && ./zig-out/bin/z7-test

# Unit tests can be easily ran in a debugger
lldb ./zig-out/bin/z7-test
```
