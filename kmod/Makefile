obj-m := ec_dump.o
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	install -Dm644 ec_dump.ko /lib/modules/$(shell uname -r)/extra/ec_dump.ko
	depmod -a

.PHONY: all clean install
