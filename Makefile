# o2c driver.  AEGIR_ROOT must point at the aegir checkout whose
# userspace runtime chain this repo's programs build against.  It is
# required: unset/empty fails the build instead of assuming a path.
ifndef AEGIR_ROOT
$(error AEGIR_ROOT is not set - point it at the aegir checkout, e.g. make build AEGIR_ROOT=/path/to/aegir)
endif

ALR_DIR := $(AEGIR_ROOT)/userspace/echo   # any aegir alr crate provides the toolchain env

#  The aegir runtime archives are linked with -L/-l, not as project
#  dependencies, so gprbuild does not notice when one of them changes
#  and skips the relink.  Drop the ELF first when an archive is newer
#  than it, so a runtime change (heap, syscalls) always reaches o2c.
RTS_ARCHIVES := $(AEGIR_ROOT)/userspace/gnat-rts/adalib/libgnat.a \
                $(AEGIR_ROOT)/lib/userspace/rts/libaegir_user.a

.PHONY: build clean

build:
	@for f in $(RTS_ARCHIVES); do \
	  if [ -f "$$f" ] && [ "$$f" -nt crate/bin/o2c.elf ]; then \
	     echo "o2c: $$f is newer than the ELF; forcing a relink"; \
	     rm -f crate/bin/o2c.elf; \
	  fi; \
	done
	cd $(ALR_DIR) && alr exec -- gprbuild -p -P $(CURDIR)/crate/o2c.gpr \
	  -aP $(AEGIR_ROOT)/userspace/rts -XAEGIR_ROOT=$(AEGIR_ROOT)

clean:
	rm -rf crate/obj crate/bin
