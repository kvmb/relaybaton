PROJECT="relaybaton"

#BASEDIR	=$(cd "$(dirname "$0")" && pwd)
#GOENV=$(go env GOHOSTOS)_$(go env GOHOSTARCH)
#BUILD_DIR=${BASEDIR}/GOROOT

# Constants
MK_FILE_PATH = $(lastword $(MAKEFILE_LIST))
PRJ_DIR      = $(abspath $(dir $(MK_FILE_PATH)))
#DEV_DIR      = $(PRJ_DIR)/_dev
# Results will be produced in this directory (can be provided by a caller)
BUILD_DIR   ?= $(PRJ_DIR)/GOROOT

# Compiler
GO ?= go
DOCKER ?= docker
GIT ?= git

# Build environment
OS          ?= $(shell $(GO) env GOHOSTOS)
ARCH        ?= $(shell $(GO) env GOHOSTARCH)
OS_ARCH     := $(OS)_$(ARCH)
VER_OS_ARCH := $(shell $(GO) version | cut -d' ' -f 3)_$(OS)_$(ARCH)
VER_MAJOR   := $(shell $(GO) version | cut -d' ' -f 3 | cut -d. -f1-2 | sed 's/[br].*//')
GOROOT_ENV  ?= $(shell $(GO) env GOROOT)
GOROOT_LOCAL = $(BUILD_DIR)/$(OS_ARCH)
# Flag indicates wheter invoke "go install -race std". Supported only on amd64 with CGO enabled
INSTALL_RACE:= $(words $(filter $(ARCH)_$(shell go env CGO_ENABLED), amd64_1))

# Test targets used for compatibility testing
TARGET_TEST_COMPAT=boring picotls tstclnt

# Some target-specific constants
BORINGSSL_REVISION=ff433815b51c34496bb6bea13e73e29e5c278238
BOGO_DOCKER_TRIS_LOCATION=/go/src/github.com/cloudflare/tls-tris

TRIS_SOURCES := $(wildcard $(PRJ_DIR)/*.go)

# SIDH repository
SIDH_REPO  ?= https://github.com/cloudflare/sidh.git
SIDH_REPO_TAG ?= Release_1.0
# NOBS repo (SIKE depends on SHA3)
NOBS_REPO  ?= https://github.com/henrydcase/nobscrypto.git
NOBS_REPO_TAG ?= Release_0.1

# Go 1.13 started resolving non-standard import paths against src/vendor/.
# Previous versions cannot use this, so use the internal directory instead.
ifeq ($(VER_MAJOR), go1.12)
STD_VENDOR_DIR := internal
else ifeq ($(VER_MAJOR), go1.11)
STD_VENDOR_DIR := internal
else
STD_VENDOR_DIR := vendor
endif

###############
#
# Build targets
#
##############################

relaybaton: go
	go mod vendor
	GOROOT=$(GOROOT_LOCAL) go build -o $(PRJ_DIR)/bin/relaybaton $(PRJ_DIR)/cmd/cli/main.go

desktop: relaybaton go
	go mod vendor
	GOROOT=$(GOROOT_LOCAL) go build -o $(PRJ_DIR)/bin/relaybaton-desktop $(PRJ_DIR)/cmd/desktop/main.go

cross_windows: go
	go mod vendor
	GOROOT=$(GOROOT_LOCAL) GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC_FOR_TARGET=x86_64-w64-mingw32-gcc CC=x86_64-w64-mingw32-gcc CC_FOR_windows_amd64=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ CXX_FOR_TARGET=x86_64-w64-mingw32-g++ CXX_FOR_windows_amd64=x86_64-w64-mingw32-g++ go build -o $(PRJ_DIR)/bin/relaybaton.exe $(PRJ_DIR)/cmd/relaybaton/main.go

cross_mac: go
	go mod vendor
	GOROOT=$(GOROOT_LOCAL) GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 CC_FOR_TARGET=o64-clang CC=o64-clang CC_FOR_darwin_amd64=o64-clang CXX=o64-clang++ CXX_FOR_TARGET=o64-clang++ CXX_FOR_darwin_amd64=o64-clang++ go build -o $(PRJ_DIR)/bin/relaybaton+darwin $(PRJ_DIR)/cmd/relaybaton/main.go


# Default target must build Go
.PHONY: go
go: $(BUILD_DIR)/$(OS_ARCH)/.ok_$(VER_OS_ARCH)

# Ensure src and src/vendor directories are present when building in parallel)
$(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR):
	mkdir -p $@

# Replace the local copy if the system Go version has changed.
$(GOROOT_LOCAL)/pkg/.ok_$(VER_OS_ARCH): $(GOROOT_ENV)/pkg | $(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)
	rm -rf $(GOROOT_LOCAL)/pkg $(GOROOT_LOCAL)/src
	mkdir -p "$(GOROOT_LOCAL)/pkg"
	cp -r $(GOROOT_ENV)/src $(GOROOT_LOCAL)/
	cp -r $(GOROOT_ENV)/pkg/include $(GOROOT_LOCAL)/pkg/
	cp -r $(GOROOT_ENV)/pkg/tool $(GOROOT_LOCAL)/pkg/
# Apply additional patches to stdlib
	for p in $(wildcard $(DEV_DIR)/patches/*); do patch -d "$(GOROOT_LOCAL)" -p1 < "$$p"; done
	touch $@

# Vendor NOBS library
$(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)/github.com/henrydcase/nobs: | $(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)
	$(eval TMP_DIR := $(shell mktemp -d))
	$(GIT) clone $(NOBS_REPO) $(TMP_DIR)/nobs
	cd $(TMP_DIR)/nobs; $(GIT) checkout tags/$(NOBS_REPO_TAG)
	perl -pi -e 's/sed -i/perl -pi -e/' $(TMP_DIR)/nobs/Makefile
	cd $(TMP_DIR)/nobs; make vendor-sidh-for-tls
	mv $(TMP_DIR)/nobs/tls_vendor/github_com $(TMP_DIR)/nobs/tls_vendor/github.com
	find $(TMP_DIR)/nobs/tls_vendor -type f -iname "*.go" -print0 | xargs -0 perl -pi -e 's/github_com/github.com/g'
ifeq ($(STD_VENDOR_DIR), internal)
	find $(TMP_DIR)/nobs/tls_vendor -type f -iname "*.go" -print0 | xargs -0 perl -pi -e 's,"github\.com/,"$(STD_VENDOR_DIR)/github.com/,g'
endif
	cp -rf $(TMP_DIR)/nobs/tls_vendor/. $(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)
	-rm -rf $(TMP_DIR)

# Vendor SIDH library
$(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)/github.com/cloudflare/sidh: | $(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)
	$(eval TMP_DIR := $(shell mktemp -d))
	$(GIT) clone $(SIDH_REPO) $(TMP_DIR)/sidh
	cd $(TMP_DIR)/sidh; $(GIT) checkout tags/$(SIDH_REPO_TAG)
	perl -pi -e 's/sed -i/perl -pi -e/' $(TMP_DIR)/sidh/Makefile
	cd $(TMP_DIR)/sidh; make vendor
	mv $(TMP_DIR)/sidh/build/vendor/github_com $(TMP_DIR)/sidh/build/vendor/github.com
	find $(TMP_DIR)/sidh/build/vendor -type f -iname "*.go" -print0 | xargs -0 perl -pi -e 's/github_com/github.com/g'
ifeq ($(STD_VENDOR_DIR), internal)
	find $(TMP_DIR)/sidh/build/vendor -type f -iname "*.go" -print0 | xargs -0 perl -pi -e 's,"github\.com/,"$(STD_VENDOR_DIR)/github.com/,g'
endif
	cp -rf $(TMP_DIR)/sidh/build/vendor/. $(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)
	-rm -rf $(TMP_DIR)

# Rebuild only on dependency (Go core and vendored deps) and Tris changes.
$(BUILD_DIR)/$(OS_ARCH)/.ok_$(VER_OS_ARCH): \
	$(GOROOT_LOCAL)/pkg/.ok_$(VER_OS_ARCH) \
	$(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)/github.com/henrydcase/nobs \
	$(GOROOT_LOCAL)/src/$(STD_VENDOR_DIR)/github.com/cloudflare/sidh \
	$(TRIS_SOURCES)

	go mod vendor
# Replace the standard TLS implementation by Tris
	rsync -a --delete $(PRJ_DIR)/vendor/github.com/cloudflare/tls-tris/ $(GOROOT_LOCAL)/src/crypto/tls/ --exclude='[._]*'

# Adjust internal paths https://github.com/cloudflare/tls-tris/issues/166
ifeq ($(VER_MAJOR), go1.12)
	perl -pi -e 's,"golang\.org/x/crypto/,"internal/x/crypto/,' $(GOROOT_LOCAL)/src/crypto/tls/*.go
else ifeq ($(VER_MAJOR), go1.11)
	perl -pi -e 's,"golang\.org/x/crypto/,"golang_org/x/crypto/,' $(GOROOT_LOCAL)/src/crypto/tls/*.go
endif
	perl -pi -e 's,"golang\.org/x/sys/cpu","internal/cpu",' $(GOROOT_LOCAL)/src/crypto/tls/*.go
ifeq ($(STD_VENDOR_DIR), internal)
# Use internal copy of SIDH and SIKE.
	perl -pi -e 's,"github\.com/,"$(STD_VENDOR_DIR)/github.com/,' $(GOROOT_LOCAL)/src/crypto/tls/*.go
endif

# Create go package
	GOARCH=$(ARCH) GOROOT="$(GOROOT_LOCAL)" $(GO) install -v std
ifeq ($(INSTALL_RACE),1)
	GOARCH=$(ARCH) GOROOT="$(GOROOT_LOCAL)" $(GO) install -race -v std
endif
	@touch "$@"