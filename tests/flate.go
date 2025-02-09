package main

import "C"

import (
    "bufio"
    "bytes"
    "compress/flate"
    "compress/gzip"
    "fmt"
    "io"
    "os"
)

//export DeflateHuffmanOnly
func DeflateHuffmanOnly(input []uint8, output []uint8) int {
    var buf bytes.Buffer

    w, err := flate.NewWriter(&buf, flate.HuffmanOnly)

    if err != nil {
        return -1
    }
    w.Write(input)
    w.Close()

    for i := 0; i < len(output); i++ {
        b, err := buf.ReadByte()
        if err == io.EOF {
            return i
        }
        output[i] = b;
    }

    return len(output);
}

//export InflateHuffmanOnly
func InflateHuffmanOnly(input []uint8, output []uint8) int {
    var buf bytes.Buffer
    var n = 0
    var err error

    _, err = buf.Write(input)
    if err != nil {
        fmt.Printf("write: %+v\n", err);
        return -1
    }

    reader := flate.NewReader(&buf)
    defer reader.Close()

    for {
        n, err = reader.Read(output[n:]);
        if err != nil && err != io.EOF {
            fmt.Printf("read: %+v\n", err);
            return -1
        }
        if err == io.EOF {
            break
        }
    }

    return n;
}

func InflateGzip(input []uint8, output []uint8) int {
    var buf bytes.Buffer
    var n = 0
    var err error

    _, err = buf.Write(input)
    if err != nil {
        fmt.Printf("write: %+v\n", err);
        return -1
    }

    reader, err := gzip.NewReader(&buf)
    if err != nil {
        fmt.Printf("reader: %+v\n", err);
        return -1
    }
    defer reader.Close()

    for {
        n, err = reader.Read(output[n:]);
        if err != nil && err != io.EOF {
            fmt.Printf("read: %+v\n", err);
            return -1
        }
        if err == io.EOF {
            break
        }
    }

    return n;
}


func loadFromFile(path string) ([]byte, bool) {
    out, err := os.ReadFile(path)
    if err != nil {
        fmt.Printf("Error reading: '%s'\n", path)
        return nil, false
    }
    return out, true
}

func dump(b []byte) {
    f := bufio.NewWriter(os.Stderr)
    f.Write(b)
    f.Flush() // Make sure to flush the stream
    println()
}

func arrayEquals(arr1 []byte, arr2 []byte) bool {
    for i := 0; i < len(arr1); i++ {
        if arr1[i] != arr2[i] {
            return false
        }
    }
    return true
}

func main() {
    if len(os.Args) != 3 {
        println("Usage: <uncompressed> <compressed>")
        os.Exit(1)
    }
    uncompressed, ok := loadFromFile(os.Args[1])
    if !ok {
        os.Exit(1)
    }

    compressed, ok := loadFromFile(os.Args[2])
    if !ok {
        os.Exit(1)
    }

    output := make([]uint8, len(uncompressed), len(uncompressed))

    // Inflate the provided compressed file and compare it to the original
    InflateGzip(compressed, output)

    if !arrayEquals(uncompressed, output) {
        println("Inflate: ERROR")
        os.Exit(1)
    }
    println("Inflate: OK")
}
