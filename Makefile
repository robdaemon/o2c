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

#  Host build of the bytecode VM.  This deliberately does NOT go through
#  the aegir crate's alr environment: that one selects the riscv64
#  toolchain, and the host VM is a plain x86_64 Ada program with no Aegir
#  runtime - it is the reference tool the golden tests diff against, and
#  it has to stay runnable after the Ada backend is retired.  alr keeps
#  native toolchains under ~/.local/share/alire/toolchains/; override
#  VM_GNAT_BIN for a different layout.
VM_GNAT_BIN := $(firstword $(wildcard $(HOME)/.local/share/alire/toolchains/gnat_native_*/bin) $(wildcard $(HOME)/.local/share/alire/toolchains/gnat_*/bin))
VM_GPR_BIN := $(firstword $(wildcard $(HOME)/.local/share/alire/toolchains/gprbuild_*/bin))
VM_GPRBUILD := $(if $(VM_GPR_BIN),$(VM_GPR_BIN)/gprbuild,gprbuild)

.PHONY: vm-host vm-clean
vm-host:
	@if [ -z "$(VM_GNAT_BIN)" ]; then \
	   echo "vm-host: no native GNAT toolchain found under" \
	        "$$HOME/.local/share/alire/toolchains; set VM_GNAT_BIN"; \
	   exit 1; \
	fi
	@#  gprbuild needs both the compiler and its own directory on PATH:
	@#  gnatmake refuses project files in this GNAT release.
	PATH="$(VM_GNAT_BIN):$(VM_GPR_BIN):$(PATH)" $(VM_GPRBUILD) -p -P $(CURDIR)/vm/vm.gpr

vm-clean:
	rm -rf vm/obj vm/bin
