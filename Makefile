VERSION = 1
ARCH            = $(shell uname -m | sed s,i[3456789]86,ia32,)

ifeq ($(MAKELEVEL),0)
TOPDIR		?= $(shell pwd)
endif
ifeq ($(TOPDIR),)
override TOPDIR := $(shell pwd)
endif
override TOPDIR	:= $(abspath $(TOPDIR))
VPATH		= $(TOPDIR)
export TOPDIR

CROSS_COMPILE =
DATADIR := /usr/share
LIBDIR := /usr/lib64
GNUEFIDIR ?= $(TOPDIR)/gnu-efi/
COMPILER = gcc
CC = $(CROSS_COMPILE)$(COMPILER)
CFLAGS ?= -O0 -g3
BUILDFLAGS := $(CFLAGS) -fPIC -Werror -Wall -Wextra -fshort-wchar \
        -fno-merge-constants -ffreestanding \
        -fno-stack-protector -fno-stack-check --std=gnu11 -DCONFIG_$(ARCH) \
	-I$(GNUEFIDIR)/inc \
	-I$(GNUEFIDIR)/inc/$(ARCH) \
	-I$(GNUEFIDIR)/inc/protocol
CCLDFLAGS ?= -nostdlib -fPIC -Wl,--warn-common \
        -Wl,--no-undefined \
        -Wl,-shared -Wl,-Bsymbolic -L$(LIBDIR) -L$(GNUEFIDIR) \
        -Wl,--build-id=sha1 -Wl,--hash-style=sysv
LD = $(CROSS_COMPILE)ld
OBJCOPY = $(CROSS_COMPILE)objcopy
OBJCOPY_GTE224  = $(shell expr $$($(OBJCOPY) --version |grep "^GNU objcopy" | sed 's/^.*\((.*)\|version\) //g' | cut -f1-2 -d.) \>= 2.24)
INSTALLROOT ?= $(DESTDIR)

dbsize = \
	$(if $(filter-out undefined,$(origin VENDOR_DB_FILE)),$(shell /usr/bin/stat --printf="%s" $(VENDOR_DB_FILE)),0)

DB_ADDRESSES=$(shell objdump -h certwrapper.so | $(TOPDIR)/find-addresses dbsz=$(call dbsize))
DB_ADDRESS=$(word $(2), $(call DB_ADDRESSES, $(1)))

DB_SECTION_ALIGN = 512
DB_SECTION_FLAGS = alloc,contents,load,readonly,data
define VENDOR_DB =
	$(if $(filter-out undefined,$(origin VENDOR_DB_FILE)),\
	--set-section-alignment .db=$(DB_SECTION_ALIGN) \
	--set-section-flags .db=$(DB_SECTION_FLAGS) \
	--add-section .db="$(VENDOR_DB_FILE)" \
	--change-section-address .db=$(call DB_ADDRESS, $(1), 1),)
endef

define add-vendor-sbat
$(OBJCOPY) --add-section ".$(patsubst %.csv,%,$(1))=$(1)" $(2)
endef

define add-skusi
$(OBJCOPY) --add-section ".$(patsubst %.bin,%,$(1))=$(1)" $(2)
endef

SBATPATH = $(TOPDIR)/data/sbat.csv
SBATLEVELLATESTPATH = $(TOPDIR)/data/sbat_level_latest.csv
SBATLEVELAUTOMATICPATH = $(TOPDIR)/data/sbat_level_automatic.csv
SSPVLATESTPATH = $(TOPDIR)/data/SkuSiPolicy_Version_latest.bin
SSPSLATESTPATH = $(TOPDIR)/data/SkuSiPolicy_latest.bin
SSPVAUTOMATICPATH = $(TOPDIR)/data/SkuSiPolicy_Version_automatic.bin
SSPSAUTOMATICPATH = $(TOPDIR)/data/SkuSiPolicy_automatic.bin
VENDOR_SBATS := $(sort $(foreach x,$(wildcard $(TOPDIR)/data/sbat.*.csv data/sbat.*.csv),$(notdir $(x))))

OBJFLAGS =
SOLIBS =

ifeq ($(ARCH),x86_64)
	FORMAT = --target efi-app-$(ARCH)
	BUILDFLAGS += -mno-mmx -mno-sse -mno-red-zone -nostdinc \
		-maccumulate-outgoing-args -DEFI_FUNCTION_WRAPPER \
		-DGNU_EFI_USE_MS_ABI -I$(shell $(CC) -print-file-name=include)
endif
ifeq ($(ARCH),ia32)
	FORMAT = --target efi-app-$(ARCH)
	BUILDFLAGS += -mno-mmx -mno-sse -mno-red-zone -nostdinc \
		-maccumulate-outgoing-args -m32 \
		-I$(shell $(CC) -print-file-name=include)
endif

ifeq ($(ARCH),aarch64)
	FORMAT = --target efi-app-$(ARCH)
	BUILDFLAGS += -ffreestanding -I$(shell $(CC) -print-file-name=include)
endif

ifeq ($(ARCH),arm)
	FORMAT = -O binary
	CCLDFLAGS += -Wl,--defsym=EFI_SUBSYSTEM=0xa
	BUILDFLAGS += -ffreestanding -I$(shell $(CC) -print-file-name=include)
endif

all : certwrapper.efi revocations.efi revocations_sbat.efi revocations_sku.efi

certwrapper.so : revocation_data.o certwrapper.o
certwrapper.so : SOLIBS=
certwrapper.so : SOFLAGS=
certwrapper.so : BUILDFLAGS+=-DVENDOR_DB
certwrapper.efi : OBJFLAGS = --strip-unneeded $(call VENDOR_DB, $<)
certwrapper.efi : SECTIONS=.text .reloc .db .sbat
certwrapper.efi : VENDOR_DB_FILE?=db.esl

revocations.so : revocation_data.o revocations.o
revocations_sbat.so : revocation_data.o revocations_sbat.o
revocations_sku.so : revocation_data.o revocations_sku.o
revocations_sbat.so revocations_sku.so revocations.so : SOLIBS=
revocations_sbat.so revocations_sku.so revocations.so : SOFLAGS=
revocations_sbat.efi revocations_sku.efi revocations.efi : OBJFLAGS = --strip-unneeded
revocations.efi : SECTIONS=.text .reloc .sbat .sbatl .sbata .sspva .sspsa .sspvl .sspsl
revocations_sbat.efi : SECTIONS=.text .reloc .sbat .sbatl .sbata
revocations_sku.efi : SECTIONS=.text .reloc .sbat .sspva .sspsa .sspvl .sspsl

revocations.o : certwrapper.o
	cp certwrapper.o revocations.o
revocations_sbat.o : certwrapper.o
	cp certwrapper.o revocations_sbat.o
revocations_sku.o : certwrapper.o
	cp certwrapper.o revocations_sku.o

SBAT_LATEST_DATE ?= 2023012950
SBAT_AUTOMATIC_DATE ?= 2023012900

$(SBATLEVELLATESTPATH) :
	awk '/^sbat,1,$(SBAT_LATEST_DATE)/ { print $$0 }' \
		FS=\"\n\" RS=\\n\\n shim/SbatLevel_Variable.txt \
		> $@

$(SBATLEVELAUTOMATICPATH) :
	awk '/^sbat,1,$(SBAT_AUTOMATIC_DATE)/ { print $$0 }' \
		FS=\"\n\" RS=\\n\\n shim/SbatLevel_Variable.txt \
		> $@

%.efi : %.so
ifneq ($(OBJCOPY_GTE224),1)
	$(error objcopy >= 2.24 is required)
endif
	$(OBJCOPY) $(foreach section,$(SECTIONS),-j $(section) ) \
		   --file-alignment 512 --section-alignment 4096 -D \
		   $(OBJFLAGS) \
		   $(FORMAT) $^ $@

revocation_data.o : $(SBATLEVELLATESTPATH) $(SBATLEVELAUTOMATICPATH)
revocation_data.o : | $(SBATPATH) $(VENDOR_SBATS)
revocation_data.o : /dev/null
	$(CC) $(BUILDFLAGS) -x c -c -o $@ $<
	$(OBJCOPY) --add-section .sbat=$(SBATPATH) \
		--set-section-flags .sbat=contents,alloc,load,readonly,data \
		$@
	$(OBJCOPY) --add-section .sbatl=$(SBATLEVELLATESTPATH) \
		--set-section-flags .sbatl=contents,alloc,load,readonly,data \
		$@
	$(OBJCOPY) --add-section .sbata=$(SBATLEVELAUTOMATICPATH) \
		--set-section-flags .sbata=contents,alloc,load,readonly,data \
		$@
	$(OBJCOPY) --add-section .sspvl=$(SSPVLATESTPATH) \
		--set-section-flags .sspvl=contents,alloc,load,readonly,data \
		$@
	$(OBJCOPY) --add-section .sspsl=$(SSPSLATESTPATH) \
		--set-section-flags .sspsl=contents,alloc,load,readonly,data \
		$@
	$(OBJCOPY) --add-section .sspva=$(SSPVAUTOMATICPATH) \
		--set-section-flags .sspva=contents,alloc,load,readonly,data \
		$@
	$(OBJCOPY) --add-section .sspsa=$(SSPSAUTOMATICPATH) \
		--set-section-flags .sspsa=contents,alloc,load,readonly,data \
		$@
	$(foreach vs,$(VENDOR_SBATS),$(call add-vendor-sbat,$(vs),$@))

%.so : %.o
	$(CC) $(CCLDFLAGS) $(SOFLAGS) -o $@ $^ $(SOLIBS) \
		$(shell $(CC) -print-libgcc-file-name) \
		-T $(TOPDIR)/elf_$(ARCH)_efi.lds

%.o : %.c
	$(CC) $(BUILDFLAGS) -c -o $@ $^

clean :
	@rm -vf *.o *.so *.efi $(SBATLEVELLATESTPATH) $(SBATLEVELAUTOMATICPATH)

update :
	git submodule update --init --recursive

install :
	install -D -d -m 0755 $(INSTALLROOT)/$(DATADIR)/certwrapper-$(VERSION)
	install -m 0644 certwrapper.efi $(INSTALLROOT)/$(DATADIR)/certwrapper-$(VERSION)/certwrapper.efi

GITTAG = $(VERSION)

test-archive:
	@./make-archive $(if $(call get-config,certwrapper.origin),--origin "$(call get-config,certwrapper.origin)") --test "$(VERSION)"

tag:
	git tag --sign $(GITTAG) refs/heads/main
	git tag -f latest-release $(GITTAG)

archive: tag
	@./make-archive $(if $(call get-config,certwrapper.origin),--origin "$(call get-config,certwrapper.origin)") --release "$(VERSION)" "$(GITTAG)" "certwrapper-$(GITTAG)"
