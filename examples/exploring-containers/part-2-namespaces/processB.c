#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#define KEY 0x01
#define SEGMENT_SIZE 0xff

int getSharedMemory(char id);
void removeSharedMemory(int shared_id);

int main(int argc, const char *argv[]){

	int shared_id = getSharedMemory(KEY);

	char *shared_memory;
	if((shared_memory = shmat(shared_id, NULL, SHM_RDONLY)) == -1){
		perror("Shared memory cannot be attached");
		exit(EXIT_FAILURE);
	}

	printf("Reading shared memory:\n%s\n",shared_memory);

	if(shmdt(shared_memory) == -1){
		perror("Shared memory cannot be detached");
		exit(EXIT_FAILURE);
	}

	sleep(1);
	removeSharedMemory(shared_id);
	return 0;
}


int getSharedMemory(char id){
	key_t shared_key = ftok(".", id);
	printf("Created key %X\n", shared_key);

	int shared_id;
	if((shared_id = shmget(shared_key, SEGMENT_SIZE, IPC_CREAT | 0660)) == -1){
		perror("Cannot retrive shared memory");
		exit(EXIT_FAILURE);
	}

	return shared_id;
}

void removeSharedMemory(int shared_id){
	struct shmid_ds info;

	if(shmctl(shared_id, IPC_RMID, NULL) == -1){
		perror("Cannot remove shared memory");
		exit(EXIT_FAILURE);
	}
	printf("Shared memory removed\n");
}
