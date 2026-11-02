.PHONY: build test verify verify-live verify-rules verify-late-rule verify-daemon-restart

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

verify-late-rule:
	zsh scripts/verify-late-rule.sh

verify-daemon-restart:
	sudo zsh scripts/verify-daemon-restart.sh
