# z7
Gzip implementation in Zig. Compatible with zig 0.14.0.

```bash
zig build bin -Doptimize=ReleaseSafe
./zig-out/bin/z7 --help
```

## Unit tests

```bash
# Flags:
#   -Ddebug=true      Print debug logs
#   -Dtrace=true      Print detailed debug logs
#   -Dquiet=true      Quiet test result output
zig build test --summary all && ./zig-out/bin/z7-test

# To only build tests for a specific file
zig build test --summary all -- tests/flags_test.zig && ./zig-out/bin/z7-test

# Unit tests can be easily ran in a debugger
lldb ./zig-out/bin/z7-test
```


## Acknowledgments
* [Good guide on deflate](https://www.youtube.com/watch?v=SJPvNi4HrWQ)
