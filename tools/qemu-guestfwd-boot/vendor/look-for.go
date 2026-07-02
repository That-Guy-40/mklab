package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
)

func main() {
	ignore := flag.String("i", "", "Ignore everything from start of line until this character occurs")
	flag.Parse()

	if len(flag.Args()) != 1 {
		fmt.Printf("Usage: look-for [ -i IGNORE-CHAR ] LINE-PREFIX\n\n" +
			"Reads stdin, and exits successfully when a line starting\n" +
			"with the given prefix is seen.\n")
		os.Exit(1)
	}

	if len(*ignore) > 1 {
		fmt.Fprintf(os.Stderr, "invalid argument %q for -i options, must be empty or a single ascii character")
		os.Exit(1)
	}

	lookingFor := []byte(flag.Arg(0))

	input := bufio.NewReader(os.Stdin)
	getByte := func() byte {
		b, err := input.ReadByte()
		if err == io.EOF {
			os.Exit(1)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "read failed: %v", err)
			os.Exit(1)
		}
		return b
	}

	for {
		// The ignore-char feature is primitive workaround for
		// lack of a proper regexp state machine, and
		// corresponds to prepending the regexp "[^i]*i" to
		// the literal string we are looking for, with "i"
		// being the ignore character.
		if *ignore != "" {
			// Skips until first ignore character. May
			// skip multiple lines, but necessarily stops
			// on the first ignore character on its line.
			for getByte() != (*ignore)[0] {
			}
		}
		func() {
			for _, c := range lookingFor {
				if getByte() != c {
					return
				}

			}
			os.Exit(0)
		}()
		// Skip rest of line
		for getByte() != '\n' {
		}
	}
}
