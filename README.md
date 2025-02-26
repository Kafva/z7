# z7
Compression tool

```bash
zig build run -- --help
```

## Unit tests
```bash
# Add -Ddebug=true to print debug logs
zig build test --summary all && ./zig-out/bin/z7-test
# Unit tests can be easily ran in a debugger
lldb ./zig-out/bin/z7-test
```
