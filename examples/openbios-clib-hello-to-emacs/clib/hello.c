/* hello.c — rung 1 of the ladder: the smallest possible OpenBIOS client.
 *
 * The firmware `load`s this ELF and `go`s it; at _start (in of1275.c) it is
 * handed the client-interface callback, which of1275_io.c/clib.c turn back
 * into console output. So every line below is the client asking the firmware,
 * over the IEEE 1275 client interface, to write to the machine's console —
 * with no operating system anywhere.
 *
 * _start (of1275.c) calls main() and then of1275_exit(return value).
 */
#include "clib.h"

int main(void)
{
	putsn("Hello world!  --  an OpenBIOS client program, calling back into the firmware.");
	puts("clib proof: 6 * 7 = ");
	put_udec(6 * 7);
	puts(", or in hex ");
	put_hex(6 * 7);
	putsn("");
	return 0;
}
