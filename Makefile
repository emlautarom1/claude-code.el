EMACS ?= emacs
SRC   := claude-code.el
TESTS := test/claude-code-tests.el

.PHONY: all compile test integration lint clean

all: compile test

## Byte-compile with warnings promoted to errors.
compile:
	$(EMACS) -Q --batch \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -L . -f batch-byte-compile $(SRC)

## Run the ERT suite in batch mode.
test:
	$(EMACS) -Q --batch \
	  -L . -L test \
	  -l ert -l $(TESTS) \
	  -f ert-run-tests-batch-and-exit

## Run the live integration test: spawns a real `claude' via Ghostel.
## Needs the Ghostel native module and a logged-in CLI; not run by `test'/CI.
## The test strips Claude's nesting env vars itself, so this works even when
## invoked from inside a Claude Code session.
integration:
	CLAUDE_CODE_INTEGRATION=1 $(EMACS) --batch \
	  --eval '(package-initialize)' \
	  -L . -L test -l ert -l $(TESTS) \
	  --eval '(ert-run-tests-batch-and-exit "integration")'

## Run checkdoc over the sources, failing the build on any diagnostic.
## `checkdoc-file' only prints and never signals, so we count every error it
## reports (via `checkdoc-create-error', the one chokepoint) and exit non-zero.
lint:
	$(EMACS) -Q --batch -L . --eval '(progn (require (quote checkdoc)) (defvar cc-lint-errors 0) (advice-add (quote checkdoc-create-error) :before (lambda (&rest _) (setq cc-lint-errors (1+ cc-lint-errors)))) (checkdoc-file "claude-code.el") (kill-emacs (if (> cc-lint-errors 0) 1 0)))'

clean:
	rm -f *.elc test/*.elc
