package main

import "C"

import (
    "bytes"
    "compress/flate"
    "fmt"
    "io"
    "math/rand"
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

    _, err := buf.Write(input)
    if err != nil {
        fmt.Printf("write: %+v\n", err);
        return -1
    }

    reader := flate.NewReader(&buf)
    defer reader.Close()

    n, err := reader.Read(output);
    if err != nil && err != io.EOF {
        fmt.Printf("read: %+v\n", err);
        return -1
    }

    return n;
}

func main() {
    input := make([]uint8, 1024, 1024)
    output := make([]uint8, 1024, 1024)
    output2 := make([]uint8, 1024, 1024)

    for i := 0; i < len(input); i++ {
        input[i] = 'A' + uint8(rand.Int() % 10)
    }

    compressed_len := DeflateHuffmanOnly(input, output)

    InflateHuffmanOnly(output[:compressed_len], output2)

    for i := 0; i < len(input); i++ {
        if input[i] != output2[i] {
            println("FAILED")
            os.Exit(1)
        }
    }

    println("OK")
}
