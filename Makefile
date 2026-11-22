# Not $(NVIM): inside Neovim's :terminal, $NVIM is the RPC socket path.
NVIM_BIN ?= nvim
TESTS := run github pr calendar dial

.PHONY: test
test:
	@fail=0; for t in $(TESTS); do \
		echo "== tests/$$t.lua"; \
		$(NVIM_BIN) --headless -u NONE -i NONE -c "luafile tests/$$t.lua" || fail=1; \
		echo; \
	done; exit $$fail
