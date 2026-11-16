obj-m := clevo_fan.o
KDIR ?= /lib/modules/$(shell uname -r)/build

KVER ?= $(shell uname -r)

all:
	$(MAKE) -C /lib/modules/$(KVER)/build M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean
