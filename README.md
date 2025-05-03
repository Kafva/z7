# z7
Gzip implementation in Zig, compatible with Zig version 0.14.0.
To build and install an optimized build:

```bash
zig build bin -Doptimize=ReleaseFast && 
    install -m755 ./zig-out/bin/z7 ~/.local/bin/z7
```

## Unit tests
The unit tests verify against the reference implementation in Go, i.e.
Go needs to be installed to run the unit tests.

```bash
# Flags:
#   -Ddebug=true      Print debug logs
#   -Dtrace=true      Print detailed debug logs
#   -Dquiet=true      Quiet test result output
zig build test --summary all && ./zig-out/bin/z7-test

# To only build tests for a specific file
zig build test --summary all -- tests/gzip_test.zig && ./zig-out/bin/z7-test

# Unit tests can be easily ran in a debugger
lldb ./zig-out/bin/z7-test
```

## Acknowledgments
* [Good guide on deflate](https://www.youtube.com/watch?v=SJPvNi4HrWQ)
