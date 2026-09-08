# o2c driver.  AEGIR_ROOT points at the aegir checkout whose userspace
# runtime chain this repo's programs build against.
AEGIR_ROOT ?= $(HOME)/src/aegir
ALR_DIR    := $(AEGIR_ROOT)/userspace/echo   # any aegir alr crate provides the toolchain env

.PHONY: build clean

build:
	cd $(ALR_DIR) && alr exec -- gprbuild -p -P $(CURDIR)/crate/o2c.gpr \
	  -aP $(AEGIR_ROOT)/userspace/rts -XAEGIR_ROOT=$(AEGIR_ROOT)

clean:
	rm -rf crate/obj crate/bin
