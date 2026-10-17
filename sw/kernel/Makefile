# The NGVM kernel.  `make` builds build/kernel.elf (and .bin, .lst).
CC      = arm-none-eabi-gcc
OBJDUMP = arm-none-eabi-objdump
OBJCOPY = arm-none-eabi-objcopy
B       = ../../build/kernel
CFLAGS  = -march=armv4t -marm -mno-thumb-interwork -O2 -g -ffreestanding -fno-builtin \
          -fno-common -fno-strict-aliasing -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare -Wno-address-of-packed-member -I. -I../include
SRCS    = start.S $(wildcard *.c)
OBJS    = $(patsubst %,$(B)/%.o,$(SRCS))

all: $(B)/kernel.elf
$(B)/%.o: % $(wildcard *.h) ../include/ngvm_hw.h
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/kernel.elf: $(OBJS) kernel.ld
	$(CC) $(CFLAGS) -nostdlib -T kernel.ld $(OBJS) -lgcc -o $@
	$(OBJCOPY) -O binary $@ $(B)/kernel.bin
	$(OBJDUMP) -d $@ > $(B)/kernel.lst
clean:
	rm -rf $(B)
.PHONY: all clean
