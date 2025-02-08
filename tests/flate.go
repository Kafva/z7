package main

import "C"

import (
    "bytes"
    "compress/flate"
    "fmt"
    "io"
)

//export FlateHuffmanOnly
func FlateHuffmanOnly(input []uint8, output []uint8) uint8 {
    var buf bytes.Buffer

    w, err := flate.NewWriter(&buf, flate.HuffmanOnly)

    if err != nil {
        return 1
    }
    w.Write(input)
    w.Close()

    for i := 0; i < len(output); i++ {
        b, err := buf.ReadByte()
        if err == io.EOF {
            break
        }
        output[i] = b;
    }

    return 0;
}

func main() {
    input := []uint8{1,2,3,4}
    output := []uint8{0,0,0,0}
    FlateHuffmanOnly(input, output)

    fmt.Printf("output: %+v\n", output);
}
