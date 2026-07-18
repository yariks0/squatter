# Root entry point for the monorepo. iOS app lives in apps/ios, the Go API in
# apps/backend. Backend targets delegate to apps/backend/Makefile.
.PHONY: help \
	ios-generate ios-test ios-build \
	backend-run backend-test compose-up compose-down psql \
	prod-up prod-down prod-logs prod-ps prod-backup

IOS_DIR := apps/ios
IOS_PROJECT := $(IOS_DIR)/Squatter.xcodeproj
SIM := platform=iOS Simulator,name=iPhone 17 Pro

help:
	@echo "iOS:     ios-generate  ios-test  ios-build"
	@echo "Backend: backend-run  backend-test  compose-up  compose-down  psql"
	@echo "Prod:    prod-up  prod-down  prod-logs  prod-ps  prod-backup  (on the VM)"

# --- iOS (XcodeGen + xcodebuild) ---------------------------------------------
ios-generate:
	cd $(IOS_DIR) && xcodegen generate

ios-test: ios-generate
	xcodebuild test -project $(IOS_PROJECT) -scheme Squatter \
		-destination '$(SIM)' -quiet

ios-build: ios-generate
	xcodebuild -project $(IOS_PROJECT) -scheme Squatter \
		-destination generic/platform=iOS -allowProvisioningUpdates -quiet build

# --- Backend (delegates to apps/backend/Makefile) ----------------------------
backend-run:
	$(MAKE) -C apps/backend run

backend-test:
	$(MAKE) -C apps/backend test

compose-up:
	$(MAKE) -C apps/backend compose-up

compose-down:
	$(MAKE) -C apps/backend compose-down

psql:
	$(MAKE) -C apps/backend psql

# --- Production (run these on the droplet; see apps/backend/README.md) --------
prod-up:
	$(MAKE) -C apps/backend prod-up

prod-down:
	$(MAKE) -C apps/backend prod-down

prod-logs:
	$(MAKE) -C apps/backend prod-logs

prod-ps:
	$(MAKE) -C apps/backend prod-ps

prod-backup:
	$(MAKE) -C apps/backend prod-backup
