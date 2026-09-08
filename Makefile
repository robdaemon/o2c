# o2c driver.  AEGIR_ROOT must point at the aegir checkout whose
# userspace runtime chain this repo's programs build against.  It is
# required: unset/empty fails the build instead of assuming a path.
ifndef AEGIR_ROOT
$(error AEGIR_ROOT is not set - point it at the aegir checkout, e.g. make build AEGIR_ROOT=/path/to/aegir)
endif

ALR_DIR := $(AEGIR_ROOT)/userspace/echo   # any aegir alr crate provides the toolchain env

.PHONY: build clean

build:
	cd $(ALR_DIR) && alr exec -- gprbuild -p -P $(CURDIR)/crate/o2c.gpr \
	  -aP $(AEGIR_ROOT)/userspace/rts -XAEGIR_ROOT=$(AEGIR_ROOT)

clean:
	rm -rf crate/obj crate/bin
