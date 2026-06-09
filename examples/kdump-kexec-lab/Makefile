obj-m += test-module.o

all:
	$(MAKE) -C/lib/modules/$(shell uname -r)/build M=$(PWD)
