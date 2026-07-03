#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define KB (1024)
#define MB (1024 * KB)

int main(int argc, char *argv[])
{
    const int bytesToAllocate = 10 * MB;
    const int megabytesToAllocate = bytesToAllocate / MB;

    int totalMegabytesAllocated = 0;
    void *p;

    while (1)
    {
        p = malloc(bytesToAllocate);
        if (p == NULL)
        {
            perror("Unable to allocate memory, exiting..");
            return 1;
        }
        memset(p, 0, bytesToAllocate);

        totalMegabytesAllocated += megabytesToAllocate;
        printf("Total \t%d MB\n", totalMegabytesAllocated);
        sleep(1);
    }
    return 0;
}
