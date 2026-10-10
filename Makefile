.PHONY: build test verify verify-live verify-rules

build:
	zsh scripts/build.sh

test:
	zsh scripts/test-unit.sh

verify:
	zsh scripts/verify-lab.sh

verify-live:
	zsh scripts/verify-live.sh

verify-rules:
	zsh scripts/verify-rules.sh
