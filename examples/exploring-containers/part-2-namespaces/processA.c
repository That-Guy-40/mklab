#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#define KEY 0x01
#define SEGMENT_SIZE 0xff

int getSharedMemory(char id);
void usage();

int main(int argc, const char *argv[]){
	if(argc < 2) usage();

	int shared_id = getSharedMemory(KEY);

	char *shared_memory;
	if((shared_memory = shmat(shared_id, NULL, 0)) == -1){
		perror("Shared memory cannot be attached");
		exit(EXIT_FAILURE);
	}

	memcpy(shared_memory, argv[1], strlen(argv[1]) + 1);

	if(shmdt(shared_memory) == -1){
		perror("Shared memory cannot be detached");
		exit(EXIT_FAILURE);
	}

	return 0;
}

int getSharedMemory(char id){
	key_t shared_key = ftok(".", id);
	printf("Created key %X\n", shared_key);

	int shared_id;
	if((shared_id = shmget(shared_key, SEGMENT_SIZE, IPC_CREAT | 0666)) == -1){
		perror("Cannot retrive shared memory");
		exit(EXIT_FAILURE);
	}

	return shared_id;
}

void usage(){
	printf("processA <message>\n");
	exit(EXIT_FAILURE);
}
