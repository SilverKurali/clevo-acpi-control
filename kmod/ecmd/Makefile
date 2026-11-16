obj-m += clevo_ecmd.o
KVER ?= $(shell uname -r)
all:
	$(MAKE) -C /lib/modules/$(KVER)/build M=$(PWD) modules
clean:
	$(MAKE) -C /lib/modules/$(KVER)/build M=$(PWD) clean
