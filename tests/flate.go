package main

import "C"

import (
    "compress/flate"
    "io"
    "os"
)

//export FlateCompress
func FlateCompress(inputfile string, outputfile string) int64 {
    out, err := os.OpenFile(outputfile, os.O_WRONLY|os.O_TRUNC, 0644)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer out.Close()

    // Create flate writer
    writer, err := flate.NewWriter(out, flate.DefaultCompression)
    if err != nil {
        println(err.Error())
        return -1
    }

    if compress(inputfile, writer) != 0 {
        return -1
    }

    writer.Flush()
    return getsize(out)
}

//export FlateDecompress
func FlateDecompress(inputfile string, outputfile string) int64 {
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
    out, err := os.OpenFile(outputfile, os.O_WRONLY|os.O_TRUNC, 0644)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer out.Close()

    // Write input file via flate reader to output file
    for {
        _, err := io.Copy(out, reader)

        if err != nil {
            if err == io.EOF || err == io.ErrUnexpectedEOF {
                break
            }
            println(err.Error())
            return -1
        }
    }

    info, err := out.Stat()
    if err != nil {
        println(err.Error())
        return -1
    }

    return info.Size()
}

func compress(inputfile string, writer *flate.Writer) int64 {
    in, err := os.Open(inputfile)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer in.Close()

    // Write input file via the provided writer to the output file
    _, err = io.Copy(writer, in)

    if err != nil {
        println(err.Error())
        return -1
    }

    return 0
}

func getsize(out *os.File) int64 {
    // The number of "written" bytes will be equal to the bytes in the input file,
    // not the resulting size of the compressed file, use Stat() to get the
    // actual size.
    info, err := out.Stat()
    if err != nil {
        println(err.Error())
        return -1
    }

    return info.Size()
}

func main() {}
