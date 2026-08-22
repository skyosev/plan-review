# Thin wrapper over the scripts. There is nothing to build here; the targets
# exist so `make doctor` and `make test` work the way they do in neighbouring
# projects. Every target is equally runnable by hand.

.PHONY: help doctor init install test
.DEFAULT_GOAL := help

help:
	@echo 'PR_ORCHESTRATOR=<codex|agent|agy|claude|none> make doctor'
	@echo '                        check that a round could run here; with no'
	@echo '                        project config the roster is every other CLI'
	@echo 'make doctor REPO=<dir> [PLAN=<rel.md>] [PRESET=<name>]'
	@echo '                        also check a target repo, plan and project config'
	@echo 'make doctor OFFLINE=1   skip the auth and model-list checks'
	@echo 'make doctor SMOKE=1     also send each reviewer one live prompt end to end'
	@echo '                        (the only doctor check that spends tokens)'
	@echo 'make init REPO=<dir> [REVIEWERS=a,b] [PINS="agy=x agent=y"]'
	@echo '                        write that repo config from what is installed here,'
	@echo '                        then run the doctor over it'
	@echo 'make init OFFLINE=1     write it without any auth or model-list call'
	@echo 'make init FORCE=1       overwrite an existing config'
	@echo 'make install [BIN_DIR=<dir>]'
	@echo '                        link bin/plan-review into ~/.local/bin, or BIN_DIR'
	@echo 'make test               run the test suite'

doctor:
	@bin/plan-review doctor \
	  $(if $(REPO),--repo $(REPO)) \
	  $(if $(PLAN),--plan $(PLAN)) \
	  $(if $(PRESET),--preset $(PRESET)) \
	  $(if $(OFFLINE),--offline) \
	  $(if $(SMOKE),--smoke)

# --no-verify is deliberately not exposed here. It exists for the test suite and
# for scripted setup on a machine that is knowingly incomplete; `make init`
# should mean the whole thing, doctor included.
init:
	@bin/plan-review init \
	  --repo $(REPO) \
	  $(if $(REVIEWERS),--reviewers $(REVIEWERS)) \
	  $(foreach p,$(PINS),--pin $(p)) \
	  $(if $(OFFLINE),--offline) \
	  $(if $(FORCE),--force)

install:
	@bin/plan-review install $(if $(BIN_DIR),--bin-dir $(BIN_DIR))

test:
	@bash tests/run-tests.sh
