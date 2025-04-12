package main

import "C"

import (
	"compress/flate"
	"compress/gzip"
	"io"
	"os"
	"path"
	"time"
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

    err = compress(inputfile, writer)
    if err != nil {
        println(err.Error())
        return -1
    }

    err = writer.Close()
    if err != nil {
        println(err.Error())
        return -1
    }

    return getSize(out)
}

//export Gzip
func Gzip(inputfile string, outputfile string) int64 {
    out, err := os.OpenFile(outputfile, os.O_WRONLY|os.O_TRUNC, 0644)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer out.Close()

    // Create gzip writer
    writer := gzip.NewWriter(out)

    // Set custom metadata
    writer.ModTime = time.Now();
    writer.Name = path.Base(inputfile)
    writer.Comment = " çava "
    // We are responsible to set the subfield format correctly ourselves
    writer.Extra = []byte{0x1, 0x0, 4, 0x0, 0xe, 0xe, 0xe, 0xe}

    err = compress(inputfile, writer)
    if err != nil {
        println(err.Error())
        return -1
    }

    err = writer.Close()
    if err != nil {
        println(err.Error())
        return -1
    }

    return getSize(out)
}

//export FlateDecompress
func FlateDecompress(inputfile string, outputfile string) int64 {
    in, err := os.Open(inputfile)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer in.Close()

    out, err := os.OpenFile(outputfile, os.O_WRONLY|os.O_TRUNC, 0644)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer out.Close()

    // Wrap input file in flate reader
    reader := flate.NewReader(in)

    err = decompress(out, reader)
    if err != nil {
        println(err.Error())
        return -1
    }

    return getSize(out)
}

//export Gunzip
func Gunzip(inputfile string, outputfile string) int64 {
    in, err := os.Open(inputfile)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer in.Close()

    out, err := os.OpenFile(outputfile, os.O_WRONLY|os.O_TRUNC, 0644)
    if err != nil {
        println(err.Error())
        return -1
    }
    defer out.Close()

    // Wrap input file in gzip reader
    reader, err := gzip.NewReader(in)
    if err != nil {
        println(err.Error())
        return -1
    }

    err = decompress(out, reader)
    if err != nil {
        println(err.Error())
        return -1
    }

    return getSize(out)
}

func compress(inputfile string, writer io.Writer) error {
    in, err := os.Open(inputfile)
    if err != nil {
        return err
    }
    defer in.Close()

    // Write input file via the provided writer to the output file
    for {
        written, err := io.Copy(writer, in)
        if err != nil {
            return err
        }
        if written == 0 {
            break
        }
    }
    return nil
}

/// Write input file via reader to output file
func decompress(out *os.File, reader io.Reader) error {
    for {
        written, err := io.Copy(out, reader)

        if err != nil {
            if err == io.EOF || err == io.ErrUnexpectedEOF {
                break
            }
            return err
        }
        if written == 0 {
            break
        }
    }

    return nil
}

func getSize(out *os.File) int64 {
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
