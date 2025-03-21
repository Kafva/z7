package main

import "C"

import (
    "bufio"
    "bytes"
    "compress/flate"
    "compress/gzip"
    "io"
    "os"
)

//export DeflateHuffmanOnly
func DeflateHuffmanOnly(inputfile string, outputfile string) int64 {
    // Open input file
    in, err := os.Open(inputfile)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer in.Close()

    // Open output file
    out, err := os.Create(outputfile)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer out.Close()
    // Wrap output file in flate writer
    writer, err := flate.NewWriter(out, flate.HuffmanOnly)
    if err != nil {
        println(err.Error())
        return -1
    }

    // Write input file via flate writer to output file
    written, err := io.Copy(writer, in)
    if err != nil {
        println(err.Error())
        return -1
    }

    return written
}

//export InflateHuffmanOnly
func InflateHuffmanOnly(inputfile string, outputfile string) int64 {
    // Open input file
    in, err := os.Open(inputfile)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer in.Close()
    // Wrap input file in flate reader
    reader := flate.NewReader(in)

    // Open output file
    out, err := os.Create(outputfile)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer out.Close()

    // Write input file via flate reader to output file
    written, err := io.Copy(out, reader)
    if err != nil {
        println(err.Error())
        return -1
    }

    return written
}

func InflateGzip(input []uint8, output []uint8) int {
    var buf bytes.Buffer
    var n = 0
    var err error

    _, err = buf.Write(input)
    if err != nil {
        println(err.Error())
        return -1
    }

    reader, err := gzip.NewReader(&buf)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer reader.Close()

    for {
        n, err = reader.Read(output[n:]);
        if err != nil && err != io.EOF {
            println(err.Error())
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
        println(err.Error())
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
    for i := range arr1 {
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
